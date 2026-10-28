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

# 1. Cài đặt toàn bộ driver hệ thống từ repository
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

TARGET_URI=""
DRIVERLESS_URI=$(driverless 2>/dev/null | head -n 1 || true)
if [[ -n "$DRIVERLESS_URI" ]]; then
  TARGET_URI="$DRIVERLESS_URI"
  info "Phát hiện máy in mạng (Driverless): $TARGET_URI"
else
  USB_URI=$(lpinfo -v 2>/dev/null | grep -Ei 'direct usb://' | head -n 1 | awk '{print $2}' || true)
  if [[ -n "$USB_URI" ]]; then
    TARGET_URI="$USB_URI"
    info "Phát hiện máy in cắm cáp USB: $TARGET_URI"
  else
    NET_URI=$(lpinfo -v 2>/dev/null | grep -Ei 'dnssd://|ipp://|ipps://|socket://' | head -n 1 | awk '{print $2}' || true)
    if [[ -n "$NET_URI" ]]; then
      TARGET_URI="$NET_URI"
      info "Phát hiện máy in mạng CUPS: $TARGET_URI"
    fi
  fi
fi

PRINTER_NAME="MayInVanPhong"

if [[ -n "$TARGET_URI" ]]; then
  if [[ "$TARGET_URI" =~ [Bb]rother ]] || lsusb 2>/dev/null | grep -qi "Brother"; then
    info "Áp dụng cấu hình tương thích cho dòng Brother..."
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m drv:///brlaser.drv/brl2360d.ppd 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E
  else
    info "Tạo hàng đợi in cho máy..."
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E
  fi
  lpadmin -d "$PRINTER_NAME"
  info "Đã tạo máy in mặc định: $PRINTER_NAME"
else
  warn "Không tìm thấy thiết bị mới đang kết nối. Tiếp tục cấu hình các hàng đợi hiện có."
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
    
    # Bật in 2 mặt cạnh dài chuẩn IPP / Driverless
    lpadmin -p "$QUEUE" -o sides=two-sided-long-edge 2>/dev/null || true
    
    # Bật in 2 mặt cho các máy dùng driver PPD truyền thống (Brother / HP)
    lpadmin -p "$QUEUE" -o Duplex=DuplexNoTumble 2>/dev/null || true
    lpadmin -p "$QUEUE" -o BRDuplex=DuplexNoTumble 2>/dev/null || true
    lpadmin -p "$QUEUE" -o HPDuplex=DuplexNoTumble 2>/dev/null || true
    
    info "Hoàn tất: $QUEUE sẵn sàng in 2 mặt & khổ A4."
  done
fi

# 4. Đặt máy in mặc định
CURRENT_DEF=$(lpstat -d 2>/dev/null | awk -F': ' '{print $2}' || true)
if [[ -z "$CURRENT_DEF" || "$CURRENT_DEF" == "no system default destination" ]] && [[ ${#ALL_QUEUES[@]} -gt 0 ]]; then
  if [[ -n "${ALL_QUEUES[0]:-}" ]]; then
    lpadmin -d "${ALL_QUEUES[0]}"
    info "Đã gán máy in mặc định: ${ALL_QUEUES[0]}"
  fi
fi

echo
echo "============================================================"
info "CÀI ĐẶT HOÀN TẤT!"
echo "Danh sách hàng đợi hiện có:"
lpstat -p -d 2>/dev/null || true
echo
echo "Kiểm tra thuộc tính in 2 mặt & khổ A4 của máy mặc định:"
lpoptions -l 2>/dev/null | grep -Ei 'pagesize|media|duplex|sides' || true
echo
echo "Giao diện CUPS: http://localhost:631/printers"
echo "Log: $LOG_FILE"
echo "============================================================"
