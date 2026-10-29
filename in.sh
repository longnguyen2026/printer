#!/usr/bin/env bash
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
fi

# Ưu tiên 2: Mạng mDNS (nếu mạng cho phép broadcast)
if [[ -z "$TARGET_URI" ]]; then
  DRIVERLESS_URI=$(timeout 3 driverless 2>/dev/null | head -n 1 || true)
  if [[ -n "$DRIVERLESS_URI" ]]; then
    TARGET_URI="$DRIVERLESS_URI"
    info "Phát hiện máy in mạng qua mDNS: $TARGET_URI"
    if [[ "$DRIVERLESS_URI" =~ [Bb]rother ]]; then PRINTER_BRAND="brother"; fi
  fi
fi

# Ưu tiên 3: Quét dải IP nội bộ tìm cổng 9100 và XÁC THỰC THIẾT BỊ
if [[ -z "$TARGET_URI" ]]; then
  info "Đang quét và xác thực máy in trong dải IP nội bộ..."
  LOCAL_SUBNET=$(ip route show default 2>/dev/null | awk '{print $3}' | cut -d. -f1-3 || true)
  
  if [[ -n "$LOCAL_SUBNET" ]]; then
    # Lấy toàn bộ danh sách các IP mở cổng in 9100
    mapfile -t CANDIDATE_IPS < <(nmap -p 9100 --open -T4 "${LOCAL_SUBNET}.0/24" -oG - 2>/dev/null | awk '/9100\/open/{print $2}' || true)
    
    # Duyệt từng IP để xác định đúng máy in Brother qua cổng web quản trị (port 80)
    for IP in "${CANDIDATE_IPS[@]}"; do
      [[ -n "$IP" ]] || continue
      
      # Gửi yêu cầu HTTP nhanh tới thiết bị để kiểm tra nhãn hãng
      PAGE_INFO=$(curl -s -L --connect-timeout 2 --max-time 3 "http://${IP}" 2>/dev/null || true)
      
      if echo "$PAGE_INFO" | grep -qi "Brother"; then
        TARGET_URI="socket://${IP}:9100"
        PRINTER_BRAND="brother"
        info "ĐÃ TÌM THẤY MÁY IN BROTHER TẠI ĐỊA CHỈ IP: $IP"
        break
      elif echo "$PAGE_INFO" | grep -qi "Hewlett-Packard\|HP LaserJet\|HP PageWide"; then
        TARGET_URI="socket://${IP}:9100"
        PRINTER_BRAND="hp"
        info "ĐÃ TÌM THẤY MÁY IN HP TẠI ĐỊA CHỈ IP: $IP"
        break
      fi
    done
    
    # Nếu web port bị đóng nhưng chỉ có duy nhất 1 IP mở cổng 9100
    if [[ -z "$TARGET_URI" && ${#CANDIDATE_IPS[@]} -eq 1 ]]; then
      TARGET_URI="socket://${CANDIDATE_IPS[0]}:9100"
      PRINTER_BRAND="brother"
      info "Dò thấy 1 cổng in duy nhất tại IP: ${CANDIDATE_IPS[0]}"
    fi
  fi
fi

PRINTER_NAME="Brother-Printer"

# 3. Tạo hàng đợi và gán driver tĩnh brlaser
if [[ -n "$TARGET_URI" ]]; then
  # Dọn sạch các hàng đợi cũ
  lpadmin -x "Brother_HL_L2360D_series" 2>/dev/null || true
  lpadmin -x "MayInVanPhong" 2>/dev/null || true
  lpadmin -x "$PRINTER_NAME" 2>/dev/null || true
  
  info "Đang tạo hàng đợi in: $PRINTER_NAME với URI: $TARGET_URI"
  
  if [[ "$PRINTER_BRAND" == "brother" ]] || [[ "$TARGET_URI" =~ 9100 ]]; then
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m drv:///brlaser.drv/brl2360d.ppd 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E
  else
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E
  fi

  # Kích hoạt hàng đợi và đặt làm mặc định
  lpadmin -d "$PRINTER_NAME"
  cupsenable "$PRINTER_NAME"
  cupsaccept "$PRINTER_NAME"

  # Cấu hình chuẩn khổ A4 & in 2 mặt (Duplex)
  lpadmin -p "$PRINTER_NAME" -o PageSize=A4 -o media=A4
  lpadmin -p "$PRINTER_NAME" -o sides=two-sided-long-edge
  lpadmin -p "$PRINTER_NAME" -o Duplex=DuplexNoTumble
  lpadmin -p "$PRINTER_NAME" -o BRDuplex=DuplexNoTumble

  info "Cấu hình thành công máy in mặc định: $PRINTER_NAME"
else
  warn "Không tìm thấy máy in trong mạng. Vui lòng kiểm tra cáp mạng/nguồn máy in."
fi

# 4. Xóa cache in của WPS Office trên toàn bộ các tài khoản người dùng
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
