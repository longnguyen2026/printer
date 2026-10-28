#!/usr/bin/env bash
# Brother Printer Setup + Duplex Repair for Linux Mint / Ubuntu
# Uses Brother's official Linux driver installer, discovers USB/network devices,
# and repairs CUPS duplex defaults only when the queue advertises a duplex option.

set -Eeuo pipefail
IFS=$'\n\t'

INSTALLER_URL="https://download.brother.com/welcome/dlf006893/linux-brprinter-installer-2.2.4-1.gz"
LOG_FILE="/var/log/brother-printer-setup.log"
TEMP_DIR=""

cleanup() {
  [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]] && rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

info() { echo "[INFO] $*"; }
warn() { echo "[CẢNH BÁO] $*" >&2; }
die() { echo "[LỖI] $*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  echo "Chạy bằng sudo:"
  echo "  sudo bash $0"
  exit 1
fi

[[ -r /etc/os-release ]] || die "Không xác định được hệ điều hành."
# shellcheck disable=SC1091
source /etc/os-release
if ! command -v apt-get >/dev/null 2>&1; then
  die "Script dành cho Linux Mint/Ubuntu/Debian có apt-get."
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================================"
echo " BROTHER PRINTER SETUP + FIX IN HAI MẶT"
echo " Linux Mint / Ubuntu"
echo "============================================================"
echo "Script sẽ phát hiện thiết bị USB và máy in quảng bá trên mạng."
echo "Bạn cần xác nhận model chính xác trên tem từng máy."
echo "Không thể cài 'mọi driver Brother trên thế giới' bằng một gói;"
echo "bộ cài chính thức chỉ cài model bạn chọn và có hỗ trợ."
echo

read -r -p "Tiếp tục? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Đã hủy."; exit 0; }

export DEBIAN_FRONTEND=noninteractive
info "Cập nhật danh sách gói..."
apt-get update
info "Cài CUPS, công cụ phát hiện USB/mạng và tiện ích cần thiết..."
apt-get install -y cups cups-client cups-filters wget ca-certificates gzip usbutils avahi-utils

systemctl enable --now cups
systemctl restart cups

echo
echo "========== PHÁT HIỆN THIẾT BỊ =========="
echo "--- Thiết bị USB Brother (nếu có) ---"
USB_BROTHER="$(lsusb 2>/dev/null | grep -i brother || true)"
if [[ -n "$USB_BROTHER" ]]; then
  printf '%s\n' "$USB_BROTHER"
else
  echo "Không thấy thiết bị Brother qua lsusb. Hãy bật máy in và kiểm tra cáp USB."
fi

echo
echo "--- Kết nối máy in mà CUPS nhìn thấy ---"
lpinfo -v 2>/dev/null | grep -Ei 'brother|usb|dnssd|ipp|socket|lpd' | head -n 80 || true

echo
echo "--- Máy in quảng bá trên mạng (mDNS/Bonjour) ---"
if command -v avahi-browse >/dev/null 2>&1; then
  avahi-browse -rt _ipp._tcp 2>/dev/null | grep -Ei 'brother|hostname|address|port|txt' | head -n 80 || true
  avahi-browse -rt _printer._tcp 2>/dev/null | grep -Ei 'brother|hostname|address|port|txt' | head -n 80 || true
  avahi-browse -rt _pdl-datastream._tcp 2>/dev/null | grep -Ei 'brother|hostname|address|port|txt' | head -n 80 || true
else
  warn "Không có avahi-browse; bỏ qua dò tìm mDNS."
fi

echo
echo "============================================================"
echo " CÀI DRIVER THEO MODEL"
echo "============================================================"
echo "Nhập model chính xác của từng máy Brother cần cài."
echo "Ví dụ: HL-L2360D, DCP-L2520D, MFC-L2700DW."
echo "Để kết thúc danh sách, nhấn Enter khi được hỏi model."
echo "Mỗi lần chạy, bộ cài sẽ hỏi lựa chọn kết nối/Device URI."
echo "USB: thường chọn No khi hỏi chỉ định DeviceURI."
echo "Mạng: chọn Yes rồi chọn IP/URI đúng của máy in."
echo
