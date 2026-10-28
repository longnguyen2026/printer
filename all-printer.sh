#!/usr/bin/env bash
# ==============================================================================
# SCRIPT CÀI FULL DRIVER (HP, BROTHER, CANON, GENERIC), AUTO-ADD & CẤU HÌNH DUPLEX/A4
# Tương thích: Linux Mint, Ubuntu, Debian
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

LOG_FILE="/var/log/full-printer-setup.log"
TEMP_DIR=""

info()  { echo -e "\e[32m[INFO]\e[0m $*"; }
warn()  { echo -e "\e[33m[CẢNH BÁO]\e[0m $*" >&2; }
error() { echo -e "\e[31m[LỖI]\e[0m $*" >&2; }
die()   { error "$*"; exit 1; }

cleanup() {
  [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]] && rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

if [[ $EUID -ne 0 ]]; then
  die "Vui lòng chạy script với quyền root: sudo bash $0"
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================================"
echo "   CÀI ĐẶT TRỌN BỘ DRIVER MÁY IN & BẬT IN 2 MẶT / KHỔ A4"
echo "============================================================"

export DEBIAN_FRONTEND=noninteractive

# 1. Cài đặt toàn bộ driver phổ biến từ repository (HPLIP, CUPS-Filters, Gutenprint, Foomatic)
info "Đang cài đặt đầy đủ bộ driver hệ thống (HP, Canon, Epson, Generic)..."
apt-get update -qq
apt-get install -y \
  cups cups-client cups-filters cups-ipp-utils \
  printer-driver-all \
  printer-driver-hpcups hplip hplip-data \
  printer-driver-gutenprint \
  printer-driver-pnm2ppa \
  foomatic-db-compressed-ppds \
  openprinting-ppds \
  avahi-daemon avahi-utils \
  usbutils wget ca-certificates gzip -qq

systemctl enable --now cups avahi-daemon
sleep 2

# 2. Xử lý driver cho Brother (nếu phát hiện máy Brother)
if lsusb 2>/dev/null | grep -qi "Brother" || lpinfo -v 2>/dev/null | grep -qi "Brother"; then
  info "Phát hiện máy in Brother. Tiến hành tải bộ cài driver chính thức..."
  TEMP_DIR="$(mktemp -d -t brother-pkg-XXXXXXXX)"[cite: 1]
  cd "$TEMP_DIR"[cite: 1]
  INSTALLER_URL="https://download.brother.com/welcome/dlf006893/linux-brprinter-installer-2.2.4-1.gz"[cite: 1]
  
  if wget --https-only --timeout=30 -O brinstaller.gz "$INSTALLER_URL"; then[cite: 1]
    gunzip brinstaller.gz[cite: 1]
    chmod 700 brinstaller[cite: 1]
    
    # Tự động lấy tên model nếu nhận diện được qua USB/lpinfo
    DETECTED_MODEL=$(lsusb 2>/dev/null | grep -i "Brother" | head -n 1 | sed -E 's/.*Brother Industries, Ltd (.*)/\1/' | tr -d ' ' || true)
    
    echo
    echo "--- Tùy chọn Model Brother ---"
    read -r -p "Nhập Model Brother [Enter lấy mặc định HL-L2360D hoặc tự nhận ${DETECTED_MODEL:-HL-L2360D}]: " INPUT_MODEL
    CHOSEN_MODEL="${INPUT_MODEL:-${DETECTED_MODEL:-HL-L2360D}}"[cite: 1]
    CHOSEN_MODEL="$(echo "$CHOSEN_MODEL" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"[cite: 1]
    
    info "Đang nạp driver cho model: $CHOSEN_MODEL..."[cite: 1]
    bash ./brinstaller "$CHOSEN_MODEL" || warn "Bộ cài Brother hoàn tất có cảnh báo."[cite: 1]
    cd /
  fi
fi

# 3. Quét và tự động thêm máy in (nếu CUPS chưa tự tạo hàng đợi)
systemctl restart cups
sleep 2

QUEUE_COUNT=$(lpstat -p 2>/dev/null | wc -l)

if [[ "$QUEUE_COUNT" -eq 0 ]]; then
  info "Chưa có hàng đợi nào, tiến hành quét tự động URI để tạo..."
  
  TARGET_URI=""
  # Dò IPP Everywhere trước
  DRIVERLESS_URI=$(driverless 2>/dev/null | head -n 1 || true)
  if [[ -n "$DRIVERLESS_URI" ]]; then
    TARGET_URI="$DRIVERLESS_URI"
  else
    # Dò qua lpinfo (ưu tiên USB)
    USB_URI=$(lpinfo -v 2>/dev/null | grep -Ei 'direct usb://' | head -n 1 | awk '{print $2}' || true)
    if [[ -n "$USB_URI" ]]; then
      TARGET_URI="$USB_URI"
    else
      TARGET_URI=$(lpinfo -v 2>/dev/null | grep -Ei 'dnssd://|ipp://|ipps://|socket://' | head -n 1 | awk '{print $2}' || true)
    fi
  fi

  if [[ -n "$TARGET_URI" ]]; then
    info "Thêm máy in từ URI: $TARGET_URI"
    PRINTER_NAME="MayInVanPhong"
    # Thử add qua everywhere hoặc tự gán driver tương thích
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E
    lpadmin -d "$PRINTER_NAME"
  else
    warn "Không phát hiện thấy URI nào đang kết nối. Vui lòng kiểm tra lại dây cáp hoặc nguồn điện máy in."
  fi
fi

# 4. Cấu hình in 2 mặt (Duplex) và Khổ giấy A4 cho tất cả hàng đợi
echo
info "Đang cấu hình Duplex (in 2 mặt) và Khổ giấy A4..."

mapfile -t ALL_QUEUES < <(lpstat -p 2>/dev/null | awk '{print $2}' | sort -u)

if [[ ${#ALL_QUEUES[@]} -eq 0 ]]; then
  warn "Chưa tạo được hàng đợi in nào."
else
  for QUEUE in "${ALL_QUEUES[@]}"; do
    echo "----------------------------------------"
    info "Đang thiết lập cho: $QUEUE"
    
    # Đặt kích thước khổ giấy mặc định là A4
    lpadmin -p "$QUEUE" -o PageSize=A4 2>/dev/null || true
    lpadmin -p "$QUEUE" -o media=A4 2>/dev/null || true
    
    # Thiết lập chuẩn IPP sides
    lpadmin -p "$QUEUE" -o sides=two-sided-long-edge 2>/dev/null || true
    
    # Dò sâu vào tùy chọn PPD của máy
    OPTIONS="$(lpoptions -p "$QUEUE" -l 2>&1 || true)"[cite: 1]
    
    if grep -qiE 'duplex|two[- ]sided|2[- ]sided' <<<"$OPTIONS"; then[cite: 1]
      DUPLEX_LINE="$(grep -Ei '^[^[:space:]]*(Duplex|two[- ]sided|2[- ]sided)[^:]*:' <<<"$OPTIONS" | head -n 1 || true)"[cite: 1]
      if [[ -n "$DUPLEX_LINE" ]]; then
        OPT_KEY="${DUPLEX_LINE%%:*}"[cite: 1]
        OPT_KEY="${OPT_KEY%%/*}"[cite: 1]
        OPT_VALS="${DUPLEX_LINE#*:}"[cite: 1]
        
        DUPLEX_VAL=""
        if grep -qE 'DuplexNoTumble' <<<"$OPT_VALS"; then[cite: 1]
          DUPLEX_VAL="DuplexNoTumble"[cite: 1]
        elif grep -qE 'LongEdge' <<<"$OPT_VALS"; then[cite: 1]
          DUPLEX_VAL="LongEdge"[cite: 1]
        elif grep -qE 'TwoSidedLongEdge' <<<"$OPT_VALS"; then
          DUPLEX_VAL="TwoSidedLongEdge"
        fi
        
        if [[ -n "$DUPLEX_VAL" ]]; then
          lpadmin -p "$QUEUE" -o "$OPT_KEY=$DUPLEX_VAL"[cite: 1]
          info "Đã kích hoạt Duplex qua PPD: $OPT_KEY=$DUPLEX_VAL"
        fi
      fi
    fi
    info "Hoàn tất cấu hình cho $QUEUE (A4 + 2 mặt lật cạnh dài)."
  done
fi

# 5. Đặt máy in mặc định (nếu chưa có)
CURRENT_DEF=$(lpstat -d 2>/dev/null | awk -F': ' '{print $2}' || true)
if [[ -z "$CURRENT_DEF" || "$CURRENT_DEF" == "no system default destination" ]] && [[ ${#ALL_QUEUES[@]} -gt 0 ]]; then
  lpadmin -d "${ALL_QUEUES[0]}"
  info "Đã đặt máy in mặc định là: ${ALL_QUEUES[0]}"
fi

echo
echo "============================================================"
info "ĐÃ HOÀN TẤT CÀI ĐẶT!"
echo "Danh sách hàng đợi hiện tại:"
lpstat -p -d[cite: 1]
echo
echo "Kiểm tra thuộc tính hàng đợi mặc định (A4 & Duplex):"
lpoptions -l | grep -Ei 'pagesize|media|duplex|sides' || true
echo
echo "Quản trị qua web: http://localhost:631/printers"[cite: 1]
echo "Log file: $LOG_FILE"[cite: 1, 2]
echo "============================================================"
