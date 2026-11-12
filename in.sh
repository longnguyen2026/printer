#!/usr/bin/env bash
# Linux Print Tools v2.0 - interactive USB / LAN printer discovery for Mint/Kubuntu.
# Uses CUPS, DNS-SD/Avahi and optional Nmap subnet discovery.
# Never deletes existing queues or cancels print jobs.
# Driver policy: exact installed CUPS PPD first, IPP Everywhere second.
# Does not execute unverified vendor installers or invent download URLs.

set -Eeuo pipefail
IFS=$'\n\t'
VERSION="2.0.0"
LOG_FILE="/var/log/linux-print-tools.log"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

info(){ printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[CANH BAO]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[LOI]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Chay bang: sudo bash $0"
command -v apt-get >/dev/null || die "Chi ho tro Linux Mint/Ubuntu/Kubuntu."
mkdir -p /var/log
touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
export DEBIAN_FRONTEND=noninteractive

echo "=== Linux Print Tools v$VERSION ==="
info "Cai CUPS, cong cu quet va driver tu kho Ubuntu..."
apt-get update
apt-get install -y cups cups-client cups-filters cups-ipp-utils \
  hplip hplip-data printer-driver-hpcups printer-driver-brlaser \
  printer-driver-gutenprint printer-driver-all avahi-daemon avahi-utils \
  usbutils ipp-usb snmp nmap curl python3 smbclient

systemctl enable --now cups
systemctl enable --now avahi-daemon 2>/dev/null || true
# cups-browsed giup phat hien may in CUPS chia se; khong tat dich vu nay.
if systemctl list-unit-files cups-browsed.service >/dev/null 2>&1; then
  systemctl enable --now cups-browsed 2>/dev/null || true
fi

CAND="$TMP/candidates.tsv"
: > "$CAND"
add_uri(){
  local u="${1:-}" src="${2:-discovery}"
  [[ -n "$u" ]] || return 0
  u="${u//$'\r'/}"
  grep -Fq "$u"$'\t' "$CAND" 2>/dev/null || printf '%s\t%s\n' "$u" "$src" >> "$CAND"
}

info "Quet backend CUPS: USB, IPP, IPPS, DNS-SD, socket, LPD..."
while IFS= read -r line; do
  # lpinfo -v format: "direct usb://..." or "network ipp://..."
  read -r backend uri _ <<< "$line"
  [[ -n "${uri:-}" ]] && add_uri "$uri" "CUPS backend ($backend)"
done < <(lpinfo -v 2>/dev/null || true)

info "Quet may in cong bo qua Avahi..."
for svc in _ipp._tcp _ipps._tcp _printer._tcp; do
  avahi-browse -rt "$svc" 2>/dev/null |
  python3 -c '
import re,sys
s=sys.stdin.read()
for b in re.split(r"(?=^\s*=\s*;)",s,flags=re.M):
 if not re.search(r"^\s*=\s*;",b,re.M): continue
 a=re.search(r"^\s*address = \[(.*?)\]",b,re.M)
 p=re.search(r"^\s*port = \[(\d+)\]",b,re.M)
 t=re.search(r"^\s*txt = \[(.*?)\]",b,re.M)
 if not a or not p: continue
 rp="ipp/print"
 if t:
  m=re.search(r"rp=([^\", ]+)",t.group(1))
  if m: rp=m.group(1).lstrip("/")
 scheme="ipps" if "_ipps" in b else "ipp"
 print(f"{scheme}://{a.group(1)}:{p.group(1)}/{rp}")
' | while IFS= read -r u; do add_uri "$u" "Avahi"; done
done

# Quet cac subnet IPv4 dang gan tren may, khong suy subnet tu gateway.
if command -v nmap >/dev/null 2>&1; then
  while IFS= read -r subnet; do
    [[ -n "$subnet" ]] || continue
    info "Quet $subnet tren cong IPP/LPD/RAW..."
    nmap -n -T3 --open -p 445,631,515,9100 "$subnet" -oG "$TMP/nmap.gnmap" 2>/dev/null || true
    awk '/Ports:/{ip=$2;if($0~/631\/open/)print "ipp://"ip":631/";if($0~/9100\/open/)print "socket://"ip":9100";if($0~/515\/open/)print "lpd://"ip":515";if($0~/445\/open/)print ip}' "$TMP/nmap.gnmap" |
    while IFS= read -r item; do
      if [[ "$item" == *.* ]]; then
        # Thu liet ke may in chia se SMB cong khai; share can xac thuc se duoc bo qua.
        smbclient -g -N -L "//$item" 2>/dev/null |
          awk -F'|' '$1=="Printer"{print $2}' |
          while IFS= read -r share; do
            [[ -n "$share" ]] && add_uri "smb://$item/$share" "SMB share"
          done
      else
        add_uri "$item" "LAN scan"
      fi
    done
  done < <(ip -o -f inet addr show scope global 2>/dev/null | awk '{print $4}' || true)
fi

DETAILS="$TMP/details.tsv"; : > "$DETAILS"
extract_attr(){
  sed -nE "s/^[[:space:]]*$2[[:space:]]*\\([^)]*\\)[[:space:]]*=[[:space:]]*//p" "$1" |
    head -n1 | sed 's/^"//;s/"$//'
}
n=0
while IFS=$'\t' read -r uri source; do
  [[ -n "$uri" ]] || continue
  n=$((n+1)); out="$TMP/ipp-$n.txt"
  if [[ -r /usr/share/cups/ipptool/get-printer-attributes.test ]]; then
    timeout 8 ipptool -tv "$uri" /usr/share/cups/ipptool/get-printer-attributes.test > "$out" 2>/dev/null || true
  else : > "$out"; fi
  model="$(extract_attr "$out" printer-make-and-model || true)"
  [[ -n "$model" ]] || model="$(extract_attr "$out" printer-info || true)"
  [[ -n "$model" ]] || model="$(extract_attr "$out" printer-name || true)"
  if [[ -z "$model" && "$uri" == usb://* ]]; then
    model="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.argv[1]))' "$uri" | sed 's#usb://##;s/?[^?]*//')"
  fi
  if [[ -z "$model" && "$uri" =~ ^(ipp|ipps|socket|lpd)://\[?([0-9a-fA-F:.]+)\]? ]]; then
    host="${BASH_REMATCH[2]}"
    model="$(snmpget -v1 -c public -t 1 -r 0 -Oqv "$host" 1.3.6.1.2.1.1.1.0 2>/dev/null | tr -d '"' || true)"
  fi
  [[ -n "$model" ]] || model="Model chua nhan dien"
  devid="$(extract_attr "$out" printer-device-id || true)"
  printf '%s\t%s\t%s\t%s\t%s\n' "$uri" "$source" "$model" "$devid" "$out" >> "$DETAILS"
done < "$CAND"

count="$(wc -l < "$DETAILS" | tr -d ' ')"
if (( count == 0 )); then
  warn "Khong tim thay may in. Kiem tra cap USB, LAN, IPP va chia se may in."
  exit 0
fi

echo
echo "========== DANH SACH MAY IN TIM THAY =========="
i=0
while IFS=$'\t' read -r uri source model devid out; do
  i=$((i+1))
  printf '\n[%d] %s\n    Ket noi: %s\n    Phat hien boi: %s\n' "$i" "$model" "$uri" "$source"
  [[ -n "$devid" ]] && printf '    Device ID: %s\n' "$devid"
done < "$DETAILS"
echo "==============================================="
read -r -p "Chon may in (1-$count, 0 de thoat): " choice
[[ "$choice" =~ ^[0-9]+$ ]] || die "Lua chon khong hop le."
(( choice == 0 )) && exit 0
(( choice >= 1 && choice <= count )) || die "So thu tu khong hop le."

IFS=$'\t' read -r URI SOURCE MODEL DEVID IPPFILE < <(sed -n "${choice}p" "$DETAILS")
info "Da chon: $MODEL"
IDENT="$MODEL $DEVID $URI"
BRAND="unknown"
if grep -qiE 'hewlett.?packard|(^|[^a-z])hp([^a-z]|$)|laserjet|deskjet|officejet' <<< "$IDENT"; then BRAND=hp
elif grep -qi brother <<< "$IDENT"; then BRAND=brother
elif grep -qiE 'canon|pixma|imageclass' <<< "$IDENT"; then BRAND=canon
elif grep -qiE 'epson|ecotank|workforce|stylus' <<< "$IDENT"; then BRAND=epson
elif grep -qi pantum <<< "$IDENT"; then BRAND=pantum
elif grep -qiE 'samsung|xpress' <<< "$IDENT"; then BRAND=samsung
fi
info "Nhan dien hang: $BRAND"

# Ten hang doi theo ten/model may in duoc bao cao; khong dung ten HP-Printer chung.
BASE="$(printf '%s' "$MODEL" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null |
  tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g;s/^-|-$//g' | cut -c1-48)"
[[ -n "$BASE" ]] || BASE="printer"
QUEUE="$BASE"; suffix=2
while lpstat -p "$QUEUE" >/dev/null 2>&1; do
  olduri="$(lpstat -v "$QUEUE" 2>/dev/null | sed 's/^[^:]*: //')"
  [[ "$olduri" == "$URI" ]] && break
  QUEUE="${BASE}-${suffix}"; suffix=$((suffix+1))
done

# Tim PPD trong CUPS da cai, co kiem tra hang va model.
MODELS="$TMP/models.txt"
lpinfo -m > "$MODELS" 2>/dev/null || true
DRIVER=""
if [[ "$MODEL" != "Model chua nhan dien" ]]; then
  key="$(printf '%s' "$MODEL" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/ /g')"
  # Chi chap nhan PPD co hang + ma model (token co chu so), tranh match chung "HP".
  model_token="$(awk '{for(i=1;i<=NF;i++) if($i ~ /[0-9]/){print $i; exit}}' <<< "$key")"
  if [[ -n "$model_token" ]]; then
    while IFS= read -r row; do
      low="$(printf '%s' "$row" | tr '[:upper:]' '[:lower:]')"
      if [[ "$low" == *"$BRAND"* && "$low" == *"$model_token"* ]]; then
        DRIVER="$(awk '{print $1}' <<< "$row")"; break
      fi
    done < "$MODELS"
  fi
fi

# IPP Everywhere: chi thu khi IPP attributes query thanh cong.
DRIVERLESS=no
if grep -qiE 'printer-make-and-model|printer-uuid|document-format-supported|ipp-versions-supported' "$IPPFILE" 2>/dev/null; then
  DRIVERLESS=yes
fi

if [[ -n "$DRIVER" ]]; then
  info "Chon PPD tu kho CUPS: $DRIVER"
  lpadmin -p "$QUEUE" -E -v "$URI" -m "$DRIVER"
elif [[ "$DRIVERLESS" == yes ]]; then
  info "Thiet bi phan hoi IPP; thu driverless IPP Everywhere."
  lpadmin -p "$QUEUE" -E -v "$URI" -m everywhere
else
  echo
  warn "Chua co driver dung model trong cac goi da cai."
  echo "Khong tu dong gan driver cua model khac."
  echo "Neu may can driver doc quyen, hay tai goi dung model tu trang chinh hang."
  read -r -p "Thu tao hang doi raw (co the mat tinh nang in) khong? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || die "Dung lai de tranh cai sai driver."
  lpadmin -p "$QUEUE" -E -v "$URI" -m raw
fi

lpadmin -p "$QUEUE" -D "$MODEL" 2>/dev/null || true
cupsenable "$QUEUE"; cupsaccept "$QUEUE"
lpoptions -p "$QUEUE" -o media=A4 2>/dev/null || true
if lpoptions -p "$QUEUE" -l 2>/dev/null | grep -qiE 'Duplex|sides'; then
  lpoptions -p "$QUEUE" -o sides=two-sided-long-edge 2>/dev/null || true
fi

echo
echo "=============== KET QUA ==============="
lpstat -p "$QUEUE" -l 2>/dev/null || true
lpstat -v "$QUEUE" 2>/dev/null || true
echo "Ten hang doi : $QUEUE"
echo "Ten/model    : $MODEL"
echo "Hang         : $BRAND"
echo "Driver       : ${DRIVER:-IPP Everywhere/raw}"
echo "Log          : $LOG_FILE"
echo "Khong xoa hang doi cu, khong huy lenh in, khong doi may in mac dinh."
echo "======================================="
warn "Gioi han: script chua tu dong tai va chay bo cai dat doc quyen theo moi model. Brother/Canon/Epson/Pantum co the can goi .deb rieng tu trang chinh hang; khong nen tu dong chay URL khong duoc xac minh."
