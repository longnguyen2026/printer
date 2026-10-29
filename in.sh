#!/usr/bin/env bash
# ==============================================================================
# SCRIPT TỰ ĐỘNG DÒ, KIỂM TRA ONLINE & CÀI ĐẶT MÁY IN BROTHER & HP
# LOẠI TRÙ TUYỆT ĐỐI MÁY IN OFFLINE / TẮT NGUỒN / MÁY MA
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
echo " KIỂM TRA TRẠNG THÁI ONLINE & CÀI ĐẶT MÁY IN BROTHER / HP"
echo "============================================================"

export DEBIAN_FRONTEND=noninteractive

info "Cập nhật driver và công cụ kiểm tra kết nối mạng..."
apt-get update -qq
apt-get install -y \
  cups cups-client cups-filters cups-ipp-utils \
  printer-driver-brlaser \
  printer-driver-hpcups hplip hplip-data printer-driver-postscript-hp \
  avahi-daemon avahi-utils usbutils iproute2 nmap curl netcat-openbsd -qq

# Tắt cups-browsed để tránh sinh máy in ma
systemctl stop cups-browsed 2>/dev/null || true
systemctl disable cups-browsed 2>/dev/null || true
systemctl enable --now cups avahi-daemon
sleep 1

cancel -a -x 2>/dev/null || true

BROTHER_URI=""
HP_URI=""

# Hàm kiểm tra máy chủ đích có thực sự Online hay không
check_online() {
  local uri="$1"
  local target_host=""

  # Bóc tách Hostname hoặc IP từ URI
  if [[ "$uri" =~ ://([^:/]+) ]]; then
    target_host="${BASH_REMATCH[1]}"
  fi

  if [[ -z "$target_host" ]]; then
    return 1
  fi

  # 1. Nếu là dạng .local (DNS-SD mDNS)
  if [[ "$target_host" =~ \.local$ ]]; then
    local resolved_ip
    resolved_ip=$(timeout 1.5 avahi-resolve -n "$target_host" 2>/dev/null | awk '{print $2}' || true)
    if [[ -z "$resolved_ip" ]]; then
      return 1
    fi
    target_host="$resolved_ip"
  fi

  # 2. Ping kiểm tra nhanh thiết bị trong 1 giây
  if ping -c 1 -W 1 "$target_host" &>/dev/null; then
    return 0
  fi

  return 1
}

# ------------------------------------------------------------------------------
# 1. QUÉT CỔNG USB CẮM TRỰC TIẾP
# ------------------------------------------------------------------------------
USB_DEV=$(lpinfo -v 2>/dev/null | grep -Ei 'direct usb://' | head -n 1 | awk '{print $2}' || true)
if [[ -n "$USB_DEV" ]]; then
  USB_LIST=$(lsusb 2>/dev/null || true)
  if echo "$USB_LIST" | grep -qi "Brother"; then
    BROTHER_URI="$USB_DEV"
    info "Phát hiện máy in Brother cắm qua cáp USB: $BROTHER_URI"
  elif echo "$USB_LIST" | grep -qiE "Hewlett-Packard|HP"; then
    HP_URI="$USB_DEV"
    info "Phát hiện máy in HP cắm qua cáp USB: $HP_URI"
  fi
fi

# ------------------------------------------------------------------------------
# 2. QUÉT MẠNG DNS-SD / IPP & BẮT BUỘC CHECK ONLINE
# ------------------------------------------------------------------------------
info "Đang quét các máy in chia sẻ qua mạng và kiểm tra trạng thái Online..."
mapfile -t NETWORK_URIS < <(lpinfo -v 2>/dev/null | grep -Ei 'network (dnssd|ipp|ipps)://' | awk '{print $2}' || true)

for N_URI in "${NETWORK_URIS[@]}"; do
  [[ -n "$N_URI" ]] || continue

  # Kiểm tra HP
  if echo "$N_URI" | grep -qiE 'hp|laserjet|m402' && [[ -z "$HP_URI" ]]; then
    info "Đang ping kiểm tra máy in HP ($N_URI)..."
    if check_online "$N_URI"; then
      HP_URI="$N_URI"
      info "=> Máy in HP đang ONLINE: $HP_URI"
    else
      warn "=> Máy in HP đang OFFLINE (tắt nguồn hoặc rút cáp), bỏ qua."
    fi
  fi

  # Kiểm tra Brother
  if echo "$N_URI" | grep -qi "Brother" && [[ -z "$BROTHER_URI" ]]; then
    info "Đang ping kiểm tra máy in Brother ($N_URI)..."
    if check_online "$N_URI"; then
      BROTHER_URI="$N_URI"
      info "=> Máy in Brother đang ONLINE: $BROTHER_URI"
    else
      warn "=> Máy in Brother đang OFFLINE (tắt nguồn hoặc rút cáp), bỏ qua."
    fi
  fi
done

# ------------------------------------------------------------------------------
# 3. QUÉT DẢI IP NỘI BỘ (CỔNG 9100) VÀ CHECK HTTP
# ------------------------------------------------------------------------------
if [[ -z "$BROTHER_URI" || -z "$HP_URI" ]]; then
  LOCAL_SUBNET=$(ip route show default 2>/dev/null | awk '{print $3}' | cut -d. -f1-3 || true)
  if [[ -n "$LOCAL_SUBNET" ]]; then
    info "Đang dò tìm cổng RAW Socket 9100 trên dải mạng LAN..."
    mapfile -t IPS_9100 < <(nmap -p 9100 --open -T4 "${LOCAL_SUBNET}.0/24" -oG - 2>/dev/null | awk '/9100\/open/{print $2}' || true)

    for IP in "${IPS_9100[@]}"; do
      [[ -n "$IP" ]] || continue

      # Kiểm tra cổng 9100 có đang phản hồi thực sự không
      if ! nc -z -w 1 "$IP" 9100 2>/dev/null; then
        continue
      fi

      PAGE_CONTENT=$(curl -s -L --connect-timeout 2 --max-time 3 "http://${IP}" 2>/dev/null || true)

      if echo "$PAGE_CONTENT" | grep -qi "Brother" && [[ -z "$BROTHER_URI" ]]; then
        BROTHER_URI="socket://${IP}:9100"
        info "Xác thực máy in Brother ONLINE tại IP: $IP:9100"
      elif echo "$PAGE_CONTENT" | grep -qiE "Hewlett-Packard|HP LaserJet|LaserJet" && [[ -z "$HP_URI" ]]; then
        HP_URI="socket://${IP}:9100"
        info "Xác thực máy in HP ONLINE tại IP: $IP:9100"
      fi
    done
  fi
fi

# ------------------------------------------------------------------------------
# 4. CHỈ ADD CÁC MÁY IN ĐƯỢC XÁC THỰC ONLINE VÀO CUPS
# ------------------------------------------------------------------------------
# Xóa các máy cũ để dọn dẹp hàng đợi
lpadmin -x "Brother_HL_L2360D_series" 2>/dev/null || true
lpadmin -x "Brother-Printer" 2>/dev/null || true
lpadmin -x "HP-Printer" 2>/dev/null || true
lpadmin -x "MayInVanPhong" 2>/dev/null || true

# Add máy HP nếu Online
if [[ -n "$HP_URI" ]]; then
  info "Đang tạo hàng đợi [HP-Printer]..."
  if [[ "$HP_URI" =~ socket:// ]]; then
    HP_PPD=$(lpinfo -m 2>/dev/null | grep -iE 'hp-laserjet_m402|hp-laserjet.*hpcups' | head -n 1 | awk '{print $1}' || true)
    lpadmin -p "HP-Printer" -v "$HP_URI" -E -m "${HP_PPD:-everywhere}" 2>/dev/null || \
    lpadmin -p "HP-Printer" -v "$HP_URI" -E
  else
    lpadmin -p "HP-Printer" -v "$HP_URI" -E -m everywhere 2>/dev/null || \
    lpadmin -p "HP-Printer" -v "$HP_URI" -E
  fi

  cupsenable "HP-Printer"
  cupsaccept "HP-Printer"
  lpadmin -p "HP-Printer" -o PageSize=A4 -o media=A4 2>/dev/null || true
  lpadmin -p "HP-Printer" -o sides=two-sided-long-edge -o Duplex=DuplexNoTumble -o HPDuplex=DuplexNoTumble 2>/dev/null || true
  lpadmin -d "HP-Printer"
  info "=> Hoàn tất cài đặt HP-Printer (Mặc định)."
fi

# Add máy Brother nếu Online
if [[ -n "$BROTHER_URI" ]]; then
  info "Đang tạo hàng đợi [Brother-Printer]..."
  lpadmin -p "Brother-Printer" -v "$BROTHER_URI" -E -m drv:///brlaser.drv/brl2360d.ppd 2>/dev/null || \
  lpadmin -p "Brother-Printer" -v "$BROTHER_URI" -E -m everywhere 2>/dev/null || \
  lpadmin -p "Brother-Printer" -v "$BROTHER_URI" -E

  cupsenable "Brother-Printer"
  cupsaccept "Brother-Printer"
  lpadmin -p "Brother-Printer" -o PageSize=A4 -o media=A4 2>/dev/null || true
  lpadmin -p "Brother-Printer" -o sides=two-sided-long-edge -o Duplex=DuplexNoTumble -o BRDuplex=DuplexNoTumble 2>/dev/null || true

  if [[ -z "$HP_URI" ]]; then
    lpadmin -d "Brother-Printer"
    info "=> Hoàn tất cài đặt Brother-Printer (Mặc định)."
  fi
fi

if [[ -z "$HP_URI" && -z "$BROTHER_URI" ]]; then
  warn "Không có máy in Brother hoặc HP nào đang ONLINE trong mạng."
fi

# ------------------------------------------------------------------------------
# 5. DỌN SẠCH CACHE WPS VÀ KHỞI ĐỘNG LẠI CUPS
# ------------------------------------------------------------------------------
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
info "TRẠNG THÁI HÀNG ĐỢI CUPS:"
lpstat -p -d 2>/dev/null || true
echo
echo "CHI TIẾT KẾT NỐI:"
lpstat -v 2>/dev/null || true
echo "============================================================"
