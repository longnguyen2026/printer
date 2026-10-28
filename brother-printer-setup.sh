#!/usr/bin/env bash
# Brother printer setup for Linux Mint / Ubuntu.
# Default model: HL-L2360D. Installs using Brother's official installer.
# Detects network/USB devices and only attempts duplex configuration when supported.

set -Eeuo pipefail
IFS=$'\n\t'

INSTALLER_URL="https://download.brother.com/welcome/dlf006893/linux-brprinter-installer-2.2.4-1.gz"
LOG_FILE="/var/log/brother-printer-setup.log"
TEMP_DIR=""

info() { echo "[INFO] $*"; }
warn() { echo "[CẢNH BÁO] $*" >&2; }
die() { echo "[LỖI] $*" >&2; exit 1; }
cleanup() { [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]] && rm -rf -- "$TEMP_DIR"; }
trap cleanup EXIT

if [[ $EUID -ne 0 ]]; then
  echo "Chạy bằng lệnh:"
  echo "curl -fsSL https://raw.githubusercontent.com/longnguyen2026/printer/main/brother-printer-setup.sh | sudo bash"
  exit 1
fi

[[ -r /etc/os-release ]] || die "Không xác định được hệ điều hành."
# shellcheck disable=SC1091
source /etc/os-release
command -v apt-get >/dev/null 2>&1 || die "Script dành cho Linux Mint/Ubuntu/Debian."

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================================"
echo " BROTHER PRINTER SETUP - LINUX MINT / UBUNTU"
echo " Cài driver + phát hiện thiết bị + kiểm tra Duplex"
echo "============================================================"
echo "Mặc định: Brother HL-L2360D. Không xóa hàng đợi hiện có."
echo

export DEBIAN_FRONTEND=noninteractive
info "Cập nhật danh sách gói và cài công cụ..."
apt-get update
apt-get install -y cups cups-client cups-filters wget ca-certificates gzip usbutils avahi-utils
systemctl enable --now cups

echo
echo "========== PHÁT HIỆN THIẾT BỊ =========="
echo "--- USB ---"
lsusb 2>/dev/null | grep -i brother || echo "Không thấy thiết bị Brother qua USB."
echo
echo "--- URI máy in mà CUPS phát hiện ---"
lpinfo -v 2>/dev/null | grep -Ei 'brother|usb|dnssd|ipp|socket|lpd' | head -n 80 || true
echo
echo "--- Máy in quảng bá qua mạng ---"
if command -v avahi-browse >/dev/null 2>&1; then
  avahi-browse -rt _ipp._tcp 2>/dev/null | grep -Ei 'Brother|hostname|address|port|txt' | head -n 80 || true
  avahi-browse -rt _printer._tcp 2>/dev/null | grep -Ei 'Brother|hostname|address|port|txt' | head -n 80 || true
  avahi-browse -rt _pdl-datastream._tcp 2>/dev/null | grep -Ei 'Brother|hostname|address|port|txt' | head -n 80 || true
fi

echo
echo "========== CHỌN MODEL =========="
read -r -p "Nhập model Brother cần cài [Enter = HL-L2360D]: " MODEL
MODEL="${MODEL:-HL-L2360D}"
# Trim leading/trailing whitespace, remove internal spaces, uppercase.
MODEL="$(printf '%s' "$MODEL" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
[[ -n "$MODEL" ]] || MODEL="HL-L2360D"
if [[ ! "$MODEL" =~ ^[A-Z0-9-]+(\([A-Z0-9]+\))?$ ]]; then
  die "Model không hợp lệ: $MODEL. Ví dụ: HL-L2360D"
fi
info "Model được chọn: $MODEL"

TEMP_DIR="$(mktemp -d -t brother-driver-XXXXXXXX)"
cd "$TEMP_DIR"
info "Tải bộ cài chính thức Brother..."
wget --https-only --timeout=30 --tries=3 -O linux-brprinter-installer.gz "$INSTALLER_URL" \
  || die "Không tải được bộ cài Brother."
gzip -t linux-brprinter-installer.gz || die "Tệp tải về không hợp lệ."
gunzip linux-brprinter-installer.gz
chmod 700 linux-brprinter-installer

echo
echo "========== CÀI DRIVER =========="
echo "Làm theo các câu hỏi của bộ cài. Chọn đúng USB hoặc URI/IP mạng."
if ! bash ./linux-brprinter-installer "$MODEL"; then
  warn "Bộ cài báo lỗi với model $MODEL. Tiếp tục kiểm tra hàng đợi hiện có."
fi

systemctl restart cups
sleep 2

echo
echo "========== HÀNG ĐỢI CUPS =========="
lpstat -p 2>/dev/null || true
