#!/usr/bin/env bash
# ==============================================================================
# SCRIPT CÀI FULL DRIVER, TỰ ĐỘNG THÊM MÁY IN & BẬT 2 MẶT / A4 (100% AUTOMATION)
# Tương thích: Linux Mint, Ubuntu, Debian
# Chạy trực tiếp: curl -fsSL <URL> | sudo bash
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

LOG_FILE="/var/log/all-printer-setup.log"

info()  { echo -e "\e[32m[INFO]\e[0m $*"; }
warn()  { echo -e "\e[33m[CẢNH BÁO]\e[0m $*" >&2; }
die()   { echo -e "\e[31m[LỖI]\e[0m $*" >&2; exit 1; }

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

# 1. Cài đặt toàn bộ driver hệ thống từ repository (Bao gồm brlaser, hplip, gutenprint)
info "Đang cài đặt đầy đủ bộ driver hệ thống..."
apt-get update -qq
apt-get install -y \
  cups cups-client cups-filters cups-ipp-utils \
  printer-driver-all \
  printer-driver-brlaser \
  printer-driver-hpcups hplip hplip-data \
  printer-driver-gutenprint \
  foomatic-db-compressed-ppds \
  openprinting-ppds \
  avahi-daemon avahi-utils \
  usbutils -qq

systemctl enable --now cups avahi-daemon
sleep 2

# 2. Quét và tự động thêm máy in vào CUPS
info "Đang quét và thêm máy in vào hệ thống..."
systemctl restart cups
sleep 2

# Tìm URI thiết bị
TARGET_URI=""
# Ưu tiên 1: Driverless IPP (Mạng LAN / Wi-Fi)
DRIVERLESS_URI=$(driverless 2>/dev/null | head -n 1 || true)
if [[ -n "$DRIVERLESS_URI" ]]; then
  TARGET_URI="$DRIVERLESS_URI"
  info "Phát hiện máy in mạng (Driverless): $TARGET_URI"
else
  # Ưu tiên 2: Cổng USB
  USB_URI=$(lpinfo -v 2>/dev/null | grep -Ei 'direct usb://' | head -n 1 | awk '{print $2}' || true)
  if [[ -n "$USB_URI" ]]; then
    TARGET_URI="$USB_URI"
    info "Phát hiện máy in cắm cáp USB: $TARGET_URI"
  else
    # Ưu tiên 3: Giao thức mạng khác
    NET_URI=$(lpinfo -v 2>/dev/null | grep -Ei 'dnssd://|ipp://|ipps://|socket://' | head -n 1 | awk '{print $2}' || true)
    if [[ -n "$NET_URI" ]]; then
      TARGET_URI="$NET_URI"
      info "Phát hiện máy in mạng CUPS: $TARGET_URI"
    fi
  fi
fi

PRINTER_NAME="MayInVanPhong"

if [[ -n "$TARGET_URI" ]]; then
  # Nếu là máy in Brother cắm USB, ưu tiên gán driver brlaser
  if [[ "$TARGET_URI" =~ brother ]] || lsusb 2>/dev/null | grep -qi "Brother"; then
    info "Áp dụng driver Brother tương thích tự động (brlaser)..."
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m drv:///brlaser.drv/brl2360d.ppd 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E
  else
    info "Tạo hàng đợi in cho máy..."
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E
  fi
  lpadmin -d "$PRINTER_NAME"
  info "Đã tạo máy in: $PRINTER_NAME"
else
  warn "Không tìm thấy thiết bị máy in nào đang kết nối. Vẫn tiến hành cấu hình hàng đợi hiện có (nếu có)."
fi

# 3. Cấu hình in 2 mặt (Duplex) và Khổ giấy A4 cho tất cả các máy
echo
info "Đang cấu hình Duplex (in 2 mặt) và Khổ giấy A4..."

mapfile -t ALL_QUEUES < <(lpstat -p 2>/dev/null | awk '{print $2}' | sort -u || true)

if [[ ${#ALL_QUEUES[@]} -eq 0 ]]; then
  warn "Chưa có hàng đợi nào trong hệ thống để áp dụng cấu hình."
else
  for QUEUE in "${ALL_QUEUES[@]}"; do
    [[ -n "$QUEUE" ]] || continue
    echo "----------------------------------------"
    info "Cấu hình cho máy in: $QUEUE"
    
    # Ép khổ giấy A4
    lpadmin -p "$QUEUE" -o PageSize=A4 2>/dev/null || true
    lpadmin -p "$QUEUE" -o media=A4 2>/dev/null || true
    
    # Ép in 2 mặt theo chuẩn IPP
    lpadmin -p "$QUEUE" -o sides=two-sided-long-edge 2>/dev/null || true
    
    # Kiểm tra PPD để ép lệnh lật cạnh dài cấp phần cứng
    OPTIONS="$(lpoptions -p "$QUEUE
