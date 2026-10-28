sudo bash -c 'cat << "EOF" > /tmp/run-printer.sh
#!/usr/bin/env bash
set -Eeuo pipefail

echo "============================================================"
echo " CẤU HÌNH IN 2 MẶT & KHỔ GIẤY A4 CHO TOÀN BỘ MÁY IN"
echo "============================================================"

systemctl restart cups
sleep 1

# Lấy danh sách máy in hiện có
mapfile -t ALL_QUEUES < <(lpstat -p 2>/dev/null | awk "{print \$2}" | sort -u || true)

if [[ ${#ALL_QUEUES[@]} -eq 0 ]]; then
  echo "[CẢNH BÁO] Chưa có hàng đợi in nào."
  exit 1
fi

for QUEUE in "${ALL_QUEUES[@]}"; do
  [[ -n "$QUEUE" ]] || continue
  echo "--- Đang cấu hình: $QUEUE ---"
  
  # Khóa khổ giấy A4
  lpadmin -p "$QUEUE" -o PageSize=A4 2>/dev/null || true
  lpadmin -p "$QUEUE" -o media=A4 2>/dev/null || true
  
  # Bật in 2 mặt chuẩn IPP (áp dụng trực tiếp cho Brother HL-L2360D Driverless)
  lpadmin -p "$QUEUE" -o sides=two-sided-long-edge 2>/dev/null || true
  
  # Bật in 2 mặt phần cứng PPD
  lpadmin -p "$QUEUE" -o Duplex=DuplexNoTumble 2>/dev/null || true
  lpadmin -p "$QUEUE" -o BRDuplex=DuplexNoTumble 2>/dev/null || true
  
  echo "Hoàn tất: $QUEUE đã sẵn sàng in 2 mặt (lật cạnh dài) và khổ A4."
done

# Đặt máy in mặc định
lpadmin -d MayInVanPhong 2>/dev/null || lpadmin -d "${ALL_QUEUES[0]}"

echo
echo "============================================================"
echo "KẾT QUẢ KIỂM TRA MÁY IN MẶC ĐỊNH:"
lpstat -d
lpoptions -p MayInVanPhong -l | grep -Ei "sides|duplex|pagesize" || true
echo "============================================================"
EOF
bash /tmp/run-printer.sh
rm -f /tmp/run-printer.sh
'
