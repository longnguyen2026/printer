#!/usr/bin/env bash
# ==============================================================================
# SCRIPT TỰ ĐỘNG DÒ VÀ THIẾT LẬP MÁY IN BROTHER & HP (USB, CUPS SHARE, LAN)
# TỰ ĐỘNG KHÓA KHỔ A4, IN 2 MẶT (DUPLEX), TƯƠNG THÍCH HOÀN TOÀN WPS OFFICE
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
echo " DÒ TÌM & THIẾT LẬP MÁY IN HP / BROTHER KHẢ DỤNG TRONG MẠNG"
echo "============================================================"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y \
  cups cups-client cups-filters cups-ipp-utils \
  printer-driver-brlaser \
  printer-driver-hpcups hplip hplip-data printer-driver-postscript-hp \
  avahi-daemon avahi-utils usbutils iproute2 nmap curl -qq

# Tắt cups-browsed để tránh sinh máy in ma ảo
systemctl stop cups-browsed 2>/dev/null || true
systemctl disable cups-browsed 2>/dev/null || true
systemctl enable --now cups avahi-daemon
sleep 1

cancel -a -x 2>/dev/null || true

FOUND_HP_URI=""
FOUND_BROTHER_URI=""

# ------------------------------------------------------------------------------
# 1. CỔNG USB CẮM TRỰC TIẾP
# ------------------------------------------------------------------------------
USB_DEV=$(lpinfo -v 2>/dev/null | grep -Ei 'direct usb://' | head -n 1 | awk '{print $2}' || true)
if [[ -n "$USB_DEV" ]]; then
  USB_LIST=$(lsusb 2>/dev/null || true)
  if echo "$USB_LIST" | grep -qiE "Hewlett-Packard|HP"; then
    FOUND_HP_URI="$USB_DEV"
    info "Phát hiện máy in HP cắm cáp USB: $FOUND_HP_URI"
  elif echo "$USB_LIST" | grep -qi "Brother"; then
    FOUND_BROTHER_URI="$USB_DEV"
    info "Phát hiện máy in Brother cắm cáp USB: $FOUND_BROTHER_URI"
  fi
fi

# ------------------------------------------------------------------------------
# 2. DÒ QUA DRIVERLESS / IPP / DNS-SD (LẤY MÁY ONLINE THỰC SỰ)
# ------------------------------------------------------------------------------
info "Đang dò tìm máy in mạng khả dụng..."

# Lấy danh sách máy in mạng mà CUPS thực tế đang nhìn thấy
mapfile -t DETECTED_URIS < <(lpinfo -v 2>/dev/null | grep -Ei 'network (dnssd|ipp|ipps)://' | awk '{print $2}' || true)

# Ưu tiên tìm HP trước
for URI in "${DETECTED_URIS[@]}"; do
  [[ -n "$URI" ]] || continue
  if echo "$URI" | grep -qiE 'hp|laserjet|m402'; then
    # Lấy URI của máy in HP đang phát sóng
    FOUND_HP_URI="$URI"
    info "ĐÃ TÌM THẤY MÁY IN HP KHẢ DỤNG: $FOUND_HP_URI"
    break
  fi
done

# Nếu không có HP mới tìm Brother mạng
if [[ -z "$FOUND_HP_URI" ]]; then
  for URI in "${DETECTED_URIS[@]}"; do
    [[ -n "$URI" ]] || continue
    if echo "$URI" | grep -qi "Brother"; then
      FOUND_BROTHER_URI="$URI"
      info "ĐÃ TÌM THẤY MÁY IN BROTHER KHẢ DỤNG: $FOUND_BROTHER_URI"
      break
    fi
  done
fi

# ------------------------------------------------------------------------------
# 3. QUÉT DẢI IP NỘI BỘ (CỔNG 9100) CÓ XÁC THỰC HTTP WEB PORT 80
# ------------------------------------------------------------------------------
if [[ -z "$FOUND_HP_URI" && -z "$FOUND_BROTHER_URI" ]]; then
  LOCAL_SUBNET=$(ip route show default 2>/dev/null | awk '{print $3}' | cut -d. -f1-3 || true)
  if [[ -n "$LOCAL_SUBNET" ]]; then
    mapfile -t IPS_9100 < <(nmap -p 9100 --open -T4 "${LOCAL_SUBNET}.0/24" -oG - 2>/dev/null | awk '/9100\/open/{print $2}' || true)

    for IP in "${IPS_9100[@]}"; do
      [[ -n "$IP" ]] || continue
      PAGE_CONTENT=$(curl -s -L --connect-timeout 2 --max-time 3 "http://${IP}" 2>/dev/null || true)
      
      if echo "$PAGE_CONTENT" | grep -qiE "Hewlett-Packard|HP LaserJet|LaserJet" && [[ -z "$FOUND_HP_URI" ]]; then
        FOUND_HP_URI="socket://${IP}:9100"
        info "Xác thực đúng máy in HP tại IP: $IP:9100"
        break
      elif echo "$PAGE_CONTENT" | grep -qi "Brother" && [[ -z "$FOUND_BROTHER_URI" ]]; then
        FOUND_BROTHER_URI="socket://${IP}:9100"
        info "Xác thực đúng máy in Brother tại IP: $IP:9100"
        break
      fi
    done
  fi
fi

# ------------------------------------------------------------------------------
# 4. TẠO HÀNG ĐỢI & CẤU HÌNH KHỔ A4 / IN 2 MẶT
# ------------------------------------------------------------------------------
lpadmin -x "Brother-Printer" 2>/dev/null || true
lpadmin -x "HP-Printer" 2>/dev/null || true

if [[ -n "$FOUND_HP_URI" ]]; then
  PRINTER_NAME="HP-Printer"
  info "Đang cài đặt hàng đợi [$PRINTER_NAME]..."
  
  # Với máy in chia sẻ qua dnssd/ipp, nạp driver everywhere chuẩn
  lpadmin -p "$PRINTER_NAME" -v "$FOUND_HP_URI" -E -m everywhere 2>/dev/null || \
  lpadmin -p "$PRINTER_NAME" -v "$FOUND_HP_URI" -E
  
  cupsenable "$PRINTER_NAME"
  cupsaccept "$PRINTER_NAME"
  lpadmin -p "$PRINTER_NAME" -o PageSize=A4 2>/dev/null || true
  lpadmin -p "$PRINTER_NAME" -o media=A4 2>/dev/null || true
  lpadmin -p "$PRINTER_NAME" -o sides=two-sided-long-edge 2>/dev/null || true
  lpadmin -p "$PRINTER_NAME" -o Duplex=DuplexNoTumble 2>/dev/null || true
  lpadmin -p "$PRINTER_NAME" -o HPDuplex=DuplexNoTumble 2>/dev/null || true
  
  lpadmin -d "$PRINTER_NAME"
  info "=> HOÀN TẤT: Đã gán $PRINTER_NAME làm máy in mặc định!"

elif [[ -n "$FOUND_BROTHER_URI" ]]; then
  PRINTER_NAME="Brother-Printer"
  info "Đang cài đặt hàng đợi [$PRINTER_NAME]..."
  
  lpadmin -p "$PRINTER_NAME" -v "$FOUND_BROTHER_URI" -E -m drv:///brlaser.drv/brl2360d.ppd 2>/dev/null || \
  lpadmin -p "$PRINTER_NAME" -v "$FOUND_BROTHER_URI" -E -m everywhere 2>/dev/null || \
  lpadmin -p "$PRINTER_NAME" -v "$FOUND_BROTHER_URI" -E

  cupsenable "$PRINTER_NAME"
  cupsaccept "$PRINTER_NAME"
  lpadmin -p "$PRINTER_NAME" -o PageSize=A4 2>/dev/null || true
  lpadmin -p "$PRINTER_NAME" -o media=A4 2>/dev/null || true
  lpadmin -p "$PRINTER_NAME" -o sides=two-sided-long-edge 2>/dev/null || true
  lpadmin -p "$PRINTER_NAME" -o Duplex=DuplexNoTumble 2>/dev/null || true
  lpadmin -p "$PRINTER_NAME" -o BRDuplex=DuplexNoTumble 2>/dev/null || true

  lpadmin -d "$PRINTER_NAME"
  info "=> HOÀN TẤT: Đã gán $PRINTER_NAME làm máy in mặc định!"
else
  warn "Không tìm thấy máy in HP hoặc Brother nào đang kết nối."
fi

# Xóa cache in WPS Office
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
info "KẾT QUẢ THIẾT LẬP:"
lpstat -p -d 2>/dev/null || true
echo
lpstat -v 2>/dev/null || true
echo "============================================================"
