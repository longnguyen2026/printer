#!/usr/bin/env bash
# ==============================================================================
# SCRIPT TỰ ĐỘNG DÒ VÀ XÁC THỰC DANH TÍNH MÁY IN BROTHER & HP (USB / LAN / DNS-SD)
# BẬT IN 2 MẶT (DUPLEX), KHÓA KHỔ A4, KHẮC PHỤC LỖI WPS OFFICE
# Cập nhật 16g 29.10.2026
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
echo " DÒ TÌM & XÁC THỰC MÁY IN BROTHER / HP (KHÔNG GÁN ẨU)"
echo "============================================================"

export DEBIAN_FRONTEND=noninteractive

# 1. Cài đặt driver cần thiết và công cụ dò quét
info "Đang cập nhật danh mục driver và công cụ dò quét..."
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

TARGET_URI=""
DETECTED_BRAND=""
DETECTED_MODEL=""

info "Bắt đầu quét và xác thực thiết bị in..."

# ==============================================================================
# TẦNG 1: DÒ VÀ XÁC THỰC MÁY IN CẮM CÁP USB TRỰC TIẾP
# ==============================================================================
USB_DEV=$(lpinfo -v 2>/dev/null | grep -Ei 'direct usb://' | head -n 1 | awk '{print $2}' || true)
if [[ -n "$USB_DEV" ]]; then
  info "Kiểm tra thiết bị cắm cổng USB..."
  USB_LIST=$(lsusb 2>/dev/null || true)
  if echo "$USB_LIST" | grep -qi "Brother"; then
    TARGET_URI="$USB_DEV"
    DETECTED_BRAND="brother"
    DETECTED_MODEL="Brother USB Printer"
    info "=> Xác thực thành công: Máy in Brother qua USB"
  elif echo "$USB_LIST" | grep -qiE "Hewlett-Packard|HP"; then
    TARGET_URI="$USB_DEV"
    DETECTED_BRAND="hp"
    DETECTED_MODEL="HP USB Printer"
    info "=> Xác thực thành công: Máy in HP qua USB"
  fi
fi

# ==============================================================================
# TẦNG 2: DÒ VÀ XÁC THỰC QUA MẠNG DNS-SD / IPP / CUPS REMOTE SHARE
# ==============================================================================
if [[ -z "$TARGET_URI" ]]; then
  info "Đang dò tìm máy in chia sẻ qua mạng (DNS-SD / CUPS Share / IPP)..."
  
  # Lấy danh sách các URI mạng mà CUPS/Avahi phát hiện được
  mapfile -t NETWORK_URIS < <(lpinfo -v 2>/dev/null | grep -Ei 'network (dnssd|ipp|ipps)://' | awk '{print $2}' || true)
  
  for N_URI in "${NETWORK_URIS[@]}"; do
    [[ -n "$N_URI" ]] || continue
    
    # Kiểm tra xem tên máy in trên URI mạng có chứa Brother không
    if echo "$N_URI" | grep -qi "Brother"; then
      TARGET_URI="$N_URI"
      DETECTED_BRAND="brother"
      DETECTED_MODEL="Brother Network (DNS-SD/IPP)"
      info "=> Xác thực thành công: $DETECTED_MODEL qua $N_URI"
      break
    # Kiểm tra xem tên máy in trên URI mạng có chứa HP / LaserJet không
    elif echo "$N_URI" | grep -qiE "hp|laserjet|m402"; then
      TARGET_URI="$N_URI"
      DETECTED_BRAND="hp"
      DETECTED_MODEL="HP Network (DNS-SD/IPP)"
      info "=> Xác thực thành công: $DETECTED_MODEL qua $N_URI"
      break
    fi
  done
fi

# ==============================================================================
# TẦNG 3: QUÉT DẢI IP NỘI BỘ (CỔNG 9100) VÀ BẮT BUỘC ĐỐI SOÁT WEB PORT 80
# ==============================================================================
if [[ -z "$TARGET_URI" ]]; then
  info "Đang quét cổng 9100 trên dải mạng LAN và xác thực danh tính HTTP..."
  LOCAL_SUBNET=$(ip route show default 2>/dev/null | awk '{print $3}' | cut -d. -f1-3 || true)
  
  if [[ -n "$LOCAL_SUBNET" ]]; then
    mapfile -t IPS_9100 < <(nmap -p 9100 --open -T4 "${LOCAL_SUBNET}.0/24" -oG - 2>/dev/null | awk '/9100\/open/{print $2}' || true)
    
    for IP in "${IPS_9100[@]}"; do
      [[ -n "$IP" ]] || continue
      
      # Gửi lệnh cURL kiểm tra trang thông tin thiết bị
      PAGE_CONTENT=$(curl -s -L --connect-timeout 2 --max-time 3 "http://${IP}" 2>/dev/null || true)
      
      if echo "$PAGE_CONTENT" | grep -qi "Brother"; then
        TARGET_URI="socket://${IP}:9100"
        DETECTED_BRAND="brother"
        DETECTED_MODEL="Brother IP Network"
        info "=> Xác thực thành công: Tìm thấy đúng máy in Brother tại IP: $IP"
        break
      elif echo "$PAGE_CONTENT" | grep -qiE "Hewlett-Packard|HP LaserJet|LaserJet|HP PageWide"; then
        TARGET_URI="socket://${IP}:9100"
        DETECTED_BRAND="hp"
        DETECTED_MODEL="HP IP Network"
        info "=> Xác thực thành công: Tìm thấy đúng máy in HP tại IP: $IP"
        break
      else
        info "Bỏ qua thiết bị tại IP $IP (Không phải Brother hoặc HP)."
      fi
    done
  fi
fi

# ==============================================================================
# TIẾN HÀNH TẠO HÀNG ĐỢI THEO ĐÚNG HÃNG ĐÃ XÁC THỰC
# ==============================================================================
if [[ -n "$TARGET_URI" && -n "$DETECTED_BRAND" ]]; then
  # Xóa các hàng đợi cũ để tránh xung đột
  lpadmin -x "Brother_HL_L2360D_series" 2>/dev/null || true
  lpadmin -x "Brother-Printer" 2>/dev/null || true
  lpadmin -x "HP-Printer" 2>/dev/null || true
  lpadmin -x "MayInVanPhong" 2>/dev/null || true

  if [[ "$DETECTED_BRAND" == "brother" ]]; then
    FINAL_NAME="Brother-Printer"
    info "Cấu hình hàng đợi [$FINAL_NAME] sử dụng driver brlaser..."
    
    lpadmin -p "$FINAL_NAME" -v "$TARGET_URI" -E -m drv:///brlaser.drv/brl2360d.ppd 2>/dev/null || \
    lpadmin -p "$FINAL_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
    lpadmin -p "$FINAL_NAME" -v "$TARGET_URI" -E

  elif [[ "$DETECTED_BRAND" == "hp" ]]; then
    FINAL_NAME="HP-Printer"
    info "Cấu hình hàng đợi [$FINAL_NAME] cho máy in HP..."
    
    # Nếu kết nối qua RAW socket 9100 thì gán driver hpcups
    if [[ "$TARGET_URI" =~ socket:// ]]; then
      HP_PPD=$(lpinfo -m 2>/dev/null | grep -iE 'hp-laserjet_m402|hp-laserjet.*hpcups' | head -n 1 | awk '{print $1}' || true)
      if [[ -n "$HP_PPD" ]]; then
        lpadmin -p "$FINAL_NAME" -v "$TARGET_URI" -E -m "$HP_PPD" 2>/dev/null || \
        lpadmin -p "$FINAL_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
        lpadmin -p "$FINAL_NAME" -v "$TARGET_URI" -E
      else
        lpadmin -p "$FINAL_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
        lpadmin -p "$FINAL_NAME" -v "$TARGET_URI" -E
      fi
    else
      # Nếu kết nối qua chia sẻ DNS-SD/IPP Everywhere, dùng trực tiếp everywhere
      lpadmin -p "$FINAL_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
      lpadmin -p "$FINAL_NAME" -v "$TARGET_URI" -E
    fi
  fi

  # Kích hoạt hàng đợi và gán làm mặc định
  lpadmin -d "$FINAL_NAME"
  cupsenable "$FINAL_NAME"
  cupsaccept "$FINAL_NAME"

  # Cấu hình chuẩn A4 và in 2 mặt (Duplex)
  info "Đang thiết lập khổ giấy A4 và in 2 mặt cho $FINAL_NAME..."
  lpadmin -p "$FINAL_NAME" -o PageSize=A4 2>/dev/null || true
  lpadmin -p "$FINAL_NAME" -o media=A4 2>/dev/null || true
  lpadmin -p "$FINAL_NAME" -o sides=two-sided-long-edge 2>/dev/null || true
  lpadmin -p "$FINAL_NAME" -o Duplex=DuplexNoTumble 2>/dev/null || true
  lpadmin -p "$FINAL_NAME" -o BRDuplex=DuplexNoTumble 2>/dev/null || true
  lpadmin -p "$FINAL_NAME" -o HPDuplex=DuplexNoTumble 2>/dev/null || true
  lpadmin -p "$FINAL_NAME" -o DuplexUnit=Installed 2>/dev/null || true

  info "ĐÃ CÀI ĐẶT THÀNH CÔNG MÁY IN MẶC ĐỊNH: $FINAL_NAME ($DETECTED_MODEL)"
else
  warn "============================================================"
  warn "KHÔNG TÌM THẤY THIẾT BỊ NÀO XÁC THỰC ĐƯỢC LÀ BROTHER HOẶC HP!"
  warn "Script từ chối gán bừa để tránh in nhầm thiết bị mạng khác."
  warn "Vui lòng kiểm tra nguồn máy in và kết nối dây mạng/USB."
  warn "============================================================"
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
info "KẾT QUẢ CẤU HÌNH HỆ THỐNG:"
lpstat -p -d 2>/dev/null || true
echo
echo "Chi tiết kết nối thiết bị:"
lpstat -v 2>/dev/null || true
echo "============================================================"
