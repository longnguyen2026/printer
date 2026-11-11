#!/usr/bin/env bash
# Linux Print Tools 0.1.0
# Safe discovery and CUPS setup for Linux Mint / Ubuntu / Kubuntu.
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="0.1.0"
APP="linux-print-tools"
LOG_DIR="/var/log/linux-print-tools"
LOG_FILE="$LOG_DIR/setup.log"
STATE_DIR="/var/lib/linux-print-tools"
MANAGED_FILE="$STATE_DIR/managed-queues"
DRY_RUN=0
INSTALL_PACKAGES=1
SET_DEFAULT=0
CONFIGURE_DEFAULTS=1
SCAN_TIMEOUT=3

info(){ printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
warn(){ printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
err(){ printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }
run(){
  if (( DRY_RUN )); then printf '[DRY-RUN]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}
usage(){
cat <<'EOF'
Linux Print Tools 0.1.0
Usage: sudo ./printer-tools.sh [options]

  --dry-run             Chỉ dò và in kế hoạch, không thay đổi hệ thống
  --no-install-packages Không cài các gói nền tảng
  --set-default         Đặt máy in mới cài đầu tiên làm mặc định
  --no-defaults         Không ép A4/duplex; giữ thiết lập mặc định của driver
  --help                Hiển thị trợ giúp

An toàn:
- Không xóa queue hiện có.
- Không hủy job đang in.
- Không tự đổi máy in mặc định (trừ khi dùng --set-default).
- Không ghi đè queue cùng tên; tên mới có hậu tố riêng.
EOF
}
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-install-packages) INSTALL_PACKAGES=0 ;;
    --set-default) SET_DEFAULT=1 ;;
    --no-defaults) CONFIGURE_DEFAULTS=0 ;;
    --help|-h) usage; exit 0 ;;
    *) err "Tùy chọn không hợp lệ: $1"; usage; exit 2 ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || { err "Hãy chạy: sudo bash $0"; exit 1; }
mkdir -p "$LOG_DIR" "$STATE_DIR"
touch "$LOG_FILE" "$MANAGED_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

info "$APP v$VERSION — bắt đầu $(date -Is)"
if [[ ! -r /etc/os-release ]]; then err "Không xác định được hệ điều hành."; exit 1; fi
. /etc/os-release
case "${ID:-} ${ID_LIKE:-}" in
  *ubuntu*|*debian*|*linuxmint*) ;;
  *) warn "Chưa xác nhận distro này. Script được thiết kế cho Linux Mint/Ubuntu/Kubuntu."; ;;
esac
command -v apt-get >/dev/null || { err "Cần apt-get."; exit 1; }

BASE_PACKAGES=(
  cups cups-client cups-filters cups-ipp-utils
  avahi-daemon avahi-utils
  printer-driver-gutenprint printer-driver-brlaser
  printer-driver-hpcups hplip hplip-data
  printer-driver-foo2zjs printer-driver-foo2zjs-common
  printer-driver-escpr
  usbutils iproute2 nmap curl
)
if (( INSTALL_PACKAGES )); then
  info "Cài các gói nền tảng và driver có sẵn trong kho Ubuntu..."
  run apt-get update
  run apt-get install -y "${BASE_PACKAGES[@]}"
fi

for cmd in lpinfo lpadmin lpstat lpoptions; do
  command -v "$cmd" >/dev/null || { err "Thiếu lệnh $cmd. Hãy chạy lại không dùng --no-install-packages."; exit 1; }
done
run systemctl enable --now cups
# Avahi is optional on systems that do not use mDNS.
if command -v systemctl >/dev/null && systemctl list-unit-files avahi-daemon.service >/dev/null 2>&1; then
  run systemctl enable --now avahi-daemon || warn "Không bật được Avahi; vẫn tiếp tục dò USB/IP."
fi

declare -A SEEN=()
declare -a DEVICES=()
add_device(){
  local uri="$1" source="$2"
  [[ -n "$uri" ]] || return 0
  [[ "$uri" =~ ^(usb|ipp|ipps|dnssd|socket|lpd|http|https): ]] || return 0
  [[ -n "${SEEN[$uri]:-}" ]] && return 0
  SEEN["$uri"]=1
  DEVICES+=("$uri"$'\t'"$source")
}
info "Dò thiết bị theo CUPS backend..."
while IFS= read -r line; do
  # lpinfo -v prints: "direct usb://..." or "network ipp://..."
  # Do not split on ": " because that is not the lpinfo output format.
  read -r _backend uri _rest <<<"$line"
  [[ -n "${uri:-}" ]] || continue
  add_device "$uri" "cups-discovery"
done < <(lpinfo -v 2>/dev/null || true)

# Scan the active local IPv4 subnets; never assume /24 or infer subnet from gateway.
if command -v nmap >/dev/null; then
  while IFS= read -r cidr; do
    [[ -n "$cidr" ]] || continue
    info "Quét subnet $cidr (IPP/RAW/LPR/HTTP/SNMP)..."
    while IFS= read -r ip; do
      [[ -n "$ip" ]] || continue
      # Check IPP first. A successful TCP connection is discovery evidence, not proof of printer model.
      if timeout "$SCAN_TIMEOUT" bash -c ":</dev/tcp/$ip/631" 2>/dev/null; then
        add_device "ipp://$ip/ipp/print" "lan-ipp-candidate"
      fi
      if timeout "$SCAN_TIMEOUT" bash -c ":</dev/tcp/$ip/9100" 2>/dev/null; then
        add_device "socket://$ip:9100" "lan-raw-candidate"
      fi
      if timeout "$SCAN_TIMEOUT" bash -c ":</dev/tcp/$ip/515" 2>/dev/null; then
        add_device "lpd://$ip/queue" "lan-lpd-candidate"
      fi
    done < <(nmap -n -p 631,9100,515 --open -T3 "$cidr" -oG - 2>/dev/null | awk '/Ports:/{print $2}' | sort -u)
  done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | sort -u)
fi

if ((${#DEVICES[@]} == 0)); then
  warn "Không tìm thấy URI máy in. Kiểm tra nguồn điện, cáp USB, cùng mạng LAN và dịch vụ CUPS."
  info "Log: $LOG_FILE"
  exit 0
fi

# Resolve a human-readable model from URI/IP when possible.
model_for(){
  local uri="$1" host=""
  if [[ "$uri" =~ ^(ipp|ipps|http|https)://([^/:]+) ]]; then host="${BASH_REMATCH[2]}"; fi
  if [[ "$uri" =~ ^(socket|lpd)://([^/:]+) ]]; then host="${BASH_REMATCH[2]}"; fi
  if [[ -n "$host" ]] && command -v snmpget >/dev/null; then
    timeout 2 snmpget -v1 -c public -Oqv "$host" .1.3.6.1.2.1.1.1.0 2>/dev/null | head -c 180 || true
  fi
  printf '%s' ""
}
queue_exists(){ lpstat -p "$1" >/dev/null 2>&1; }
make_queue_name(){
  local base="$1" candidate="$1" n=2
  candidate="${base//[^a-zA-Z0-9_-]/-}"
  while queue_exists "$candidate"; do candidate="${base//[^a-zA-Z0-9_-]/-}-$n"; ((n+=1)); done
  printf '%s' "$candidate"
}
choose_model(){
  local uri="$1" model=""
  # Query standard IPP attributes where possible.
  if command -v ipptool >/dev/null && [[ "$uri" =~ ^ipps?:// ]]; then
    model="$(timeout 4 ipptool -tv "$uri" /usr/share/cups/ipptool/get-printer-attributes.test 2>/dev/null |
      awk -F' = ' '/printer-make-and-model|printer-info|printer-name/ {print $2; exit}' | tr -d '"' | head -c 100)"
  fi
  if [[ -z "$model" ]]; then
    case "$uri" in
      usb://*) model="USB printer (model not exposed by CUPS URI)" ;;
      *) model="Network printer (model not identified)" ;;
    esac
  fi
  printf '%s' "$model"
}
find_ppd(){
  local model="$1" models="" token=""
  # Prefer an exact or highly similar installed PPD/model match.
  models="$(lpinfo -m 2>/dev/null || true)"
  token="$(printf '%s' "$model" | sed 's/[[:space:]]\+/ /g' | cut -c1-50)"
  if [[ -n "$token" && "$token" != *"not identified"* ]]; then
    printf '%s\n' "$models" | grep -iF "$token" | head -n1 | awk '{print $1}'
  fi
}
install_queue(){
  local uri="$1" source="$2" model="$3" brand="" ppd="" base="" queue="" driver_note=""
  local low="${model,,} ${uri,,}"
  if [[ "$low" == *hp* || "$low" == *hewlett* ]]; then brand="HP"
  elif [[ "$low" == *brother* ]]; then brand="Brother"
  elif [[ "$low" == *canon* ]]; then brand="Canon"
  elif [[ "$low" == *epson* ]]; then brand="Epson"
  elif [[ "$low" == *samsung* ]]; then brand="Samsung"
  elif [[ "$low" == *pantum* ]]; then brand="Pantum"
  else brand="Printer"; fi
  base="${brand}-$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | cut -c1-28)"
  [[ "$base" == "$brand-" ]] && base="$brand-$(printf '%s' "$uri" | sha256sum | cut -c1-8)"
  queue="$(make_queue_name "$base")"
  ppd="$(find_ppd "$model" || true)"

  info "Thiết bị: $uri"
  info "Model nhận diện: $model"
  info "Hãng suy đoán: $brand"
  if [[ -n "$ppd" ]]; then
    driver_note="PPD đã cài: $ppd"
    info "$driver_note"
    run lpadmin -p "$queue" -E -v "$uri" -m "$ppd"
  elif [[ "$uri" =~ ^(ipp|ipps|dnssd): ]]; then
    driver_note="Driverless IPP Everywhere (thiết bị cần hỗ trợ IPP)"
    info "$driver_note"
    run lpadmin -p "$queue" -E -v "$uri" -m everywhere
  else
    warn "Chưa tìm được PPD theo model. Không gán driver sai; tạo queue driverless chỉ khi thiết bị hỗ trợ IPP."
    warn "Bỏ qua URI không IPP để tránh tạo hàng đợi không in được: $uri"
    return 0
  fi

  run cupsenable "$queue"
  run cupsaccept "$queue"
  if (( CONFIGURE_DEFAULTS )); then
    # Only apply options advertised by this queue's driver.
    local opts
    opts="$(lpoptions -p "$queue" -l 2>/dev/null || true)"
    if grep -qE 'PageSize.*A4|PageSize.*A4' <<<"$opts"; then
      run lpadmin -p "$queue" -o PageSize=A4
    fi
    if grep -q 'sides.*two-sided-long-edge' <<<"$opts"; then
      run lpadmin -p "$queue" -o sides=two-sided-long-edge
    elif grep -q 'Duplex.*DuplexNoTumble' <<<"$opts"; then
      run lpadmin -p "$queue" -o Duplex=DuplexNoTumble
    fi
  fi
  printf '%s\n' "$queue" >> "$MANAGED_FILE"
  info "Đã tạo queue mới: $queue"
  if (( SET_DEFAULT )); then run lpadmin -d "$queue"; SET_DEFAULT=0; fi
}

info "Tìm thấy ${#DEVICES[@]} URI ứng viên. Bắt đầu đánh giá..."
for item in "${DEVICES[@]}"; do
  uri="${item%%$'\t'*}"
  source="${item#*$'\t'}"
  model="$(choose_model "$uri")"
  install_queue "$uri" "$source" "$model"
done

echo
info "Tổng kết CUPS:"
lpstat -t 2>/dev/null || true
echo
info "Danh sách queue do Linux Print Tools tạo:"
sort -u "$MANAGED_FILE" 2>/dev/null | tail -30 || true
info "Không có queue cũ nào bị xóa; không có job in nào bị hủy."
info "Log: $LOG_FILE"
