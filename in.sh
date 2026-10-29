#!/usr/bin/env bash
# ==============================================================================
# SCRIPT TỰ ĐỘNG DÒ VÀ CÀI ĐẶT MÁY IN HP / BROTHER (USB, DNS-SD, IPP, LAN)
# TỰ ĐỘNG BẬT IN 2 MẶT & KHỔ GIẤY A4 CHO WPS OFFICE
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
echo " TỰ ĐỘNG DÒ TÌM & THIẾT LẬP MÁY IN HP / BROTHER KHẢ DỤNG"
echo "============================================================"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y \
  cups cups-client cups-filters cups-ipp-utils \
  printer-driver-brlaser \
  printer-driver-hpcups hplip hplip-data printer-driver-postscript-hp \
  avahi-daemon avahi-utils usbutils iproute2 nmap curl -qq

# Tắt cups-browsed để tránh sinh máy in ảo làm đơ WPS
systemctl stop cups-browsed 2>/dev/null || true
systemctl disable cups-browsed 2>/dev/null || true
systemctl enable --now cups avahi-daemon
sleep 1

cancel -a -x 2>/dev/null || true

TARGET_URI=""
PRINTER_BRAND=""

# ------------------------------------------------------------------------------
# 1. KIỂM TRA MÁY IN CẮM CÁP USB TRỰC TIẾP
# ------------------------------------------------------------------------------
USB_DEV=$(lpinfo -v 2>/dev/null | grep -Ei 'direct usb://' | head -n 1 | awk '{print $2}' || true)
if [[ -n "$USB_DEV" ]]; then
  USB_LIST=$(lsusb 2>/dev/null || true)
  if echo "$USB_LIST" | grep -qiE "Hewlett-Packard|HP"; then
    TARGET_URI="$USB_DEV"
    PRINTER_BRAND="hp"
    info "Phát hiện máy in HP cắm cổng USB: $TARGET_URI"
  elif echo "$USB_LIST" | grep -qi "Brother"; then
    TARGET_URI="$USB_DEV"
    PRINTER_BRAND="brother"
    info "Phát hiện máy in Brother cắm cổng USB: $TARGET_URI"
  fi
fi

# ------------------------------------------------------------------------------
# 2. DÒ QUA MẠNG DNS-SD / IPP (ƯU TIÊN HP LASERJET ĐANG PHÁT SÓNG)
# ------------------------------------------------------------------------------
if [[ -z "$TARGET_URI" ]]; then
  info "Đang dò tìm thiết bị in mạng qua DNS-SD / IPP..."
  mapfile -t NET_PRINTERS < <(lpinfo -v 2>/dev/null | grep -Ei 'network (dnssd|ipp|ipps)://' | awk '{print $2}' || true)

  # Quét tìm máy in HP trước (ưu tiên dòng M402 / LaserJet)
  for URI in "${NET_PRINTERS[@]}"; do
    [[ -n "$URI" ]] || continue
    if echo "$URI" | grep -qiE 'hp|laserjet|m402'; then
      TARGET_URI="$URI"
      PRINTER_BRAND="hp"
      info "ĐÃ TÌM THẤY MÁY IN HP QUA DNS-SD: $TARGET_URI"
      break
    fi
  done

  # Nếu không có máy HP, tìm máy in Brother mạng
  if [[ -z "$TARGET_URI" ]]; then
    for URI in "${NET_PRINTERS[@]}"; do
      [[ -n "$URI" ]] || continue
      if echo "$URI" | grep -qi "Brother"; then
        TARGET_URI="$URI"
        PRINTER_BRAND="brother"
        info "ĐÃ TÌM THẤY MÁY IN BROTHER QUA DNS-SD: $TARGET_URI"
        break
      fi
    done
  fi
fi

# ------------------------------------------------------------------------------
# 3. QUÉT DẢI IP NỘI BỘ (CỔNG 9100) CÓ XÁC THỰC HTTP WEB
# ------------------------------------------------------------------------------
if [[ -z "$TARGET_URI" ]]; then
  info "Quét cổng RAW Socket 9100 trên dải mạng LAN..."
  LOCAL_SUBNET=$(ip route show default 2>/dev/null | awk '{print $3}' | cut -d. -f1-3 || true)
  if [[ -n "$LOCAL_SUBNET" ]]; then
    mapfile -t IPS_9100 < <(nmap -p 9100 --open -T4 "${LOCAL_SUBNET}.0/24" -oG - 2>/dev/null | awk '/9100\/open/{print $2}' || true)

    for IP in "${IPS_9100[@]}"; do
      [[ -n "$IP" ]] || continue
      PAGE_CONTENT=$(curl -s -L --connect-timeout 2 --max-time 3 "http://${IP}" 2>/dev/null || true)
      
      if echo "$PAGE_CONTENT" | grep -qiE "Hewlett-Packard|HP LaserJet|LaserJet" && [[ -z "$TARGET_URI" ]]; then
        TARGET_URI="socket://${IP}:9100"
        PRINTER_BRAND="hp"
        info "Xác thực máy in HP tại IP: $IP:9100"
        break
      elif echo "$PAGE_CONTENT" | grep -qi "Brother" && [[ -z "$TARGET_URI" ]]; then
        TARGET_URI="socket://${IP}:9100"
        PRINTER_BRAND="brother"
        info "Xác thực máy in Brother tại IP: $IP:9100"
        break
      fi
    done
  fi
fi

# ------------------------------------------------------------------------------
# 4. TẠO HÀNG ĐỢI VÀ CẤU HÌNH IN 2 MẶT KHỔ A4
# ------------------------------------------------------------------------------
# Xóa các hàng đợi cũ để tránh trùng lặp
lpadmin -x "HP-Printer" 2>/dev/null || true
lpadmin -x "Brother-Printer" 2>/dev/null || true

if [[ -n "$TARGET_URI" ]]; then
  if [[ "$PRINTER_BRAND" == "hp" ]]; then
    PRINTER_NAME="HP-Printer"
    info "Đang tiến hành cài đặt [$PRINTER_NAME]..."
    
    # Dùng driver IPP Everywhere chuẩn của CUPS (khớp giao diện Settings)
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E
    
    cupsenable "$PRINTER_NAME"
    cupsaccept "$PRINTER_NAME"
    lpadmin -p "$PRINTER_NAME" -o PageSize=A4 2>/dev/null || true
    lpadmin -p "$PRINTER_NAME" -o media=A4 2>/dev/null || true
    lpadmin -p "$PRINTER_NAME" -o sides=two-sided-long-edge 2>/dev/null || true
    lpadmin -p "$PRINTER_NAME" -o Duplex=DuplexNoTumble 2>/dev/null || true
    lpadmin -p "$PRINTER_NAME" -o HPDuplex=DuplexNoTumble 2>/dev/null || true
    
    lpadmin -d "$PRINTER_NAME"
    info "=> ĐÃ CÀI ĐẶT VÀ GÁN HP-PRINTER LÀM MÁY IN MẶC ĐỊNH!"

  elif [[ "$PRINTER_BRAND" == "brother" ]]; then
    PRINTER_NAME="Brother-Printer"
    info "Đang tiến hành cài đặt [$PRINTER_NAME]..."
    
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m drv:///brlaser.drv/brl2360d.ppd 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E

    cupsenable "$PRINTER_NAME"
    cupsaccept "$PRINTER_NAME"
    lpadmin -p "$PRINTER_NAME" -o PageSize=A4 2>/dev/null || true
    lpadmin -p "$PRINTER_NAME" -o media=A4 2>/dev/null || true
    lpadmin -p "$PRINTER_NAME" -o sides=two-sided-long-edge 2>/dev/null || true
    lpadmin -p "$PRINTER_NAME" -o Duplex=DuplexNoTumble 2>/dev/null || true
    lpadmin -p "$PRINTER_NAME" -o BRDuplex=DuplexNoTumble 2>/dev/null || true
    
    lpadmin -d "$PRINTER_NAME"
    info "=> ĐÃ CÀI ĐẶT VÀ GÁN BROTHER-PRINTER LÀM MÁY IN MẶC ĐỊNH!"
  fi
else
  warn "Không phát hiện thấy bất kỳ máy in HP hay Brother nào khả dụng."
fi

# Xóa cache in của WPS Office
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
