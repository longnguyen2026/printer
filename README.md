# Lệnh cài driver máy in brother
````bash
curl -fsSL https://raw.githubusercontent.com/longnguyen2026/printer/main/brother-printer-setup.sh | sudo bash
````

# Lệnh kiểm tra sau khi cài
````bash
lpoptions -p $(lpstat -p | awk '{print $2}' | grep -i "2360" | head -n 1) -l | grep Duplex
````
Nếu kết quả hiển thị *DuplexNoTumble (có dấu hoa thị phía trước) chứng minh chế độ in 2 mặt tự động đã được kích hoạt thành công.
