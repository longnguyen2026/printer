#!/usr/bin/env bash
# HP Printer Setup for Linux Mint / Ubuntu
# Installs HPLIP from the distribution repositories and helps configure USB/network printers.
# Does not remove existing queues or run HP's downloaded binary installer.

set -Eeuo pipefail
IFS=$'\n\t'

LOG_FILE="/var/log/hp-printer-setup.log"

die() { echo "[LỖI] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
warn() { echo "[CẢNH BÁO] $*" >&2; }

if [[ "${EUID}" -ne 0 ]]; then
  echo "Hãy chạy bằng sudo, ví dụ:"
  echo "  sudo bash $0"
  exit 1
fi

[[ -r /etc/os-release ]] || die "Không xác định được hệ điều hành."
# shellcheck disable=SC1091
source /etc/os-release

if ! command -v apt-get >/dev/null 2>&1; then
  die "Không tìm thấy apt-get. Script dành cho Linux Mint/Ubuntu/Debian."
fi

echo "============================================================"
echo "      CÀI ĐẶT MÁY IN HP - LINUX MINT / UBUNTU"
echo "============================================================"
echo "Script cài HPLIP và công cụ cấu hình từ kho phần mềm hệ thống."
echo "Hỗ trợ máy HP được HPLIP/CUPS nhận diện; model cụ thể có thể cần"
echo "plugin độc quyền hoặc driver khác."
echo

read -r -p "Tiếp tục cài đặt? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Đã hủy."; exit 0; }

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

export DEBIAN_FRONTEND=noninteractive

info "Cập nhật danh sách gói..."
apt-get update

info "Cài CUPS, HPLIP và công cụ phát hiện máy in..."
apt-get install -y \
  cups cups-client cups-filters \
  hplip hplip-data hplip-gui \
  printer-driver-hpcups \
  sane-utils usbutils \
  avahi-daemon

info "Bật dịch vụ CUPS..."
systemctl enable --now cups

# Avahi is helpful for discovering network printers; don't fail if unavailable.
if systemctl list-unit-files avahi-daemon.service >/dev/null 2>&1; then
  systemctl enable --now avahi-daemon || warn "Không bật được Avahi; máy in USB vẫn có thể hoạt động."
fi

echo
echo "============================================================"
echo "CẤU HÌNH MÁY IN HP"
echo "============================================================"
echo "1) Nếu dùng USB: cắm và bật máy in trước khi tiếp tục."
echo "2) Nếu dùng LAN/Wi-Fi: máy in và máy tính nên cùng mạng."
echo "3) Có thể chạy hp-setup để mở trình cấu hình HP."
echo

read -r -p "Bạn muốn mở trình cấu hình hp-setup ngay? [Y/n] " RUN_SETUP
if [[ ! "$RUN_SETUP" =~ ^[Nn]$ ]]; then
  # Root needs access to the active desktop session for the GUI.
  # Prefer launching as the invoking sudo user; fall back to CLI mode.
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && command -v runuser >/dev/null 2>&1; then
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    USER_ID="$(id -u "$SUDO_USER")"
    if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
      info "Đang thử mở hp-setup dưới tài khoản $SUDO_USER..."
      if ! runuser -u "$SUDO_USER" -- env \
        HOME="$USER_HOME" \
        DISPLAY="${DISPLAY:-}" \
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
        XAUTHORITY="${XAUTHORITY:-$USER_HOME/.Xauthority}" \
        DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}" \
        hp-setup; then
        warn "Không mở được giao diện hp-setup. Hãy chạy thủ công: hp-setup"
      fi
    else
      info "Không phát hiện phiên đồ họa. Mở chế độ dòng lệnh hp-setup -i."
      hp-setup -i || warn "hp-setup -i kết thúc với lỗi; kiểm tra kết nối/model và log."
    fi
  else
    info "Chạy hp-setup ở chế độ dòng lệnh."
    hp-setup -i || warn "hp-setup -i kết thúc với lỗi; kiểm tra kết nối/model và log."
  fi
fi

echo
info "Khởi động lại CUPS và kiểm tra hàng đợi..."
systemctl restart cups
lpstat -t || true

echo
echo "Thiết bị USB có thể được kiểm tra bằng:"
echo "  lsusb"
echo
echo "Danh sách máy in trong CUPS:"
lpstat -p 2>/dev/null || true
echo
echo "Mở giao diện quản lý máy in: http://localhost:631"
echo "Log: $LOG_FILE"
echo
echo "Nếu máy in HP yêu cầu plugin độc quyền, dùng công cụ HPLIP:"
echo "  hp-plugin"
echo "Để kiểm tra hỗ trợ model và trạng thái:"
echo "  hp-check -r"
echo "  hp-probe -b usb"
echo "  hp-probe -b net"
echo
echo "LƯU Ý: Máy đa chức năng có thể cần cấu hình quét riêng."
echo "Script không tự xóa máy in cũ, không tự đặt in hai mặt và không ép cài plugin."
