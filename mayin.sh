#!/usr/bin/env bash
# ==============================================================================
# SCRIPT TỰ ĐỘNG DÒ VÀ CÀI ĐẶT MÁY IN HP / BROTHER (USB, DNS-SD, IPP, LAN)
# TỰ ĐỘNG LẤY TÊN MÁY IN CHIA SẺ TRÊN MẠNG & CẤU HÌNH IN 2 MẶT KHỔ A4
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

info "Đang cập nhật và cài đặt đầy đủ các gói driver máy in..."
apt-get update -qq
apt-get install -y \
  cups cups-client cups-filters cups-ipp-utils \
  printer-driver-brlaser printer-driver-ptouch \
  printer-driver-hpcups hplip hplip-data printer-driver-postscript-hp \
  printer-driver-gutenprint foomatic-db-compressed-ppds openprinting-ppds \
  avahi-daemon avahi-utils usbutils iproute2 nmap curl -qq

# Tắt cups-browsed để tránh sinh máy in ảo trùng lặp làm đơ WPS
systemctl stop cups-browsed 2>/dev/null || true
systemctl disable cups-browsed 2>/dev/null || true
systemctl enable --now cups avahi-daemon
sleep 1

cancel -a -x 2>/dev/null || true

# ------------------------------------------------------------------------------
# CÁC HÀM HỖ TRỢ TRÍCH XUẤT TÊN MÁY IN & DÒ DRIVER
# ------------------------------------------------------------------------------

# Giải mã chuỗi URL-encoded (ví dụ: %20 -> khoảng trắng)
urldecode() {
  local encoded="${1//+/ }"
  printf '%b' "${encoded//%/\\x}"
}

# Chuẩn hóa tên hàng đợi CUPS (không chứa khoảng trắng và ký tự cấm của lpadmin)
sanitize_queue_name() {
  local raw="$1"
  echo "$raw" | sed -E 's/[^a-zA-Z0-9_-]+/_/g; s/^_+//; s/_+$//; s/_+/_/g'
}

# Làm sạch tên hiển thị (Description)
clean_display_name() {
  local raw="$1"
  echo "$raw" | tr -d '\r\n' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

# Trích xuất tên máy in đang share từ URI (DNS-SD / IPP / USB)
extract_name_from_uri() {
  local uri="$1"
  local extracted=""

  if [[ "$uri" =~ ^usb:// ]]; then
    # Ví dụ: usb://HP/LaserJet%20Pro%20M402dn?serial=...
    extracted=$(echo "$uri" | sed -E 's|^usb://||; s|\?.*$||; s|/| |g')
    extracted=$(urldecode "$extracted")

  elif [[ "$uri" =~ ^dnssd:// ]]; then
    # Ví dụ: dnssd://HP%20LaserJet%20M402dn%20(Phong%20KT)._ipp._tcp.local/?uuid=...
    extracted=$(echo "$uri" | sed -E 's|^dnssd://||; s|\._(ipp|ipps|pdl-datastream|printer)\._tcp\.local.*$||')
    extracted=$(urldecode "$extracted")

  elif [[ "$uri" =~ /printers/([^/?]+) ]]; then
    # Ví dụ: ipp://192.168.1.10:631/printers/May_In_Ke_Toan
    extracted=$(urldecode "${BASH_REMATCH[1]}")

  elif [[ "$uri" =~ ^ipps?:// ]]; then
    # Truy vấn trực tiếp tên máy in qua IPP nếu URI có dạng ipp://IP/ipp/print
    if command -v ipptool >/dev/null 2>&1 && [[ -f /usr/share/cups/ipptool/get-printer-attributes.test ]]; then
      extracted=$(ipptool -tv -T 3 "$uri" /usr/share/cups/ipptool/get-printer-attributes.test 2>/dev/null | \
        grep -E '^\s*(printer-info|printer-make-and-model|printer-name)\s*\(' | head -n 1 | \
        sed -E 's/.*=\s*//' || true)
    fi
    if [[ -z "$extracted" ]]; then
      extracted=$(echo "$uri" | sed -E 's|^[a-zA-Z0-9]+://([^/:?]+).*|\1|; s|\.local$||')
      extracted=$(urldecode "$extracted")
    fi
  fi

  clean_display_name "$extracted"
}

# Trích xuất tên máy in từ địa chỉ IP (khi quét cổng 9100)
extract_name_from_ip() {
  local ip="$1"
  local page_content="$2"
  local brand="$3"
  local extracted=""

  # 1. Ưu tiên lấy tên đang phát sóng qua mDNS / Avahi ứng với IP đó
  if command -v avahi-browse >/dev/null 2>&1; then
    extracted=$(avahi-browse -rpt _ipp._tcp 2>/dev/null | awk -F';' -v target_ip="$ip" '$1 == "=" && $8 == target_ip {print $4; exit}' || true)
    if [[ -z "$extracted" ]]; then
      extracted=$(avahi-browse -rpt _pdl-datastream._tcp 2>/dev/null | awk -F';' -v target_ip="$ip" '$1 == "=" && $8 == target_ip {print $4; exit}' || true)
    fi
    if [[ -n "$extracted" ]]; then
      # Giải mã ký tự escape \032 (khoảng trắng) của avahi-browse
      extracted=$(echo "$extracted" | sed 's/\\032/ /g; s/\\040/(/g; s/\\041/)/g')
    fi
  fi

  # 2. Thử truy vấn qua giao thức IPP trên IP đó
  if [[ -z "$extracted" ]] && command -v ipptool >/dev/null 2>&1 && [[ -f /usr/share/cups/ipptool/get-printer-attributes.test ]]; then
    extracted=$(ipptool -tv -T 2 "ipp://${ip}/ipp/print" /usr/share/cups/ipptool/get-printer-attributes.test 2>/dev/null | \
      grep -E '^\s*(printer-info|printer-make-and-model)\s*\(' | head -n 1 | \
      sed -E 's/.*=\s*//' || true)
  fi

  # 3. Trích xuất từ thẻ <title> của trang quản trị Web máy in
  if [[ -z "$extracted" && -n "$page_content" ]]; then
    extracted=$(echo "$page_content" | tr '\r\n' ' ' | sed -nE 's/.*<[tT][iI][tT][lL][eE][^>]*>([^<]+)<\/[tT][iI][tT][lL][eE]>.*/\1/p' | head -n 1 || true)
  fi

  # 4. Dự phòng nếu vẫn trống
  if [[ -z "$extracted" ]]; then
    extracted="${brand^^}_Printer_${ip##*.}"
  fi

  clean_display_name "$extracted"
}

# Tự động tìm PPD Driver tối ưu theo tên máy in
find_best_driver() {
  local brand="$1"
  local model_hint="$2"
  local ppd=""

  # Lọc mã số model (ví dụ: M402, M404, L2360, L2520, 2700...)
  local model_num=""
  model_num=$(echo "$model_hint" | grep -oEi '(m[0-9]{3}|l[0-9]{4}|hl-?[a-z0-9]+|dcp-?[a-z0-9]+|mfc-?[a-z0-9]+|[0-9]{4})' | head -n 1 | tr -d '-' || true)

  if [[ "$brand" == "brother" ]]; then
    if [[ -n "$model_num" ]]; then
      ppd=$(lpinfo -m 2>/dev/null | grep -i "brlaser" | grep -i "$model_num" | head -n 1 | awk '{print $1}' || true)
      if [[ -z "$ppd" ]]; then
        ppd=$(lpinfo -m 2>/dev/null | grep -i "brother" | grep -i "$model_num" | head -n 1 | awk '{print $1}' || true)
      fi
    fi
    [[ -z "$ppd" ]] && ppd="drv:///brlaser.drv/brl2360d.ppd"

  elif [[ "$brand" == "hp" ]]; then
    if [[ -n "$model_num" ]]; then
      ppd=$(lpinfo -m 2>/dev/null | grep -Ei "hpcups|postscript-hp" | grep -i "$model_num" | head -n 1 | awk '{print $1}' || true)
    fi
    [[ -z "$ppd" ]] && ppd="drv:///sample.drv/generpcl.ppd"
  fi

  echo "$ppd"
}

TARGET_URI=""
PRINTER_BRAND=""
RAW_PRINTER_NAME=""

# ------------------------------------------------------------------------------
# 1. KIỂM TRA MÁY IN CẮM CÁP USB TRỰC TIẾP
# ------------------------------------------------------------------------------
USB_DEV=$(lpinfo -v 2>/dev/null | grep -Ei 'direct usb://' | head -n 1 | awk '{print $2}' || true)
if [[ -n "$USB_DEV" ]]; then
  USB_LIST=$(lsusb 2>/dev/null || true)
  if echo "$USB_LIST" "$USB_DEV" | grep -qiE "Hewlett-Packard|HP"; then
    TARGET_URI="$USB_DEV"
    PRINTER_BRAND="hp"
    RAW_PRINTER_NAME=$(extract_name_from_uri "$TARGET_URI")
    info "Phát hiện máy in HP cắm cổng USB: $RAW_PRINTER_NAME ($TARGET_URI)"
  elif echo "$USB_LIST" "$USB_DEV" | grep -qi "Brother"; then
    TARGET_URI="$USB_DEV"
    PRINTER_BRAND="brother"
    RAW_PRINTER_NAME=$(extract_name_from_uri "$TARGET_URI")
    info "Phát hiện máy in Brother cắm cổng USB: $RAW_PRINTER_NAME ($TARGET_URI)"
  fi
fi

# ------------------------------------------------------------------------------
# 2. DÒ QUA MẠNG DNS-SD / IPP (LẤY TÊN SHARE TRỰC TIẾP TRONG MẠNG)
# ------------------------------------------------------------------------------
if [[ -z "$TARGET_URI" ]]; then
  info "Đang dò tìm thiết bị in được chia sẻ qua DNS-SD / IPP..."
  mapfile -t NET_PRINTERS < <(lpinfo -v 2>/dev/null | grep -Ei 'network (dnssd|ipp|ipps)://' | awk '{print $2}' || true)

  # Quét tìm máy in HP trước (ưu tiên dòng M402 / LaserJet)
  for URI in "${NET_PRINTERS[@]}"; do
    [[ -n "$URI" ]] || continue
    DECODED_URI=$(urldecode "$URI")
    if echo "$DECODED_URI" | grep -qiE 'hp|laserjet|m402|hewlett'; then
      TARGET_URI="$URI"
      PRINTER_BRAND="hp"
      RAW_PRINTER_NAME=$(extract_name_from_uri "$TARGET_URI")
      info "ĐÃ TÌM THẤY MÁY IN HP TRÊN MẠNG: [$RAW_PRINTER_NAME] -> $TARGET_URI"
      break
    fi
  done

  # Nếu không có máy HP, tìm máy in Brother mạng
  if [[ -z "$TARGET_URI" ]]; then
    for URI in "${NET_PRINTERS[@]}"; do
      [[ -n "$URI" ]] || continue
      DECODED_URI=$(urldecode "$URI")
      if echo "$DECODED_URI" | grep -qiE 'brother|hl-|dcp-|mfc-'; then
        TARGET_URI="$URI"
        PRINTER_BRAND="brother"
        RAW_PRINTER_NAME=$(extract_name_from_uri "$TARGET_URI")
        info "ĐÃ TÌM THẤY MÁY IN BROTHER TRÊN MẠNG: [$RAW_PRINTER_NAME] -> $TARGET_URI"
        break
      fi
    done
  fi
fi

# ------------------------------------------------------------------------------
# 3. QUÉT DẢI IP NỘI BỘ (CỔNG 9100) CÓ XÁC THỰC TÊN QUA mDNS / IPP / WEB
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
        RAW_PRINTER_NAME=$(extract_name_from_ip "$IP" "$PAGE_CONTENT" "HP")
        info "Xác thực máy in HP [$RAW_PRINTER_NAME] tại IP: $IP:9100"
        break
      elif echo "$PAGE_CONTENT" | grep -qi "Brother" && [[ -z "$TARGET_URI" ]]; then
        TARGET_URI="socket://${IP}:9100"
        PRINTER_BRAND="brother"
        RAW_PRINTER_NAME=$(extract_name_from_ip "$IP" "$PAGE_CONTENT" "Brother")
        info "Xác thực máy in Brother [$RAW_PRINTER_NAME] tại IP: $IP:9100"
        break
      fi
    done
  fi
fi

# ------------------------------------------------------------------------------
# 4. TẠO HÀNG ĐỢI THEO TÊN SHARE VÀ CẤU HÌNH IN 2 MẶT KHỔ A4
# ------------------------------------------------------------------------------
# Xóa các hàng đợi tên chung chung của phiên bản cũ (nếu có)
lpadmin -x "HP-Printer" 2>/dev/null || true
lpadmin -x "Brother-Printer" 2>/dev/null || true

if [[ -n "$TARGET_URI" ]]; then
  PRINTER_NAME=$(sanitize_queue_name "$RAW_PRINTER_NAME")
  if [[ -z "$PRINTER_NAME" ]]; then
    PRINTER_NAME="${PRINTER_BRAND^^}_Printer"
  fi
  PRINTER_DESC="${RAW_PRINTER_NAME:-$PRINTER_NAME}"

  # Xóa hàng đợi trùng tên hoặc trùng URI cũ để tránh xung đột
  lpadmin -x "$PRINTER_NAME" 2>/dev/null || true
  while read -r OLD_QUEUE; do
    [[ -n "$OLD_QUEUE" ]] && lpadmin -x "$OLD_QUEUE" 2>/dev/null || true
  done < <(lpstat -v 2>/dev/null | awk -v uri="$TARGET_URI" '$0 ~ uri {gsub(":", "", $3); print $3}' || true)

  BEST_PPD=$(find_best_driver "$PRINTER_BRAND" "$RAW_PRINTER_NAME $TARGET_URI")
  info "Đang tiến hành cài đặt máy in: Tên queue=[$PRINTER_NAME] | Mô tả=[$PRINTER_DESC] | Driver ưu tiên=[$BEST_PPD]"

  if [[ "$PRINTER_BRAND" == "hp" ]]; then
    # Nếu là kết nối mạng IPP/DNS-SD thì ưu tiên IPP Everywhere trước, nếu USB/Socket thì dùng PPD
    if [[ "$TARGET_URI" =~ ^(ipp|ipps|dnssd):// ]]; then
      lpadmin -p "$PRINTER_NAME" -D "$PRINTER_DESC" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
      lpadmin -p "$PRINTER_NAME" -D "$PRINTER_DESC" -v "$TARGET_URI" -E -m "$BEST_PPD" 2>/dev/null || \
      lpadmin -p "$PRINTER_NAME" -D "$PRINTER_DESC" -v "$TARGET_URI" -E
    else
      lpadmin -p "$PRINTER_NAME" -D "$PRINTER_DESC" -v "$TARGET_URI" -E -m "$BEST_PPD" 2>/dev/null || \
      lpadmin -p "$PRINTER_NAME" -D "$PRINTER_DESC" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
      lpadmin -p "$PRINTER_NAME" -D "$PRINTER_DESC" -v "$TARGET_URI" -E
    fi

    cupsenable "$PRINTER_NAME"
    cupsaccept "$PRINTER_NAME"
    lpadmin -p "$PRINTER_NAME" -o PageSize=A4 2>/dev/null || true
    lpadmin -p "$PRINTER_NAME" -o media=A4 2>/dev/null || true
    lpadmin -p "$PRINTER_NAME" -o sides=two-sided-long-edge 2>/dev/null || true
    lpadmin -p "$PRINTER_NAME" -o Duplex=DuplexNoTumble 2>/dev/null || true
    lpadmin -p "$PRINTER_NAME" -o HPDuplex=DuplexNoTumble 2>/dev/null || true

    lpadmin -d "$PRINTER_NAME"
    info "=> ĐÃ CÀI ĐẶT VÀ GÁN [$PRINTER_NAME] LÀM MÁY IN MẶC ĐỊNH!"

  elif [[ "$PRINTER_BRAND" == "brother" ]]; then
    lpadmin -p "$PRINTER_NAME" -D "$PRINTER_DESC" -v "$TARGET_URI" -E -m "$BEST_PPD" 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -D "$PRINTER_DESC" -v "$TARGET_URI" -E -m everywhere 2>/dev/null || \
    lpadmin -p "$PRINTER_NAME" -D "$PRINTER_DESC" -v "$TARGET_URI" -E

    cupsenable "$PRINTER_NAME"
    cupsaccept "$PRINTER_NAME"
    lpadmin -p "$PRINTER_NAME" -o PageSize=A4 2>/dev/null || true
    lpadmin -p "$PRINTER_NAME" -o media=A4 2>/dev/null || true
    lpadmin -p "$PRINTER_NAME" -o sides=two-sided-long-edge 2>/dev/null || true
    lpadmin -p "$PRINTER_NAME" -o Duplex=DuplexNoTumble 2>/dev/null || true
    lpadmin -p "$PRINTER_NAME" -o BRDuplex=DuplexNoTumble 2>/dev/null || true

    lpadmin -d "$PRINTER_NAME"
    info "=> ĐÃ CÀI ĐẶT VÀ GÁN [$PRINTER_NAME] LÀM MÁY IN MẶC ĐỊNH!"
  fi
else
  warn "Không phát hiện thấy bất kỳ máy in HP hay Brother nào khả dụng."
fi

# Xóa cache in của WPS Office để nhận tên máy in mới ngay lập tức
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
