#!/usr/bin/env bash
# ==============================================================================
# SCRIPT CÀI FULL DRIVER (HP, BROTHER, CANON, GENERIC), AUTO-ADD & CẤU HÌNH DUPLEX/A4
# Tương thích: Linux Mint, Ubuntu, Debian
# Hỗ trợ chạy trực tiếp: curl -fsSL <URL> | sudo bash
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

LOG_FILE="/var/log/all-printer-setup.log"
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

# 1. Cài đặt toàn bộ driver hệ thống từ repository
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

# 2. Xử lý driver Brother chính thức (nếu phát hiện máy Brother)
IS_BROTHER=0
if lsusb 2>/dev/null | grep -qi "Brother"; then
  IS_BROTHER=1
elif lpinfo -v 2>/dev/null | grep -qi "Brother"; then
  IS_BROTHER=1
fi

if [[ "$IS_BROTHER" -eq 1 ]]; then
  info "Phát hiện máy in Brother. Tiến hành nạp bộ cài chính thức..."
  TEMP_DIR="$(mktemp -d -t brother-pkg-XXXXXXXX)"
  cd "$TEMP_DIR"
  INSTALLER_URL="https://download.brother.com/welcome/dlf006893/linux-brprinter-installer-2.2.4-1.gz"
  
  if wget --https-only --timeout=30 -O brinstaller.gz "$INSTALLER_URL"; then
    gunzip -f brinstaller.gz
    chmod 700 brinstaller
    
    # Tự động trích xuất model từ lsusb nếu có
    DETECTED_MODEL=$(lsusb 2>/dev/null | grep -i "Brother" | head -n 1 | sed -E 's/.*Brother Industries, Ltd (.*)/\1/' | tr -d ' ' || true)
    
    # Tự động chọn model: ưu tiên model cắm USB, mặc định là HL-L2360D
    CHOSEN_MODEL="${DETECTED_MODEL:-HL-L2360D}"
    CHOSEN_MODEL="$(echo "$CHOSEN_MODEL" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
    
    info "Tự động cài đặt driver cho model: $CHOSEN_MODEL..."
    
    # Chạy tự động: truyền 'yes' vào bộ cài và thêm cờ -y để không bị hỏi xác nhận
    yes | bash ./brinstaller -y "$CHOSEN_MODEL" || warn "Bộ cài Brother hoàn tất với cảnh báo."
  else
    warn "Không thể tải bộ cài Brother từ internet."
  fi
  cd /
fi

# 3. Quét và tự động thêm máy in nếu CUPS chưa tạo hàng đợi
systemctl restart cups
sleep 2

QUEUE_COUNT=$(lpstat -p 2>/dev/null | wc -l || echo "0")

if [[ "$QUEUE_COUNT" -eq 0 ]]; then
  info "Chưa có hàng đợi nào, tiến hành quét tự động kết nối..."
  TARGET_URI=""
  
  # Dò IPP Everywhere / Driverless trước
  DRIVERLESS_URI=$(driverless 2>/dev/null | head -n 1 || true)
  if [[ -n "$DRIVERLESS_URI" ]]; then
    TARGET_URI="$DRIVERLESS_URI"
  else
    # Dò qua cổng USB trước
    USB_URI=$(lpinfo -v 2>/dev/null | grep -Ei 'direct usb://' | head -n 1 | awk '{print $2}' || true)
    if [[ -n "$USB_URI" ]]; then
      TARGET_URI="$USB_URI"
    else
      # Dò qua kết nối mạng
      TARGET_URI=$(lpinfo -v 2>/dev/null | grep -Ei 'dnssd://|ipp://|ipps://|socket://' | head -n 1 | awk '{print $2}' || true)
    fi
  fi

  if [[ -n "$TARGET_URI" ]]; then
    info "Thêm hàng đợi từ URI: $TARGET_URI"
    PRINTER_NAME="MayInVanPhong"
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E
    lpadmin -d "$PRINTER_NAME"
  else
    warn "Không phát hiện thấy cổng in đang cắm. Vui lòng kiểm tra lại dây cáp hoặc nguồn điện máy in."
  fi
fi

# 4. Cấu hình in 2 mặt (Duplex) và Khổ giấy A4 cho tất cả hàng đợi
echo
info "Đang cấu hình Duplex (in 2 mặt) và Khổ giấy A4..."

mapfile -t ALL_QUEUES < <(lpstat -p 2>/dev/null | awk '{print $2}' | sort -u || true)

if [[ ${#ALL_QUEUES[@]} -eq 0 ]]; then
  warn "Chưa có hàng đợi in nào để cấu hình."
else
  for QUEUE in "${ALL_QUEUES[@]}"; do
    [[ -n "$QUEUE" ]] || continue
    echo "----------------------------------------"
    info "Đang cấu hình: $QUEUE"
    
    # 4.1. Khóa khổ giấy A4
    lpadmin -p "$QUEUE" -o PageSize=A4 2>/dev/null || true
    lpadmin -p "$QUEUE" -o media=A4 2>/dev/null || true
    
    # 4.2. Cấu hình IPP standard
    lpadmin -p "$QUEUE" -o sides=two-sided-long-edge 2>/dev/null || true
    
    # 4.3. Quét và ép tùy chọn PPD phần cứng
    OPTIONS="$(lpoptions -p "$QUEUE" -l 2>&1 || true)"
    if grep -qiE 'duplex|two[- ]sided|2[- ]sided' <<<"$OPTIONS"; then
      DUPLEX_LINE="$(grep -Ei '^[^[:space:]]*(Duplex|two[- ]sided|2[- ]sided)[^:]*:' <<<"$OPTIONS" | head -n 1 || true)"
      if [[ -n "$DUPLEX_LINE" ]]; then
        OPT_KEY="${DUPLEX_LINE%%:*}"
        OPT_KEY="${OPT_KEY%%/*}"
        OPT_VALS="${DUPLEX_LINE#*:}"
        
        DUPLEX_VAL=""
        if grep -qE 'DuplexNoTumble' <<<"$OPT_VALS"; then
          DUPLEX_VAL="DuplexNoTumble"
        elif grep -qE 'LongEdge' <<<"$OPT_VALS"; then
          DUPLEX_VAL="LongEdge"
        elif grep -qE 'TwoSidedLongEdge' <<<"$OPT_VALS"; then
          DUPLEX_VAL="TwoSidedLongEdge"
        fi
        
        if [[ -n "$DUPLEX_VAL" ]]; then
          lpadmin -p "$QUEUE" -o "$OPT_KEY=$DUPLEX_VAL"
          info "Đã bật Duplex phần cứng: $OPT_KEY=$DUPLEX_VAL"
        fi
      fi
    fi
    info "Đã hoàn thành thiết lập cho $QUEUE (Khổ A4, 2 mặt lật cạnh dài)."
  done
fi

# 5. Đảm bảo có máy in mặc định
CURRENT_DEF=$(lpstat -d 2>/dev/null | awk -F': ' '{print $2}' || true)
if [[ -z "$CURRENT_DEF" || "$CURRENT_DEF" == "no system default destination" ]] && [[ ${#ALL_QUEUES[@]} -gt 0 ]]; then
  if [[ -n "${ALL_QUEUES[0]:-}" ]]; then
    lpadmin -d "${ALL_QUEUES[0]}"
    info "Đã gán máy in mặc định: ${ALL_QUEUES[0]}"
  fi
fi

echo
echo "============================================================"
info "HOÀN TẤT THIẾT LẬP HỆ THỐNG MÁY IN!"
echo "Danh sách hàng đợi hiện tại:"
lpstat -p -d 2>/dev/null || true
echo
echo "Cấu hình in 2 mặt & khổ giấy máy in mặc định:"
lpoptions -l 2>/dev/null | grep -Ei 'pagesize|media|duplex|sides' || true
echo
echo "Giao diện CUPS web: http://localhost:631/printers"
echo "File nhật ký: $LOG_FILE"
echo "============================================================"
