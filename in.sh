#!/usr/bin/env bash
# Linux Print Tools v2.0.4
# Detect USB / DNS-SD / IPP printers, exclude receipt/POS devices,
# let the user select printers, and install the best locally available driver.
# Existing queues and print jobs are never deleted or cancelled.

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2.0.5"
LOG_FILE="/var/log/linux-print-tools.log"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

info() { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

if [[ $EUID -ne 0 ]]; then
  die "Chạy bằng quyền root: sudo bash $0"
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

printf '\n============================================================\n'
printf ' Linux Print Tools v%s\n' "$VERSION"
printf ' Phát hiện và cài đặt máy in USB / mạng\n'
printf '============================================================\n\n'

export DEBIAN_FRONTEND=noninteractive
info "Cài đặt các thành phần CUPS và công cụ nhận diện..."
apt-get update -qq
apt-get install -y \
  cups cups-client cups-filters cups-ipp-utils \
  printer-driver-brlaser printer-driver-gutenprint \
  printer-driver-hpcups hplip hplip-data \
  avahi-daemon avahi-utils usbutils ipp-usb \
  python3 curl >/dev/null

systemctl enable --now cups >/dev/null 2>&1 || true
systemctl enable --now avahi-daemon >/dev/null 2>&1 || true
# Không tắt cups-browsed: dịch vụ này có thể đang cung cấp các hàng đợi mạng.
sleep 2

# Decode DNS-SD service instance and generate a readable display name.
decode_dnssd() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
u=sys.argv[1]
s=u[len("dnssd://"):] if u.startswith("dnssd://") else u
s=s.split("._ipp._tcp",1)[0].split("._ipps._tcp",1)[0]
print(urllib.parse.unquote(s))
PY
}

# Return 0 for known receipt/POS printer models. Avoid excluding ordinary
# office printers from the same manufacturer.
is_pos_printer() {
  local s="${1^^}"
  [[ "$s" =~ BIXOLON|SRP[-_[:space:]]?[0-9]|FP[-_[:space:]]?2000|STAR[[:space:]_-]*MICRONICS|TSP[0-9]{2,}|RONGTA|XPRINTER|SEWOO|SNBC|EPSON[[:space:]_-]?TM|TM[-_[:space:]]?T[0-9]|RECEIPT[[:space:]_-]*PRINTER|THERMAL[[:space:]_-]*RECEIPT ]]
}

# Make a CUPS-safe queue name from a display name.
make_queue_name() {
  python3 - "$1" <<'PY'
import re,sys
s=sys.argv[1].lower()
s=re.sub(r'[^a-z0-9]+','_',s).strip('_')
print((s[:100] or 'printer'))
PY
}

# Find an existing CUPS queue by normalized name, ignoring case and separators.
find_existing_queue() {
  local wanted="$1" q normalized
  wanted="$(make_queue_name "$wanted")"
  while IFS= read -r q; do
    [[ -n "$q" ]] || continue
    normalized="$(make_queue_name "$q")"
    if [[ "$normalized" == "$wanted" ]]; then
      printf '%s\n' "$q"
      return 0
    fi
  done < <(lpstat -p 2>/dev/null | awk '$1 == "printer" {print $2}')
  return 1
}

queue_state() {
  local q="$1" line
  line="$(lpstat -p "$q" 2>/dev/null | head -n1 || true)"
  if [[ "$line" =~ is[[:space:]]+([^.]*) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "đã tồn tại"
  fi
}

# Build candidate list from actual device URIs reported by CUPS.
# Format: display<TAB>uri<TAB>kind
CANDIDATES="$TMP_DIR/candidates.tsv"
: > "$CANDIDATES"
while IFS= read -r line; do
  # lpinfo -v format is usually: "network URI" or "direct URI".
  IFS=' ' read -r backend uri _ <<< "$line"
  [[ -n "${uri:-}" ]] || continue
  case "$uri" in
    dnssd://*)
      display="$(decode_dnssd "$uri")"
      printf '%s\t%s\tDNS-SD\n' "$display" "$uri" >> "$CANDIDATES"
      ;;
    usb://*)
      # Device ID/model information is available through lpinfo -v / lsusb;
      # keep URI as candidate and resolve a friendly label below.
      printf 'USB printer\t%s\tUSB\n' "$uri" >> "$CANDIDATES"
      ;;
    ipp://*|ipps://*|socket://*|lpd://*|smb://*|http://*|https://*)
      host="${uri#*://}"; host="${host%%/*}"
      printf '%s\t%s\tNETWORK\n' "Network printer ($host)" "$uri" >> "$CANDIDATES"
      ;;
  esac
done < <(lpinfo -v 2>/dev/null || true)

# Existing CUPS queues are not added as installation candidates.
# This avoids duplicate implicitclass entries and preserves current queues.

# Remove duplicate URIs, then split supported and excluded devices.
awk -F '\t' '!seen[$2]++' "$CANDIDATES" > "$TMP_DIR/unique.tsv"
: > "$TMP_DIR/usable.tsv"
: > "$TMP_DIR/excluded.tsv"
while IFS=$'\t' read -r display uri kind; do
  [[ -n "$uri" ]] || continue
  # For USB, try to replace generic label with USB device ID/model.
  if [[ "$kind" == "USB" ]]; then
    usb_text="$(lpinfo -v 2>/dev/null | grep -F "$uri" | head -n1 || true)"
    display="USB printer ${usb_text#*usb://}"
  fi
  if is_pos_printer "$display $uri"; then
    printf '%s\t%s\t%s\n' "$display" "$uri" "$kind" >> "$TMP_DIR/excluded.tsv"
  else
    printf '%s\t%s\t%s\n' "$display" "$uri" "$kind" >> "$TMP_DIR/usable.tsv"
  fi
done < "$TMP_DIR/unique.tsv"

printf '\n'
if [[ -s "$TMP_DIR/excluded.tsv" ]]; then
  warn "Đã tự động loại các thiết bị có dấu hiệu là máy in hóa đơn/POS:"
  while IFS=$'\t' read -r d u k; do printf '  - %s\n' "$d"; done < "$TMP_DIR/excluded.tsv"
fi

if [[ ! -s "$TMP_DIR/usable.tsv" ]]; then
  die "Không tìm thấy máy in văn phòng phù hợp. Kiểm tra USB, Avahi/DNS-SD hoặc CUPS."
fi

mapfile -t DISPLAYS < <(cut -f1 "$TMP_DIR/usable.tsv")
mapfile -t URIS < <(cut -f2 "$TMP_DIR/usable.tsv")
mapfile -t KINDS < <(cut -f3 "$TMP_DIR/usable.tsv")

printf '\nMáy in phát hiện được:\n'
for i in "${!DISPLAYS[@]}"; do
  existing="$(find_existing_queue "${DISPLAYS[$i]}" || true)"
  if [[ -n "$existing" ]]; then
    state="$(queue_state "$existing")"
    printf '  %2d) %-42s [%s] [ĐÃ CẤU HÌNH: %s; %s]\n' \
      "$((i+1))" "${DISPLAYS[$i]}" "${KINDS[$i]}" "$existing" "$state"
  else
    printf '  %2d) %-42s [%s] [CHƯA CẤU HÌNH]\n' \
      "$((i+1))" "${DISPLAYS[$i]}" "${KINDS[$i]}"
  fi
done
printf '\n'
if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
  die "Không tìm thấy terminal tương tác. Hãy chạy lệnh từ cửa sổ Terminal."
fi
# When launched with curl | sudo bash, stdin is the script itself.
# Also, the normal output is piped through tee for logging. Therefore write
# the prompt explicitly to the controlling terminal, not to stdout/stderr.
printf '%s' "Chọn máy in cần cài (nhập số, nhiều số cách nhau bởi dấu cách; Enter để thoát): " > /dev/tty
if ! IFS= read -r selection < /dev/tty; then
  die "Không đọc được lựa chọn từ terminal."
fi
if [[ -z "${selection//[[:space:]]/}" ]]; then
  info "Đã thoát, không thay đổi hàng đợi."
  exit 0
fi
# Accept one or more numbers separated by spaces or tabs.
IFS=$' \t\n' read -r -a selection_array <<< "$selection"

# Driver lookup: require model tokens to match; do not blindly assign a
# generic Brother/HP PPD to a different model.
choose_driver() {
  local display="$1" normalized model_line
  normalized="$(printf '%s' "$display" | tr '[:lower:]' '[:upper:]')"
  if [[ "$normalized" =~ HL[-_[:space:]]?L?2360D ]]; then
    model_line="$(lpinfo -m 2>/dev/null | grep -iE 'Brother HL-L2360D series' | head -n1 || true)"
    if [[ -n "$model_line" ]]; then printf '%s\n' "${model_line%% *}"; return 0; fi
  fi
  if [[ "$normalized" =~ HL[-_[:space:]]?L?([0-9]{4}[A-Z]?) ]]; then
    local token="${BASH_REMATCH[1]}"
    model_line="$(lpinfo -m 2>/dev/null | grep -iE "Brother HL-L?${token}([[:space:]]|,)" | head -n1 || true)"
    if [[ -n "$model_line" ]]; then printf '%s\n' "${model_line%% *}"; return 0; fi
  fi
  if [[ "$normalized" =~ (M[0-9]{3}[A-Z]?) ]]; then
    local token="${BASH_REMATCH[1]}"
    model_line="$(lpinfo -m 2>/dev/null | grep -iE "HP.*${token}" | head -n1 || true)"
    if [[ -n "$model_line" ]]; then printf '%s\n' "${model_line%% *}"; return 0; fi
  fi
  # Exact vendor/model phrase match from local CUPS model catalog.
  model_line="$(lpinfo -m 2>/dev/null | grep -iF "$display" | head -n1 || true)"
  if [[ -n "$model_line" ]]; then printf '%s\n' "${model_line%% *}"; return 0; fi
  return 1
}

for item in "${selection_array[@]}"; do
  [[ "$item" =~ ^[0-9]+$ ]] || { warn "Bỏ qua lựa chọn không hợp lệ: $item"; continue; }
  idx=$((item-1))
  if (( idx < 0 || idx >= ${#URIS[@]} )); then
    warn "Số thứ tự không tồn tại: $item"
    continue
  fi

  display="${DISPLAYS[$idx]}"
  uri="${URIS[$idx]}"
  queue="$(make_queue_name "$display")"
  # Detect existing queues case-insensitively and report their re#!/usr/bin/env bash
# Linux Print Tools v2.0.4
# Detect USB / DNS-SD / IPP printers, exclude receipt/POS devices,
# let the user select printers, and install the best locally available driver.
# Existing queues and print jobs are never deleted or cancelled.

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2.0.5"
LOG_FILE="/var/log/linux-print-tools.log"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

info() { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

if [[ $EUID -ne 0 ]]; then
  die "Chạy bằng quyền root: sudo bash $0"
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

printf '\n============================================================\n'
printf ' Linux Print Tools v%s\n' "$VERSION"
printf ' Phát hiện và cài đặt máy in USB / mạng\n'
printf '============================================================\n\n'

export DEBIAN_FRONTEND=noninteractive
info "Cài đặt các thành phần CUPS và công cụ nhận diện..."
apt-get update -qq
apt-get install -y \
  cups cups-client cups-filters cups-ipp-utils \
  printer-driver-brlaser printer-driver-gutenprint \
  printer-driver-hpcups hplip hplip-data \
  avahi-daemon avahi-utils usbutils ipp-usb \
  python3 curl >/dev/null

systemctl enable --now cups >/dev/null 2>&1 || true
systemctl enable --now avahi-daemon >/dev/null 2>&1 || true
# Không tắt cups-browsed: dịch vụ này có thể đang cung cấp các hàng đợi mạng.
sleep 2

# Decode DNS-SD service instance and generate a readable display name.
decode_dnssd() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
u=sys.argv[1]
s=u[len("dnssd://"):] if u.startswith("dnssd://") else u
s=s.split("._ipp._tcp",1)[0].split("._ipps._tcp",1)[0]
print(urllib.parse.unquote(s))
PY
}

# Return 0 for known receipt/POS printer models. Avoid excluding ordinary
# office printers from the same manufacturer.
al queue name.
  existing="$(find_existing_queue "$display" || true)"
  if [[ -n "$existing" ]]; then
    state="$(queue_state "$existing")"
    info "Máy in này đã được cấu hình. Hàng đợi: $existing (trạng thái: $state)."
    info "Giữ nguyên cấu hình hiện tại; không tạo hàng đợi trùng và không thay đổi lệnh in."
    continue
  fi

  info "Đang thiết lập: $display"
  driver="$(choose_driver "$display" || true)"
  if [[ -n "$driver" ]]; then
    info "Driver khớp model: $driver"
    if ! lpadmin -p "$queue" -E -v "$uri" -m "$driver"; then
      warn "Không tạo được hàng đợi với driver đã chọn; thử IPP Everywhere."
      driver=""
    fi
  fi

  if [[ -z "$driver" ]]; then
    if [[ "$uri" == dnssd://* || "$uri" == ipp://* || "$uri" == ipps://* ]]; then
      info "Không có PPD khớp model cục bộ; thử IPP Everywhere."
      lpadmin -p "$queue" -E -v "$uri" -m everywhere || {
        warn "IPP Everywhere không được thiết bị hỗ trợ; không tạo hàng đợi sai driver."
        continue
      }
    else
      warn "Không tìm thấy driver phù hợp cho $display. Không tạo hàng đợi bằng driver đoán."
      continue
    fi
  fi

  lpadmin -p "$queue" -D "$display" 2>/dev/null || true
  cupsenable "$queue" 2>/dev/null || true
  cupsaccept "$queue" 2>/dev/null || true

  # Set A4 only when supported; never force duplex on a simplex printer.
  lpadmin -p "$queue" -o PageSize=A4 2>/dev/null || true
  lpadmin -p "$queue" -o media=A4 2>/dev/null || true
  if lpoptions -p "$queue" -l 2>/dev/null | grep -qiE 'Duplex|sides'; then
    lpadmin -p "$queue" -o sides=two-sided-long-edge 2>/dev/null || true
  fi
  info "Đã tạo hàng đợi: $queue"
done

printf '\n============================================================\n'
info "Hoàn tất. Các hàng đợi hiện có và lệnh in đang chờ được giữ nguyên."
lpstat -p -d 2>/dev/null || true
lpstat -v 2>/dev/null || true
printf 'Log: %s\n' "$LOG_FILE"
printf '============================================================\n'
