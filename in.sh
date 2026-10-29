#!/usr/bin/env bash
# ==============================================================================
# SCRIPT TỰ ĐỘNG DÒ TÌM & CÀI ĐẶT DRIVER MÁY IN BROTHER & HP (USB + LAN)
# TỰ ĐỘNG BẬT IN 2 MẶT, KHỔ GIẤY A4, TƯƠNG THÍCH HOÀN TOÀN WPS OFFICE
# Hỗ trợ: Linux Mint, Ubuntu, Debian
# Cập nhật 29/10/2026
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
echo " TỰ ĐỘNG DÒ & CÀI ĐẶT MÁY IN BROTHER / HP (A4 & IN 2 MẶT)"
echo "============================================================"

export DEBIAN_FRONTEND=noninteractive

# 1. Cài đặt toàn bộ driver và gói công cụ quét mạng
info "Đang cập nhật driver HP, Brother và công cụ dò quét..."
apt-get update -qq

apt-get install -y \
  cups cups-client cups-filters cups-ipp-utils \
  printer-driver-brlaser \
  printer-driver-hpcups hplip hplip-data printer-driver-postscript-hp \
  printer-driver-escpr printer-driver-gutenprint printer-driver-foo2zjs \
  avahi-daemon avahi-utils usbutils iproute2 nmap curl -qq

# Vô hiệu hóa cups-browsed để triệt tiêu máy in ma gây lỗi WPS Office
systemctl stop cups-browsed 2>/dev/null || true
systemctl disable cups-browsed 2>/dev/null || true
systemctl enable --now cups avahi-daemon
sleep 1

# Hủy các lệnh in kẹt cũ
cancel -a -x 2>/dev/null || true

# 2. Dò tìm máy in (USB -> mDNS -> Quét IP LAN xác thực HTTP)
info "Bắt đầu dò tìm máy in văn phòng..."
TARGET_URI=""
PRINTER_BRAND="generic"
PRINTER_MODEL=""

# --- TẦNG 1: CỔNG CẮM USB TRỰC TIẾP ---
USB_URI=$(timeout 3 lpinfo -v 2>/dev/null | grep -Ei 'direct usb://' | head -n 1 | awk '{print $2}' || true)
if [[ -n "$USB_URI" ]]; then
  TARGET_URI="$USB_URI"
  info "Phát hiện máy in cắm qua cáp USB: $TARGET_URI"
  USB_INFO=$(lsusb 2>/dev/null || true)
  if echo "$USB_INFO" | grep -qi "Brother"; then
    PRINTER_BRAND="brother"
  elif echo "$USB_INFO" | grep -qi "Hewlett-Packard\|HP"; then
    PRINTER_BRAND="hp"
    PRINTER_MODEL=$(echo "$USB_URI" | sed -n 's/.*m=\([^&]*\).*/\1/p' || true)
  fi
fi

# --- TẦNG 2: MẠNG MDNS (DRIVERLESS) ---
if [[ -z "$TARGET_URI" ]]; then
  DRIVERLESS_URI=$(timeout 3 driverless 2>/dev/null | head -n 1 || true)
  if [[ -n "$DRIVERLESS_URI" ]]; then
    TARGET_URI="$DRIVERLESS_URI"
    info "Phát hiện máy in mạng qua mDNS: $TARGET_URI"
    if [[ "$DRIVERLESS_URI" =~ [Bb]rother ]]; then PRINTER_BRAND="brother"; fi
    if [[ "$DRIVERLESS_URI" =~ [Hh][Pp] ]]; then PRINTER_BRAND="hp"; fi
  fi
fi

# --- TẦNG 3: QUÉT MẠNG LAN CỔNG 9100 & XÁC THỰC DANH TÍNH ---
if [[ -z "$TARGET_URI" ]]; then
  info "Đang quét và xác thực thiết bị in trong mạng LAN..."
  LOCAL_SUBNET=$(ip route show default 2>/dev/null | awk '{print $3}' | cut -d. -f1-3 || true)
  
  if [[ -n "$LOCAL_SUBNET" ]]; then
    mapfile -t CANDIDATE_IPS < <(nmap -p 9100 --open -T4 "${LOCAL_SUBNET}.0/24" -oG - 2>/dev/null | awk '/9100\/open/{print $2}' || true)
    
    for IP in "${CANDIDATE_IPS[@]}"; do
      [[ -n "$IP" ]] || continue
      
      # Đọc thông tin thiết bị qua HTTP Port 80
      PAGE_INFO=$(curl -s -L --connect-timeout 2 --max-time 3 "http://${IP}" 2>/dev/null || true)
      
      if echo "$PAGE_INFO" | grep -qi "Brother"; then
        TARGET_URI="socket://${IP}:9100"
        PRINTER_BRAND="brother"
        info "ĐÃ TÌM THẤY MÁY IN BROTHER TẠI IP: $IP"
        break
      elif echo "$PAGE_INFO" | grep -qi "Hewlett-Packard\|HP LaserJet\|HP PageWide"; then
        TARGET_URI="socket://${IP}:9100"
        PRINTER_BRAND="hp"
        info "ĐÃ TÌM THẤY MÁY IN HP TẠI IP: $IP"
        break
      fi
    done
  fi
fi

# 3. Tạo hàng đợi và chỉ định driver phù hợp theo hãng
if [[ -n "$TARGET_URI" ]]; then
  # Xóa các hàng đợi lỗi cũ
  lpadmin -x "Brother_HL_L2360D_series" 2>/dev/null || true
  lpadmin -x "MayInVanPhong" 2>/dev/null || true
  
  if [[ "$PRINTER_BRAND" == "brother" ]]; then
    PRINTER_NAME="Brother-Printer"
    lpadmin -x "$PRINTER_NAME" 2>/dev/null || true
    info "Đang thiết lập hàng đợi $PRINTER_NAME..."
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m drv:///brlaser.drv/brl2360d.ppd 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E

  elif [[ "$PRINTER_BRAND" == "hp" ]]; then
    PRINTER_NAME="HP-Printer"
    lpadmin -x "$PRINTER_NAME" 2>/dev/null || true
    info "Đang thiết lập hàng đợi $PRINTER_NAME..."
    
    # Tự động tìm file PPD hpcups thích hợp nhất trong hệ thống
    HP_PPD=""
    if [[ -n "$PRINTER_MODEL" ]]; then
      HP_PPD=$(lpinfo -m 2>/dev/null | grep -i "hpcups" | grep -i "$PRINTER_MODEL" | head -n 1 | awk '{print $1}' || true)
    fi
    if [[ -z "$HP_PPD" ]]; then
      HP_PPD=$(lpinfo -m 2>/dev/null | grep -iE 'hp-laserjet.*hpcups' | head -n 1 | awk '{print $1}' || true)
    fi

    if [[ -n "$HP_PPD" ]]; then
      lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m "$HP_PPD" 2>/dev/null || \
      lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
      lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E
    else
      lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
      lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E
    fi
  else#!/usr/bin/env bash
# ==============================================================================
# SCRIPT CÀI ĐẶT DRIVER TẤT CẢ CÁC HÃNG & TỰ ĐỘNG DÒ CHÍNH XÁC MÁY IN BROTHER / HP
# Tương thích: Linux Mint, Ubuntu, Debian, WPS Office, LibreOffice
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

LOG_FILE="/var/log/all-printer-setup.log"

info()  { echo -e "\e[32m[INFO]\e[0m $*"; }
warn()  { echo -e "\e[33m[CẢNH BÁO]\e[0m $*" >&2; }
die()   { echo -e "\e[31m[LỖI]\e[0m $*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  die "Vui lòng chạy với quyền root: sudo bash $0"
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================================"
echo " TỰ ĐỘNG DÒ VÀ CÀI ĐẶT MÁY IN CHUẨN XÁC CHO MẠNG VĂN PHÒNG"
echo "============================================================"

export DEBIAN_FRONTEND=noninteractive

# 1. Cài đặt các gói driver cần thiết và công cụ mạng
info "Đang cập nhật và cài đặt driver cùng công cụ mạng..."
apt-get update -qq

apt-get install -y \
  cups cups-client cups-filters cups-ipp-utils \
  printer-driver-brlaser \
  printer-driver-hpcups hplip hplip-data \
  printer-driver-escpr printer-driver-gutenprint printer-driver-foo2zjs \
  avahi-daemon avahi-utils usbutils iproute2 nmap curl -qq

# Tắt cups-browsed để tránh sinh máy in ma gây lỗi WPS Office
systemctl stop cups-browsed 2>/dev/null || true
systemctl disable cups-browsed 2>/dev/null || true
systemctl enable --now cups avahi-daemon
sleep 1

# Hủy tất cả các lệnh in bị kẹt trước đó
cancel -a -x 2>/dev/null || true

# 2. Dò tìm máy in (Cổng USB -> mDNS -> Quét IP có xác thực danh tính)
info "Bắt đầu dò tìm máy in..."
TARGET_URI=""
PRINTER_BRAND="generic"

# Ưu tiên 1: Cổng USB cắm trực tiếp
USB_URI=$(timeout 3 lpinfo -v 2>/dev/null | grep -Ei 'direct usb://' | head -n 1 | awk '{print $2}' || true)
if [[ -n "$USB_URI" ]]; then
  TARGET_URI="$USB_URI"
  info "Phát hiện máy in cắm qua cáp USB: $TARGET_URI"
  if lsusb 2>/dev/null | grep -qi "Brother"; then PRINTER_BRAND="brother"; fi

    PRINTER_NAME="VanPhong-Printer"
    lpadmin -x "$PRINTER_NAME" 2>/dev/null || true
    info "Đang thiết lập hàng đợi $PRINTER_NAME..."
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E
  fi

  # Kích hoạt hàng đợi và gán làm mặc định
  lpadmin -d "$PRINTER_NAME"
  cupsenable "$PRINTER_NAME"
  cupsaccept "$PRINTER_NAME"

  # Cấu hình Khổ giấy A4 và In 2 mặt (Duplex)
  info "Đang áp dụng cấu hình khổ giấy A4 và in 2 mặt mặc định..."
  lpadmin -p "$PRINTER_NAME" -o PageSize=A4 -o media=A4
  lpadmin -p "$PRINTER_NAME" -o sides=two-sided-long-edge
  lpadmin -p "$PRINTER_NAME" -o Duplex=DuplexNoTumble
  lpadmin -p "$PRINTER_NAME" -o BRDuplex=DuplexNoTumble
  lpadmin -p "$PRINTER_NAME" -o HPDuplex=DuplexNoTumble
  lpadmin -p "$PRINTER_NAME" -o DuplexUnit=Installed

  info "Hoàn tất cài đặt máy in mặc định: $PRINTER_NAME"
else
  warn "Không phát hiện thấy máy in Brother/HP nào đang kết nối (USB hoặc LAN)."
fi

# 4. Dọn dẹp cache in của WPS Office trên tất cả tài khoản
for USER_HOME in /home/*; do
  if [[ -d "$USER_HOME/.config/Kingsoft" ]]; then
    rm -rf "$USER_HOME/.config/Kingsoft/wps/printer"* 2>/dev/null || true
    rm -rf "$USER_HOME/.config/Kingsoft/Office/printer"* 2>/dev/null || true
    rm -rf "$USER_HOME/.config/Kingsoft/wps/et/printer"* 2>/dev/null || true
  fi
done

systemctl restart cups
sleep 1

echo
echo "============================================================"
info "CÀI ĐẶT HOÀN TẤT!"
echo "Danh sách hàng đợi hiện có:"
lpstat -p -d 2>/dev/null || true
echo
echo "Kiểm tra kết nối thiết bị:"
lpstat -v 2>/dev/null || true
echo "============================================================"
