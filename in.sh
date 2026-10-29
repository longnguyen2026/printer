#!/usr/bin/env bash
# ==============================================================================
# SCRIPT DÒ TÌM & CÀI ĐẶT MÁY IN BROTHER & HP (ƯU TIÊN HP ONLINE)
# TỰ ĐỘNG KHÓA KHỔ A4, IN 2 MẶT (DUPLEX), TƯƠNG THÍCH WPS OFFICE
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
echo " DÒ TÌM, KIỂM TRA ONLINE & THIẾT LẬP MÁY IN HP / BROTHER"
echo "============================================================"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y \
  cups cups-client cups-filters cups-ipp-utils \
  printer-driver-brlaser \
  printer-driver-hpcups hplip hplip-data printer-driver-postscript-hp \
  avahi-daemon avahi-utils usbutils iproute2 nmap curl netcat-openbsd -qq

systemctl stop cups-browsed 2>/dev/null || true
systemctl disable cups-browsed 2>/dev/null || true
systemctl enable --now cups avahi-daemon
sleep 1

cancel -a -x 2>/dev/null || true

FOUND_HP_URI=""
FOUND_BROTHER_URI=""

# Hàm kiểm tra cổng in có thực sự thông hay không
check_port_open() {
  local host="$1"
  local port="${2:-631}"

  # Phân giải nếu là tên miền .local
  if [[ "$host" =~ \.local$ ]]; then
    local resolved_ip
    resolved_ip=$(timeout 1.5 avahi-resolve -n "$host" 2>/dev/null | awk '{print $2}' || true)
    if [[ -n "$resolved_ip" ]]; then
      host="$resolved_ip"
    else
      return 1
    fi
  fi

  nc -z -w 1 "$host" "$port" 2>/dev/null
}

# 1. Quét USB trực tiếp
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

# 2. Quét mạng DNS-SD / IPP (Lọc riêng từng hãng và kiểm tra cổng 631)
mapfile -t NETWORK_URIS < <(lpinfo -v 2>/dev/null | grep -Ei 'network (dnssd|ipp|ipps)://' | awk '{print $2}' || true)

for URI in "${NETWORK_URIS[@]}"; do
  [[ -n "$URI" ]] || continue

  # Trích xuất host từ URI
  TARGET_HOST=""
  if [[ "$URI" =~ ://([^:/]+) ]]; then
    TARGET_HOST="${BASH_REMATCH[1]}"
  fi

  # Kiểm tra HP
  if echo "$URI" | grep -qiE 'hp|laserjet|m402' && [[ -z "$FOUND_HP_URI" ]]; then
    info "Phát hiện máy in HP qua DNS-SD: $URI"
    if [[ -n "$TARGET_HOST" ]] && check_port_open "$TARGET_HOST" 631; then
      FOUND_HP_URI="$URI"
      info "=> Xác nhận máy in HP đang ONLINE (Port 631 mở)."
    else
      warn "=> Máy in HP không phản hồi cổng in (Offline), bỏ qua."
    fi
  fi

  # Kiểm tra Brother
  if echo "$URI" | grep -qi "Brother" && [[ -z "$FOUND_BROTHER_URI" ]]; then
    info "Phát hiện máy in Brother qua DNS-SD: $URI"
    if [[ -n "$TARGET_HOST" ]] && check_port_open "$TARGET_HOST" 631; then
      FOUND_BROTHER_URI="$URI"
      info "=> Xác nhận máy in Brother đang ONLINE (Port 631 mở)."
    else
      warn "=> Máy in Brother không phản hồi cổng in (Offline), bỏ qua."
    fi
  fi
done

# 3. Quét dải IP nội bộ tìm cổng 9100 nếu chưa tìm thấy
if [[ -z "$FOUND_HP_URI" && -z "$FOUND_BROTHER_URI" ]]; then
  LOCAL_SUBNET=$(ip route show default 2>/dev/null | awk '{print $3}' | cut -d. -f1-3 || true)
  if [[ -n "$LOCAL_SUBNET" ]]; then
    info "Quét tìm cổng 9100 trên dải $LOCAL_SUBNET.0/24..."
    mapfile -t IPS_9100 < <(nmap -p 9100 --open -T4 "${LOCAL_SUBNET}.0/24" -oG - 2>/dev/null | awk '/9100\/open/{print $2}' || true)

    for IP in "${IPS_9100[@]}"; do
      [[ -n "$IP" ]] || continue
      PAGE_CONTENT=$(curl -s -L --connect-timeout 2 --max-time 3 "http://${IP}" 2>/dev/null || true)
      
      if echo "$PAGE_CONTENT" | grep -qiE "Hewlett-Packard|HP LaserJet|LaserJet" && [[ -z "$FOUND_HP_URI" ]]; then
        FOUND_HP_URI="socket://${IP}:9100"
        info "Xác thực máy in HP tại IP: $IP:9100"
      elif echo "$PAGE_CONTENT" | grep -qi "Brother" && [[ -z "$FOUND_BROTHER_URI" ]]; then
        FOUND_BROTHER_URI="socket://${IP}:9100"
        info "Xác thực máy in Brother tại IP: $IP:9100"
      fi
    done
  fi
fi

# 4. Tạo hàng đợi và gán máy mặc định
# Dọn dẹp hàng đợi cũ
lpadmin -x "Brother-Printer" 2>/dev/null || true
lpadmin -x "HP-Printer" 2>/dev/null || true

# ƯU TIÊN 1: Cài đặt HP nếu có kết nối
if [[ -n "$FOUND_HP_URI" ]]; then
  info "Đang tạo hàng đợi [HP-Printer]..."
  
  if [[ "$FOUND_HP_URI" =~ socket:// ]]; then
    HP_PPD=$(lpinfo -m 2>/dev/null | grep -iE 'hp-laserjet_m402|hp-laserjet.*hpcups' | head -n 1 | awk '{print $1}' || true)
    lpadmin -p "HP-Printer" -v "$FOUND_HP_URI" -E -m "${HP_PPD:-everywhere}" 2>/dev/null || \
    lpadmin -p "HP-Printer" -v "$FOUND_HP_URI" -E
  else
    lpadmin -p "HP-Printer" -v "$FOUND_HP_URI" -E -m everywhere 2>/dev/null || \
    lpadmin -p "HP-Printer" -v "$FOUND_HP_URI" -E
  fi

  cupsenable "HP-Printer"
  cupsaccept "HP-Printer"
  lpadmin -p "HP-Printer" -o PageSize=A4 -o media=A4 2>/dev/null || true
  lpadmin -p "HP-Printer" -o sides=two-sided-long-edge -o Duplex=DuplexNoTumble -o HPDuplex=DuplexNoTumble 2>/dev/null || true
  
  # Đặt HP làm máy in mặc định hệ thống
  lpadmin -d "HP-Printer"
  info "=> ĐÃ THIẾT LẬP HP-PRINTER LÀM MÁY IN MẶC ĐỊNH!"

# ƯU TIÊN 2: Cài Brother nếu không có HP
elif [[ -n "$FOUND_BROTHER_URI" ]]; then
  info "Đang tạo hàng đợi [Brother-Printer]..."
  
  lpadmin -p "Brother-Printer" -v "$FOUND_BROTHER_URI" -E -m drv:///brlaser.drv/brl2360d.ppd 2>/dev/null || \
  lpadmin -p "Brother-Printer" -v "$FOUND_BROTHER_URI" -E -m everywhere 2>/dev/null || \
  lpadmin -p "Brother-Printer" -v "$FOUND_BROTHER_URI" -E

  cupsenable "Brother-Printer"
  cupsaccept "Brother-Printer"
  lpadmin -p "Brother-Printer" -o PageSize=A4 -o media=A4 2>/dev/null || true
  lpadmin -p "Brother-Printer" -o sides=two-sided-long-edge -o Duplex=DuplexNoTumble -o BRDuplex=DuplexNoTumble 2>/dev/null || true
  
  lpadmin -d "Brother-Printer"
  info "=> ĐÃ THIẾT LẬP BROTHER-PRINTER LÀM MÁY IN MẶC ĐỊNH!"
else
  warn "Không tìm thấy máy in HP hoặc Brother nào khả dụng (Online)!"
fi

# Dọn cache in WPS Office
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
info "KẾT QUẢ CUỐI CÙNG:"
lpstat -p -d 2>/dev/null || true
echo
lpstat -v 2>/dev/null || true
echo "============================================================"
