#!/bin/bash

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Vui lòng chạy script với quyền sudo: sudo bash epson-printer.sh"
  exit 1
fi

echo "=== [1/4] Cập nhật hệ thống và cài đặt các gói phụ thuộc CUPS & SANE =="
apt update
apt install -y cups cups-client sane sane-utils sane-airscan printer-driver-cups-pdf libcups2 libusb-0.1-4

echo "=== [2/4] Cài đặt driver Epson Inkjet Printer ESC/P-R chính hãng =="
# Gói driver mã nguồn mở cao cấp cho phần lớn máy in phun màu Epson EcoTank
apt install -y printer-driver-escpr

echo "=== [3/4] Cấu hình dịch vụ CUPS và SANE =="
systemctl enable --now cups
systemctl restart cups

# Kiểm tra và thêm user hiện tại vào nhóm scanner nếu có giao diện đồ họa
CURRENT_USER=$(logname 2>/dev/null || echo $SUDO_USER)
if [ -n "$CURRENT_USER" ]; then
  usermod -aG lp,lpadmin,scanner "$CURRENT_USER"
  echo "[+] Đã thêm user '$CURRENT_USER' vào nhóm quyền máy in và máy scan."
fi

echo "=== [4/4] Quét và liệt kê các máy in Epson đang kết nối (USB/LAN) =="
echo "------------------------------------------------------------------"
lpinfo -v | grep -i epson
echo "------------------------------------------------------------------"
sane-find-scanner | grep -i epson
echo "------------------------------------------------------------------"

echo "[+] Hoàn tất! Bạn có thể truy cập http://localhost:631 để thêm hàng đợi máy in hoặc dùng lệnh lpadmin."
