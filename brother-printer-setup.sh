#!/usr/bin/env bash
# Brother Printer Setup for Linux Mint / Ubuntu
# Uses Brother's official linux-brprinter-installer for the model selected by the user.
# Does not remove existing printers or force duplex on every model.

set -Eeuo pipefail
IFS=$'\n\t'

INSTALLER_URL="https://download.brother.com/welcome/dlf006893/linux-brprinter-installer-2.2.4-1.gz"
TEMP_DIR=""
LOG_FILE="/var/log/brother-printer-setup.log"

cleanup() {
  [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]] && rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

die() { echo "[LOI] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
warn() { echo "[CANH BAO] $*" >&2; }

if [[ "${EUID}" -ne 0 ]]; then
  echo "Hãy chạy bằng sudo, ví dụ:"
  echo "  sudo bash $0"
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  die "Không xác định được hệ điều hành."
fi
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-} ${ID_LIKE:-}" in
  *linuxmint*|*ubuntu*|*debian*) ;;
  *) warn "Script được thiết kế cho Linux Mint/Ubuntu/Debian; tiếp tục nhưng cần tự kiểm tra tương thích." ;;
esac

if ! command -v apt-get >/dev/null 2>&1; then
  die "Không tìm thấy apt-get. Script này dành cho Linux Mint/Ubuntu/Debian."
fi

echo "============================================================"
echo "   CÀI ĐẶT DRIVER MÁY IN BROTHER - LINUX MINT"
echo "============================================================"
echo "Script dùng bộ cài Brother theo model, không cài tất cả driver"
echo "không liên quan vào máy và không xóa máy in đang có."
echo

read -r -p "Nhập model chính xác trên tem máy (ví dụ HL-L2360D, DCP-L2520D, MFC-L2700DW): " MODEL
MODEL="${MODEL//[[:space:]]/}"
MODEL="${MODEL^^}"

[[ -n "$MODEL" ]] || die "Bạn chưa nhập model."
if [[ ! "$MODEL" =~ ^[A-Z0-9-]+(\([A-Z0-9]+\))?$ ]]; then
  die "Model chứa ký tự không hợp lệ. Hãy nhập model như in trên tem máy."
fi

echo
echo "Model sẽ cài: $MODEL"
echo "Kết nối: hãy cắm cáp USB trước nếu dùng USB; nếu dùng mạng, chuẩn bị địa chỉ IP."
read -r -p "Tiếp tục? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Đã hủy."; exit 0; }

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

info "Cập nhật danh sách gói..."
export DEBIAN_FRONTEND=noninteractive
apt-get update

info "Cài CUPS và công cụ tải/giải nén..."
apt-get install -y cups cups-client cups-filters wget ca-certificates gzip

info "Bật dịch vụ in CUPS..."
systemctl enable --now cups

TEMP_DIR="$(mktemp -d -t brother-driver-XXXXXXXX)"
cd "$TEMP_DIR"

info "Tải công cụ cài đặt driver chính thức của Brother..."
if ! wget --https-only --timeout=30 --tries=3 -O linux-brprinter-installer.gz "$INSTALLER_URL"; then
  die "Không tải được bộ cài Brother. Kiểm tra Internet hoặc URL/tính khả dụng của bộ cài."
fi
gzip -t linux-brprinter-installer.gz || die "Tệp tải về không phải gzip hợp lệ."
gunzip linux-brprinter-installer.gz
chmod 700 linux-brprinter-installer

echo
echo "============================================================"
echo "BỘ CÀI BROTHER SẮP CHẠY"
echo "============================================================"
echo "Model: $MODEL"
echo "Bộ cài Brother có thể hỏi loại kết nối, giấy phép và cài gói phụ thuộc."
echo "Đọc từng câu hỏi và trả lời theo thiết bị thực tế."
echo "Không tự động trả lời hàng loạt vì lựa chọn USB/LAN khác nhau theo máy."
echo

# Brother's installer must be run interactively; do not pipe guessed answers.
if ! bash ./linux-brprinter-installer "$MODEL"; then
  warn "Bộ cài Brother trả về lỗi. Xem log: $LOG_FILE"
  exit 1
fi

echo
info "Khởi động lại CUPS và kiểm tra hàng đợi in..."
systemctl restart cups
sleep 2
lpstat -t || true

echo
echo "Danh sách máy in đã được CUPS nhận:"
lpstat -p 2>/dev/null || true

echo
echo "Có muốn đặt in hai mặt làm mặc định không?"
echo "Chỉ chọn Có nếu model của bạn hỗ trợ in hai mặt tự động."
read -r -p "Đặt mặc định in hai mặt? [y/N] " DUPLEX
if [[ "$DUPLEX" =~ ^[Yy]$ ]]; then
  echo
  lpstat -p 2>/dev/null || true
  read -r -p "Nhập đúng tên máy in trong danh sách trên: " PRINTER_NAME
  if [[ -n "$PRINTER_NAME" ]] && lpstat -p "$PRINTER_NAME" >/dev/null 2>&1; then
    # Brother/CUPS PPD options differ by model. Try the common option, then report status.
    if lpadmin -p "$PRINTER_NAME" -o Duplex=DuplexNoTumble; then
      lpoptions -p "$PRINTER_NAME" -o Duplex=DuplexNoTumble || true
      info "Đã yêu cầu CUPS đặt in hai mặt mặc định. Hãy kiểm tra hộp thoại in vì tùy chọn tùy model/driver."
    else
      warn "Không đặt được tùy chọn Duplex cho hàng đợi này; không thay đổi thêm."
    fi
  else
    warn "Tên máy in không khớp hàng đợi CUPS; bỏ qua cấu hình in hai mặt."
  fi
else
  info "Giữ nguyên cấu hình in hai mặt hiện tại."
fi

echo
echo "============================================================"
echo "HOÀN TẤT"
echo "============================================================"
echo "Model đã yêu cầu cài: $MODEL"
echo "Log: $LOG_FILE"
echo "Kiểm tra máy in:  lpstat -t"
echo "Trang quản lý CUPS: http://localhost:631"
echo
echo "Lưu ý:"
echo "- Bộ cài Brother hỗ trợ model nào phụ thuộc danh sách hỗ trợ của Brother."
echo "- Nếu model không được hỗ trợ bởi công cụ này, hãy tải driver riêng từ trang hỗ trợ Brother."
echo "- Máy đa chức năng có thể cần cài thêm driver scanner riêng; script này tập trung vào in."
