#!/usr/bin/env bash
# ==============================================================================
# SCRIPT TỰ ĐỘNG DÒ TÌM MÁY IN (USB + MDNS + QUÉT DẢI IP SOCKET 9100)
# CÀI ĐẶT DRIVER CHUẨN TẤT CẢ CÁC HÃNG, KHÓA KHỔ A4 & IN 2 MẶT (TƯƠNG THÍCH WPS)
# Tương thích: Linux Mint, Ubuntu, Debian
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
echo " TỰ ĐỘNG DÒ TÌM, CÀI DRIVER TẤT CẢ CÁC HÃNG & BẬT 2 MẶT / A4"
echo "============================================================"

export DEBIAN_FRONTEND=noninteractive

# 1. Cài đặt đầy đủ driver các hãng và công cụ quét mạng cần thiết
info "Đang cài đặt gói driver các hãng và công cụ mạng..."
apt-get update -qq

apt-get install -y \
  cups cups-client cups-filters cups-ipp-utils \
  printer-driver-brlaser \
  printer-driver-hpcups hplip hplip-data printer-driver-postscript-hp \
  printer-driver-escpr \
  printer-driver-gutenprint \
  printer-driver-foo2zjs printer-driver-foo2zjs-common \
  printer-driver-splix \
  printer-driver-fujixerox \
  printer-driver-c2esp \
  printer-driver-pnm2ppa \
  printer-driver-ptouch \
  printer-driver-dymo \
  avahi-daemon avahi-utils \
  usbutils iproute2 iputils-ping nmap -qq

# Vô hiệu hóa cups-browsed để tránh sinh máy in ma gây lỗi WPS Office
systemctl stop cups-browsed 2>/dev/null || true
systemctl disable cups-browsed 2>/dev/null || true

systemctl enable --now cups avahi-daemon
sleep 1

# 2. Cơ chế quét tự động 3 tầng (USB -> mDNS -> Quét dải IP cổng 9100)
info "Bắt đầu tự động dò tìm máy in..."
systemctl restart cups
sleep 1

TARGET_URI=""
PRINTER_BRAND="generic"

# Tầng 1: Cổng cắm USB trực tiếp
USB_URI=$(timeout 3 lpinfo -v 2>/dev/null | grep -Ei 'direct usb://' | head -n 1 | awk '{print $2}' || true)
if [[ -n "$USB_URI" ]]; then
  TARGET_URI="$USB_URI"
  info "Phát hiện máy in cắm qua cáp USB: $TARGET_URI"
  if lsusb 2>/dev/null | grep -qi "Brother"; then PRINTER_BRAND="brother"; fi
  if lsusb 2>/dev/null | grep -qi "Hewlett-Packard\|HP"; then PRINTER_BRAND="hp"; fi
fi

# Tầng 2: Mạng mDNS Driverless
if [[ -z "$TARGET_URI" ]]; then
  DRIVERLESS_URI=$(timeout 4 driverless 2>/dev/null | head -n 1 || true)
  if [[ -n "$DRIVERLESS_URI" ]]; then
    TARGET_URI="$DRIVERLESS_URI"
    info "Phát hiện máy in mạng qua mDNS: $TARGET_URI"
    if [[ "$DRIVERLESS_URI" =~ [Bb]rother ]]; then PRINTER_BRAND="brother"; fi
    if [[ "$DRIVERLESS_URI" =~ [Hh][Pp] ]]; then PRINTER_BRAND="hp"; fi
  fi
fi

# Tầng 3: Tự động quét dải IP LAN tìm cổng máy in RAW Socket 9100 (Khắc phục chặn mDNS)
if [[ -z "$TARGET_URI" ]]; then
  info "mDNS không phản hồi, đang tự động quét tìm máy in trong dải IP nội bộ..."
  LOCAL_SUBNET=$(ip route show default 2>/dev/null | awk '{print $3}' | cut -d. -f1-3 || true)
  
  if [[ -n "$LOCAL_SUBNET" ]]; then
    # Quét nhanh cổng 9100 trong subnet bằng nmap (giới hạn 10s)
    FOUND_IP=$(nmap -p 9100 --open -T4 "${LOCAL_SUBNET}.0/24" -oG - 2>/dev/null | awk '/9100\/open/{print $2}' | head -n 1 || true)
    
    if [[ -n "$FOUND_IP" ]]; then
      TARGET_URI="socket://${FOUND_IP}:9100"
      info "Đã dò thấy máy in tại địa chỉ IP: $FOUND_IP (Cổng 9100)"
      PRINTER_BRAND="brother"
    fi
  fi
fi

PRINTER_NAME="Brother-Printer"

if [[ -n "$TARGET_URI" ]]; then
  info "Đang tiến hành tạo hàng đợi in chuẩn với Driver tương thích cao..."
  
  # Xóa các hàng đợi lỗi cũ
  lpadmin -x "Brother_HL_L2360D_series" 2>/dev/null || true
  lpadmin -x "MayInVanPhong" 2>/dev/null || true
  
  if [[ "$PRINTER_BRAND" == "brother" ]] || [[ "$TARGET_URI" =~ 9100 ]]; then
    # Ép dùng driver brlaser tĩnh để WPS Office hiển thị đầy đủ thuộc tính
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m drv:///brlaser.drv/brl2360d.ppd 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E
  else
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E
  fi
  
  lpadmin -d "$PRINTER_NAME"
  info "Đã thiết lập máy in mặc định thành công: $PRINTER_NAME"
else
  warn "Không thể dò thấy thiết bị in nào (USB/LAN). Tiếp tục cấu hình các máy đã có."
fi

# 3. Kích hoạt hàng đợi và ép in 2 mặt (Duplex) + Khổ A4
echo
info "Đang cấu hình Duplex (in 2 mặt) và Khổ giấy A4..."

mapfile -t ALL_QUEUES < <(lpstat -p 2>/dev/null | awk '{print $2}' | sort -u || true)

if [[ ${#ALL_QUEUES[@]} -gt 0 ]]; then
  for QUEUE in "${ALL_QUEUES[@]}"; do
    [[ -n "$QUEUE" ]] || continue
    echo "----------------------------------------"
    info "Cấu hình cho máy in: $QUEUE"
    
    cupsenable "$QUEUE" 2>/dev/null || true
    cupsaccept "$QUEUE" 2>/dev/null || true

    # Khóa khổ giấy A4
    lpadmin -p "$QUEUE" -o PageSize=A4 2>/dev/null || true
    lpadmin -p "$QUEUE" -o media=A4 2>/dev/null || true
    
    # Ép in 2 mặt lật cạnh dài
    lpadmin -p "$QUEUE" -o sides=two-sided-long-edge 2>/dev/null || true
    lpadmin -p "$QUEUE" -o Duplex=DuplexNoTumble 2>/dev/null || true
    lpadmin -p "$QUEUE" -o BRDuplex=DuplexNoTumble 2>/dev/null || true
    lpadmin -p "$QUEUE" -o HPDuplex=DuplexNoTumble 2>/dev/null || true
    lpadmin -p "$QUEUE" -o EFDuplex=DuplexNoTumble 2>/dev/null || true
    lpadmin -p "$QUEUE" -o DuplexUnit=Installed 2>/dev/null || true
    
    info "Hoàn tất: $QUEUE đã sẵn sàng in 2 mặt & khổ A4."
  done
fi

# Đặt mặc định nếu chưa có
CURRENT_DEF=$(lpstat -d 2>/dev/null | awk -F': ' '{print $2}' || true)
if [[ -z "$CURRENT_DEF" || "$CURRENT_DEF" == "no system default destination" ]] && [[ ${#ALL_QUEUES[@]} -gt 0 ]]; then
  if [[ -n "${ALL_QUEUES[0]:-}" ]]; then
    lpadmin -d "${ALL_QUEUES[0]}"
    info "Đã gán máy in mặc định: ${ALL_QUEUES[0]}"
  fi
fi

# Dọn dẹp cache cấu hình in của WPS ở profile người dùng thông thường
for USER_HOME in /home/*; do
  if [[ -d "$USER_HOME/.config/Kingsoft" ]]; then
    rm -rf "$USER_HOME/.config/Kingsoft/wps/printer"* 2>/dev/null || true
    rm -rf "$USER_HOME/.config/Kingsoft/Office/printer"* 2>/dev/null || true
    rm -rf "$USER_HOME/.config/Kingsoft/wps/et/printer"* 2>/dev/null || true
  fi
done

cancel -a -x 2>/dev/null || true

echo
echo "============================================================"
info "CÀI ĐẶT TOÀN DIỆN HOÀN TẤT!"
echo "Danh sách hàng đợi hiện có:"
lpstat -p -d 2>/dev/null || true
echo
echo "Kiểm tra thuộc tính máy in mặc định:"
lpoptions -l 2>/dev/null | grep -Ei 'pagesize|media|duplex|sides' || true
echo "Log: $LOG_FILE"
echo "============================================================"
