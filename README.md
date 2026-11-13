# mpquic-download-testbed — Thí nghiệm tải file qua MPQUIC (picoquic)

Server HTTP/3 chạy trên `47.129.174.173` (UDP 4443) phục vụ các file test. Client tải file về
theo 3 chế độ, rồi so sánh single-path với multipath QUIC
(draft-ietf-quic-multipath, bản cài đặt trong picoquic).

```
 Client: Raspberry Pi 4 Model B                      Server AWS 47.129.174.173
 ┌─────────────────────────┐   path 0 (vd. Wi-Fi)    ┌──────────────────────────┐
 │ picoquicdemo -M -A ...  │ ──────────────────────► │ picoquicdemo -M -w www   │
 │ run_experiment.py       │   path 1 (vd. 4G/USB)   │ UDP 4443, HTTP/3 (h3)    │
 │                         │ ──────────────────────► │ file_1MB … file_100MB    │
 └─────────────────────────┘                         └──────────────────────────┘
```

Không viết lại QUIC. `picoquicdemo` đã có sẵn server/client HTTP/3, cờ `-M` (bật multipath)
và `-A` (thêm đường phụ). Repo này bổ sung:

| Thành phần | Vai trò |
|---|---|
| `patches/picoquic-mpstat.patch` | Patch 16 dòng: client in dòng `MPSTAT` cho từng path (số byte nhận, sRTT, RTT min, loss). Nhờ đó chứng minh được dữ liệu thực sự đi trên cả hai đường. |
| `common/build_picoquic.sh` | Clone picoquic ở commit cố định (`PICOQUIC_COMMIT` trong `config.env`), áp patch, rồi build. |
| `server/` | Cài dependency, tạo cert tự ký, sinh file test kèm `SHA256SUMS`, tạo service systemd. |
| `client/run_experiment.py` | Tải lặp N lần, xáo thứ tự các mode trong mỗi lần lặp, kiểm tra SHA-256, ghi `runs.csv`. |
| `client/shape_paths.sh` | (Linux) Giả lập băng thông, delay, loss cho chiều tải xuống của từng interface. |
| `analysis/analyze.py` | Tính median/P25/P75/P95, tỉ lệ thành công, tỉ lệ chia byte giữa các path và tỉ số ghép cặp MP/SP. |

Toàn bộ quy trình đã chạy thử trên loopback (macOS): 12/12 lần tải đúng SHA-256, chế độ mp-sim chia khoảng 55/45 trên 2 path.

---

## 1. Server

### 1.1 Mở cổng trên AWS (bắt buộc)
EC2 → Security Groups → Inbound rules → **Custom UDP, port 4443**, source là IP client
(hoặc `0.0.0.0/0` khi đang thử). Cần thêm SSH (TCP 22) để deploy.

### 1.2 Deploy
Cách A: chạy từ laptop. Sửa `SSH_USER` và `SSH_KEY` trong `config.env` trước:
```bash
./server/deploy.sh
```
Cách B: tự copy repo lên server, rồi chạy trên server:
```bash
cd ~/mpquic-download-testbed && ./server/setup_server.sh
```
`setup_server.sh` sẽ: cài gcc/cmake/openssl → build vào `/opt/mpquic/bin` → tạo cert →
sinh `file_{1,10,50,100}MB.bin` + `SHA256SUMS` + `index.html` → đặt sysctl UDP buffer →
bật service `mpquic-server`.

### 1.3 Vận hành
```bash
sudo systemctl status mpquic-server
journalctl -u mpquic-server -f
sudo systemctl restart mpquic-server
```
Muốn ghi qlog phía server: thêm `Environment=QLOG=1` vào unit file rồi restart.
qlog cho file lớn có dung lượng lớn, chỉ nên bật khi debug.

---

## 2. Client (Raspberry Pi 4 Model B)

### 2.1 Chuẩn bị Pi và build
- Nên dùng **Raspberry Pi OS 64-bit (Bookworm)**. Bản 32-bit vẫn build được nhưng chậm hơn.
- Dùng nguồn 5V/3A chính hãng và có tản nhiệt/quạt. Khi thiếu điện áp hoặc quá nhiệt, Pi
  tự hạ xung và kết quả đo bị sai (script ghi lại `vcgencmd get_throttled` để phát hiện).
```bash
sudo apt-get update
sudo apt-get install -y build-essential cmake git pkg-config libssl-dev python3
./client/build_client.sh          # → bin/picoquicdemo  (~5–10 phút trên Pi 4)
```
(Client cũng build được trên Ubuntu/macOS, cùng lệnh; macOS: `brew install cmake pkg-config openssl@3`.)

### 2.1b Ba yếu tố riêng của Pi 4 có thể làm sai phép đo

| Yếu tố | Vì sao | Script đã xử lý |
|---|---|---|
| CPU không có lệnh AES | BCM2711 (Cortex-A72) không có ARMv8 Crypto Extensions, nên AES-GCM chạy bằng phần mềm và Pi dễ nghẽn CPU trước khi nghẽn mạng | Client ép **ChaCha20** (`CLIENT_CIPHER="20"` trong `config.env`, tương ứng cờ `-C 20`) và ghi `cpu_pct` của mỗi lần tải. `analyze.py` cảnh báo khi median > 85 % |
| Thẻ SD ghi chậm | Thẻ SD thường chỉ ghi 20–40 MB/s, thấp hơn tốc độ tải ở vài trăm Mbps | File được tải vào **RAM** (`/dev/shm/mpquic-dl`), kiểm SHA-256 rồi xoá. Pi 4 bản 2 GB trở lên là đủ cho file 100 MB |
| Hạ xung do nhiệt/điện | Pi hạ xung khi quá 80 °C hoặc khi điện áp thấp | Ghi `soc_temp_c` mỗi lần tải; `meta.txt` ghi `throttled_start/end` và in cảnh báo nếu khác `0x0` |

Nếu `cpu_pct` ≈ 100 % ở chế độ `sp`, client đã nghẽn CPU. Khi đó so sánh MP với SP sẽ
không phản ánh mạng. Hãy giảm tốc độ đường truyền bằng `shape_paths.sh`, hoặc ghi rõ hạn chế này.

### 2.2 Ba chế độ

| Mode | Cờ picoquic | Ý nghĩa | Chạy được ở đâu |
|---|---|---|---|
| `sp` | (không) | Single-path QUIC, dùng làm baseline | Mọi nơi |
| `mp-sim` | `-M -A 0.0.0.0/0` | Multipath, path 2 dùng cùng interface nhưng khác UDP port | Mọi nơi. Dùng để kiểm tra giao thức; **không** tăng băng thông vì hai path chung một bottleneck |
| `mp` | `-M -A <ip2>/<ifindex2>` | Multipath trên 2 interface thật (vd. Wi-Fi + 4G) | **Client Linux** |

Thử nhanh một lần tải:
```bash
./client/download.sh sp     file_10MB.bin
./client/download.sh mp-sim file_10MB.bin
ALT_PATHS="192.168.1.50/3" ./client/download.sh mp file_10MB.bin   # wlan0 làm path 2
```
Kết quả đúng khi thấy `Enable multipath: Success`, có 2 dòng `MPSTAT path=…`, và cả hai đều có `bytes_received` > 0.

### 2.3 Chuẩn bị multipath thật trên Pi
Pi 4 có sẵn `eth0` (Gigabit) và `wlan0` (Wi-Fi 5). Có thể cắm thêm USB 4G hoặc điện thoại
chia sẻ mạng qua USB (hiện thành `usb0`/`eth1`/`wwan0`).

| Cặp đường | Đánh giá |
|---|---|
| `eth0` + `wlan0` cùng một router nhà | Dễ làm, nhưng **chung đường ISP**. Multipath chỉ có lợi nếu Wi-Fi/LAN là nút cổ chai; nếu nghẽn ở ISP thì MP/SP ≈ 1 |
| `eth0` hoặc `wlan0` + 4G (USB) | **Hai đường độc lập thật**, phù hợp để đo khả năng cộng băng thông. RTT hai đường chênh nhau nhiều, nên cũng đo được hiệu ứng lệch RTT |

1. Bật cả hai interface. Trên Bookworm, NetworkManager tự gán default route cho mỗi interface
   với metric khác nhau (`ip route` sẽ thấy 2 dòng `default`).
2. Lấy IP và ifindex. Trên Pi thường gặp `lo`=1, `eth0`=2, `wlan0`=3, USB=4:
   ```bash
   ip -o -4 addr show     # vd. "3: wlan0 inet 192.168.1.50/24"  → ALT_PATHS=192.168.1.50/3
   ip route               # xác định interface nào đang là default (sẽ là path 0)
   ```
   Path 0 đi theo default route có metric thấp nhất (thường là `eth0`). Interface còn lại
   khai báo trong `ALT_PATHS`. Muốn chắc chắn, đặt thêm `PRIMARY_IF=<ifindex của path 0>`.
3. Picoquic gửi kèm `ipi_ifindex`, nên kernel ép gói ra đúng interface. Nếu path 2 vẫn không
   lên, thêm policy routing để gói trả về cũng đi đúng đường:
   ```bash
   sudo ip rule add from 192.168.43.100 table 102
   sudo ip route add default via 192.168.43.1 dev usb0 table 102
   sudo sysctl -w net.ipv4.conf.all.rp_filter=2      # loose, tránh kernel drop gói vào usb0
   ```
4. Kiểm tra từng đường trước khi đo: `ping -I eth0 47.129.174.173` và `ping -I wlan0 47.129.174.173`.

**macOS:** khi không có `IP_PKTINFO`, picoquic chỉ đặt địa chỉ nguồn chứ không chọn được
interface ra. Vì vậy chế độ `mp` trên macOS **chưa được kiểm chứng** và nhiều khả năng gói
vẫn đi ra interface mặc định. Trên Mac chỉ nên dùng `sp` và `mp-sim`, còn `mp` thì chạy trên Linux
(máy thật, hoặc VM bridge 2 card mạng).

### 2.4 Chạy thí nghiệm
```bash
# Kiểm tra giao thức
python3 client/run_experiment.py -n 10 -m sp,mp-sim --label "pi-check"

# Thí nghiệm chính: path 0 = eth0 (ifindex 2), path 1 = wlan0 (ifindex 3)
PRIMARY_IF=2 ALT_PATHS="192.168.1.50/3" \
python3 client/run_experiment.py -n 30 -m sp,mp -f file_10MB.bin,file_100MB.bin --label "pi4 eth0+wlan0"

python3 analysis/analyze.py results/<stamp>/runs.csv --plot
```
Mỗi lần chạy tạo thư mục `results/<stamp>/` gồm `runs.csv`, `meta.txt` (commit, seed,
ALT_PATHS, máy) và `logs/` (log đầy đủ từng lần tải). Thêm `--qlog` để có qlog mở bằng
https://qvis.quictools.info.

### 2.5 Giả lập điều kiện đường truyền (Linux, tuỳ chọn)
```bash
sudo client/shape_paths.sh add eth0 20mbit 10ms
sudo client/shape_paths.sh add usb0 5mbit 60ms 0.5%
sudo client/shape_paths.sh show
sudo client/shape_paths.sh del eth0; sudo client/shape_paths.sh del usb0
```
Script chỉ shape chiều tải xuống (ingress → ifb → netem). Nên ghi cấu hình shaping vào `--label`.

---

## 3. Đọc kết quả cho đúng

- **Goodput** = kích thước file / thời gian kết nối của picoquic (từ lúc bắt đầu kết nối tới lúc
  đóng, *gồm cả handshake*). Với file nhỏ, handshake chiếm phần lớn thời gian, nên mức lợi
  của multipath chủ yếu thể hiện ở file lớn.
- **Lần tải hỏng không bị loại bỏ**: những lần SHA-256 sai hoặc timeout vẫn nằm trong CSV với
  `ok=0`. Cột `ok/n` cho biết số lần thành công.
- **So sánh ghép cặp**: `analyze.py` chia goodput của mode cho goodput của `sp` trong cùng lần
  lặp và cùng file, nên giảm được ảnh hưởng của dao động mạng theo thời gian. Thứ tự các mode
  được xáo trong mỗi lần lặp, seed ghi trong `meta.txt`.
- Mỗi lần tải dùng thư mục làm việc mới nên không có session ticket, tức là luôn full handshake
  và không có 0-RTT làm lệch kết quả.
- **Multipath chỉ cộng được băng thông khi hai path có bottleneck riêng.** `mp-sim` chung một
  bottleneck, nên MP/SP ≈ 1 là kết quả *đúng như dự đoán*, không phải lỗi. Nếu băng thông phía
  AWS (giới hạn theo loại instance) nhỏ hơn tổng hai đường của client, bottleneck sẽ nằm ở server.
- Scheduler của picoquic phân phối gói theo congestion window từng path. Khi hai path chênh
  RTT nhiều, gói về không theo thứ tự (head-of-line ở tầng stream) có thể làm MP *chậm hơn* SP.
  Đây là hiện tượng đáng đo, cột `pX_share` và `pX_srtt_ms` giúp giải thích.
- Nên chạy n ≥ 20–30 mỗi nhóm. Script sẽ cảnh báo khi nhóm có ít hơn 10 lần.

## 4. Xử lý sự cố

| Triệu chứng | Nguyên nhân thường gặp |
|---|---|
| Client treo rồi timeout, không thấy `Negotiated ALPN` | Security Group chưa mở UDP 4443, hoặc mạng client chặn UDP |
| `Cannot send GET command` | Thiếu SNI. Script đã truyền `-n mpquic.local`; nếu tự chạy tay thì phải thêm `-n` |
| `Cannot parse the specified scenario` | Đường dẫn file phải bắt đầu bằng `/` (vd. `/file_10MB.bin`) |
| `Enable multipath: Refused` | Server chạy thiếu `-M` (xem `run_server.sh`) |
| Chỉ có `MPSTAT path=0` ở chế độ `mp` | Sai ip/ifindex, interface 2 không có route ra Internet, hoặc bị rp_filter (xem 2.3) |
| `cpu_pct` ≈ 100 % | Pi nghẽn CPU: kiểm tra `CLIENT_CIPHER="20"`, tản nhiệt và `vcgencmd get_throttled` |
| Chạy `mp` thì path 0 và path 1 cùng `local=` IP | Sai `ALT_PATHS` (đang trỏ vào IP của interface mặc định) |
| Có path 1 nhưng `bytes_received` ≈ 0 | Path 1 bị mất gói liên tục nên bị picoquic đánh dấu suspended. Kiểm tra lại bằng `ping -I <if2> 47.129.174.173` |
