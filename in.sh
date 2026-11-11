#!/usr/bin/env bash
# ==============================================================================
# SCRIPT TỰ ĐỘNG DÒ TÌM, LỌC, CHỌN VÀ CÀI ĐẶT MÁY IN VĂN PHÒNG (HP / BROTHER)
# TỰ ĐỘNG BẬT IN 2 MẶT, KHỔ A4 VÀ ĐẶT TÊN THEO MODEL THỰC TẾ
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
echo " TỰ ĐỘNG DÒ TÌM & TÙY CHỌN CÀI ĐẶT MÁY IN VĂN PHÒNG"
echo "============================================================"

export DEBIAN_FRONTEND=noninteractive

info "Đang cập nhật và cài đặt các gói công cụ CUPS, Avahi, nmap..."
apt-get update -qq
apt-get install -y \
  cups cups-client cups-filters cups-ipp-utils \
  printer-driver-brlaser \
  printer-driver-hpcups hplip hplip-data printer-driver-postscript-hp \
  avahi-daemon avahi-utils usbutils iproute2 nmap curl -qq

# Tắt cups-browsed để tránh sinh máy in rác làm đơ WPS
systemctl stop cups-browsed 2>/dev/null || true
systemctl disable cups-browsed 2>/dev/null || true
systemctl enable --now cups avahi-daemon
sleep 1

cancel -a -x 2>/dev/null || true

# Mảng lưu danh sách máy in tìm thấy: định dạng "URI|BRAND|MODEL_NAME"
declare -a FOUND_PRINTERS=()

# Hàm kiểm tra và loại trừ máy in bill/nhiệt
is_receipt_printer() {
  local text="$1"
  if echo "$text" | grep -qiE 'pos|thermal|receipt|bill|k80|k57|xprinter|t81|t88|epson.*tm'; then
    return 0 # Đúng là máy in bill
  fi
  return 1 # Không phải máy in bill
}

# ------------------------------------------------------------------------------
# 1. QUÉT MÁY IN USB TRỰC TIẾP
# ------------------------------------------------------------------------------
info "Đang quét các máy in kết nối qua cổng USB..."
mapfile -t USB_DEVS < <(lpinfo -v 2>/dev/null | grep -Ei 'direct usb://' | awk '{print $2}' || true)
USB_LIST=$(lsusb 2>/dev/null || true)

for USB_URI in "${USB_DEVS[@]}"; do
  [[ -n "$USB_URI" ]] || continue
  if is_receipt_printer "$USB_URI" || is_receipt_printer "$USB_LIST"; then
    info "Bỏ qua máy in bill/nhiệt cổng USB."
    continue
  fi

  if echo "$USB_LIST" | grep -qiE "Hewlett-Packard|HP"; then
    MODEL_NAME="HP-USB-Printer"
    FOUND_PRINTERS+=("$USB_URI|hp|$MODEL_NAME")
  elif echo "$USB_LIST" | grep -qi "Brother"; then
    MODEL_NAME="Brother-USB-Printer"
    FOUND_PRINTERS+=("$USB_URI|brother|$MODEL_NAME")
  fi
done

# ------------------------------------------------------------------------------
# 2. QUÉT MÁY IN QUA MẠNG LAN (CỔNG RAW 9100)
# ------------------------------------------------------------------------------
info "Đang quét mạng LAN qua cổng RAW 9100..."
LOCAL_SUBNET=$(ip route show default 2>/dev/null | awk '{print $3}' | cut -d. -f1-3 || true)

if [[ -n "$LOCAL_SUBNET" ]]; then
  mapfile -t IPS_9100 < <(nmap -p 9100 --open -T4 "${LOCAL_SUBNET}.0/24" -oG - 2>/dev/null | awk '/9100\/open/{print $2}' || true)

  for IP in "${IPS_9100[@]}"; do
    [[ -n "$IP" ]] || continue
    PAGE_CONTENT=$(curl -s -L --connect-timeout 2 --max-time 3 "http://${IP}" 2>/dev/null || true)
    
    if is_receipt_printer "$PAGE_CONTENT"; then
      info "Bỏ qua máy in hóa đơn/nhiệt tại IP: $IP"
      continue
    fi

    if echo "$PAGE_CONTENT" | grep -qi "Brother"; then
      # Cố gắng lấy tên model cụ thể từ trang web của máy in Brother nếu có
      BR_MODEL=$(echo "$PAGE_CONTENT" | grep -oiE 'HL-L[0-9]+[A-Za-z]*|MFC-[0-9]+[A-Za-z]*' | head -n 1 || echo "Brother-Network")
      FOUND_PRINTERS+=("socket://${IP}:9100|brother|${BR_MODEL}")
      info "Tìm thấy máy in Brother LAN: ${BR_MODEL} tại ${IP}"
    elif echo "$PAGE_CONTENT" | grep -qiE "Hewlett-Packard|HP LaserJet|LaserJet"; then
      HP_MODEL=$(echo "$PAGE_CONTENT" | grep -oiE 'LaserJet [A-Za-z0-9_-]+|HP [A-Za-z0-9_-]+' | head -n 1 | tr ' ' '-' || echo "HP-Network")
      FOUND_PRINTERS+=("socket://${IP}:9100|hp|${HP_MODEL}")
      info "Tìm thấy máy in HP LAN: ${HP_MODEL} tại ${IP}"
    fi
  done
fi

# ------------------------------------------------------------------------------
# 3. QUÉT DỰ PHÒNG QUA DNS-SD / mDNS
# ------------------------------------------------------------------------------
mapfile -t NET_PRINTERS < <(lpinfo -v 2>/dev/null | grep -Ei 'network (dnssd|ipp|ipps)://' | awk '{print $2}' || true)
for URI in "${NET_PRINTERS[@]}"; do
  [[ -n "$URI" ]] || continue
  if is_receipt_printer "$URI"; then continue; fi

  # Kiểm tra xem URI này đã có trong danh sách socket chưa để tránh trùng lặp
  exists=0
  for item in "${FOUND_PRINTERS[@]}"; do
    if [[ "$item" == *"$URI"* ]]; then exists=1; break; fi
  done
  [[ $exists -eq 1 ]] && continue

  if echo "$URI" | grep -qi "Brother"; then
    FOUND_PRINTERS+=("$URI|brother|Brother-DNS-SD")
  elif echo "$URI" | grep -qiE 'hp|laserjet'; then
    FOUND_PRINTERS+=("$URI|hp|HP-DNS-SD")
  fi
done

# ------------------------------------------------------------------------------
# 4. XỬ LÝ KẾT QUẢ VÀ HIỂN THỊ MENU CHO NGƯỜI DÙNG CHỌN
# ------------------------------------------------------------------------------
TOTAL_FOUND=${#FOUND_PRINTERS[@]}

if [[ $TOTAL_FOUND -eq 0 ]]; then
  die "Không tìm thấy máy in văn phòng HP hoặc Brother nào khả dụng trên hệ thống!"
fi

info "Đã tìm thấy tổng cộng $TOTAL_FOUND máy in phù hợp."
echo "============================================================"
echo " DANH SÁCH MÁY IN KHẢ DỤNG:"
echo "============================================================"
for i in "${!FOUND_PRINTERS[@]}"; do
  IFS='|' read -r uri brand name <<< "${FOUND_PRINTERS[$i]}"
  echo "  [$((i+1))] Hãng: ${brand^^} | Tên gợi ý: $name | Kết nối: $uri"
done
echo "============================================================"

# Nếu chỉ có 1 máy, tự động chọn luôn. Nếu có nhiều máy, hiện prompt yêu cầu chọn.
SELECTED_INDEX=0
if [[ $TOTAL_FOUND -gt 1 ]]; then
  while true; do
    read -rp "Nhập số thứ tự máy in bạn muốn cài đặt (1-$TOTAL_FOUND): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= TOTAL_FOUND )); then
      SELECTED_INDEX=$((choice - 1))
      break
    else
      warn "Lựa chọn không hợp lệ. Vui lòng nhập số từ 1 đến $TOTAL_FOUND."
    fi
  done
else
  info "Hệ thống chỉ tìm thấy 1 máy in, tự động chọn thiết bị này."
fi

# Trích xuất thông tin máy được chọn
IFS='|' read -r TARGET_URI PRINTER_BRAND RAW_MODEL_NAME <<< "${FOUND_PRINTERS[$SELECTED_INDEX]}"

# Làm sạch tên máy in để đặt tên hệ thống CUPS (không chứa khoảng trắng hoặc ký tự đặc biệt)
PRINTER_NAME=$(echo "$RAW_MODEL_NAME" | tr ' ' '-' | sed 's/[^a-zA-Z0-9_-]//g')
[[ -n "$PRINTER_NAME" ]] || PRINTER_NAME="Office-Printer"

info "Đã chọn cài đặt: [$PRINTER_NAME] (Hãng: $PRINTER_BRAND) qua URI: $TARGET_URI"

# Xóa hàng đợi cũ nếu trùng tên
lpadmin -x "$PRINTER_NAME" 2>/dev/null || true

# ------------------------------------------------------------------------------
# 5. TIẾN HÀNH CÀI ĐẶT DRIVER VÀ CẤU HÌNH IN 2 MẶT / KHỔ A4
# ------------------------------------------------------------------------------
if [[ "$PRINTER_BRAND" == "hp" ]]; then
  info "Đang tiến hành cài đặt driver HP cho [$PRINTER_NAME]..."
  lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
  lpadmin -p "$PRINTER_NAME" -v "$TARGET_URI" -E
  
  cupsenable "$PRINTER_NAME"
  cupsaccept "$PRINTER_NAME"
  lpadmin -p "$PRINTER_NAME" -o PageSize=A4 2>/dev/null || true
  lpadmin -p "$PRINTER_NAME" -o media=A4 2>/dev/null || true
  lpadmin -p "$PRINTER_NAME" -o sides=two-sided-long-edge 2>/dev/null || true
  lpadmin -p "$PRINTER_NAME" -o Duplex=DuplexNoTumble 2>/dev/null || true
  lpadmin -p "$PRINTER_NAME" -o HPDuplex=DuplexNoTumble 2>/dev/null || true

elif [[ "$PRINTER_BRAND" == "brother" ]]; then
  info "Đang tiến hành cài đặt driver Brother cho [$PRINTER_NAME]..."
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
fi

# Đặt làm máy in mặc định của hệ thống
lpadmin -d "$PRINTER_NAME"

# Dọn dẹp cache in của WPS Office để tránh lỗi tràn bộ đệm
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
info "CÀI ĐẶT THÀNH CÔNG!"
lpstat -p "$PRINTER_NAME" -d 2>/dev/null || true
echo "============================================================"
