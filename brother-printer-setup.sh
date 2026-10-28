#!/usr/bin/env bash
# Brother printer installer for Linux Mint / Ubuntu.
# Keeps the original HL-L2360D default workflow, supports additional models,
# detects USB/network printer advertisements, and repairs Duplex only when safe.

set -Eeuo pipefail
IFS=$'\n\t'

INSTALLER_URL="https://download.brother.com/welcome/dlf006893/linux-brprinter-installer-2.2.4-1.gz"
LOG_FILE="/var/log/brother-printer-setup.log"
TEMP_DIR=""

info() { echo "[INFO] $*"; }
warn() { echo "[CẢNH BÁO] $*" >&2; }
die() { echo "[LỖI] $*" >&2; exit 1; }

cleanup() {
  [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]] && rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

if [[ $EUID -ne 0 ]]; then
  echo "Chạy bằng sudo:"
  echo "  curl -fsSL https://raw.githubusercontent.com/longnguyen2026/printer/main/brother-printer-setup.sh | sudo bash"
  exit 1
fi

[[ -r /etc/os-release ]] || die "Không xác định được hệ điều hành."
# shellcheck disable=SC1091
source /etc/os-release
command -v apt-get >/dev/null 2>&1 || die "Script dành cho Linux Mint/Ubuntu/Debian có apt-get."

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================================"
echo " BROTHER PRINTER SETUP - LINUX MINT / UBUNTU"
echo " Cài driver + phát hiện thiết bị + kiểm tra Duplex"
echo "============================================================"
echo "Mặc định: Brother HL-L2360D, giống quy trình script gốc."
echo "Bạn có thể nhập model khác hoặc nhiều model, mỗi model một lần."
echo "Script không xóa hàng đợi máy in đang có."
echo

export DEBIAN_FRONTEND=noninteractive
info "Cập nhật danh sách gói và cài công cụ cần thiết..."
apt-get update
apt-get install -y cups cups-client cups-filters wget ca-certificates gzip usbutils avahi-utils

systemctl enable --now cups
systemctl restart cups

echo
echo "========== PHÁT HIỆN THIẾT BỊ =========="
echo "--- USB ---"
lsusb 2>/dev/null | grep -i brother || echo "Chưa thấy thiết bị Brother qua USB."
echo
echo "--- Thiết bị in CUPS ---"
lpinfo -v 2>/dev/null | grep -Ei 'brother|usb|dnssd|ipp|socket|lpd' | head -n 80 || true
echo
echo "--- Máy in Brother quảng bá qua mạng (mDNS/Bonjour) ---"
if command -v avahi-browse >/dev/null 2>&1; then
  avahi-browse -rt _ipp._tcp 2>/dev/null | grep -Ei 'brother|hostname|address|port|txt' | head -n 80 || true
  avahi-browse -rt _printer._tcp 2>/dev/null | grep -Ei 'brother|hostname|address|port|txt' | head -n 80 || true
  avahi-browse -rt _pdl-datastream._tcp 2>/dev/null | grep -Ei 'brother|hostname|address|port|txt' | head -n 80 || true
fi

echo
echo "========== CHỌN MODEL =========="
read -r -p "Nhập model Brother cần cài [mặc định HL-L2360D]: " MODEL
MODEL="${MODEL//[[:space:]]/}"
MODEL="${MODEL^^}"
MODEL="${MODEL:-HL-L2360D}"
[[ "$MODEL" =~ ^[A-Z0-9-]+(\([A-Z0-9]+\))?$ ]] || die "Model có ký tự không hợp lệ: $MODEL"
info "Model được chọn: $MODEL"

echo
echo "========== TẢI BỘ CÀI CHÍNH THỨC BROTHER =========="
TEMP_DIR="$(mktemp -d -t brother-driver-XXXXXXXX)"
cd "$TEMP_DIR"
wget --https-only --timeout=30 --tries=3 -O linux-brprinter-installer.gz "$INSTALLER_URL" \
  || die "Không tải được bộ cài Brother."
gzip -t linux-brprinter-installer.gz || die "Tệp tải về không hợp lệ."
gunzip linux-brprinter-installer.gz
chmod 700 linux-brprinter-installer

echo
echo "Bộ cài Brother sẽ chạy cho $MODEL."
echo "Trả lời các câu hỏi theo kết nối thực tế."
echo "USB: chọn thiết bị USB tương ứng nếu được hỏi."
echo "Mạng: chọn đúng IP/URI của máy in."
echo
if ! bash ./linux-brprinter-installer "$MODEL"; then
  warn "Bộ cài Brother báo lỗi cho model $MODEL. Tiếp tục kiểm tra hàng đợi hiện có."
