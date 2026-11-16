# mpquic-download-testbed

Testbed đo hiệu năng tải file qua **Multipath QUIC** ([draft-ietf-quic-multipath](https://datatracker.ietf.org/doc/draft-ietf-quic-multipath/)),
sử dụng bản cài đặt multipath có sẵn trong [picoquic](https://github.com/private-octopus/picoquic).
Client (Raspberry Pi 4) tải file qua HTTP/3 từ server trên AWS, đồng thời trên **hai interface
mạng thật**. Mỗi lần tải được kiểm tra toàn vẹn bằng SHA-256 và ghi lại thống kê theo từng path.

```
 Client: Raspberry Pi 4 Model B                           Server: AWS EC2 (47.129.174.173)
 ┌──────────────────────────────┐   path 0 (eth0)         ┌──────────────────────────────┐
 │ picoquicdemo -M -A <ip>/<if> │ ──────────────────────► │ picoquicdemo -M              │
 │ client/run_experiment.py     │   path 1 (wlan0 / 4G)   │ HTTP/3 (h3), UDP 4443        │
 │                              │ ──────────────────────► │ file_1MB … file_100MB        │
 └──────────────────────────────┘                         └──────────────────────────────┘
```

Dự án không tự cài đặt QUIC. `picoquicdemo` đã có sẵn client và server HTTP/3, cờ `-M` để bật
multipath và cờ `-A` để khai báo path bổ sung. Repo này bổ sung phần build có thể tái lập, phần
triển khai, quy trình đo lặp và phân tích kết quả.

## Mục lục
1. [Cấu trúc repo](#1-cấu-trúc-repo)
2. [Yêu cầu](#2-yêu-cầu)
3. [Cấu hình](#3-cấu-hình)
4. [Cài đặt picoquic](#4-cài-đặt-picoquic)
5. [Setup server](#5-setup-server-aws)
6. [Setup client](#6-setup-client-raspberry-pi-4)
7. [Setup multipath trên client](#7-setup-multipath-trên-client)
8. [Smoke test](#8-smoke-test)
9. [Chạy thí nghiệm và phân tích](#9-chạy-thí-nghiệm-và-phân-tích)
10. [Lưu ý khi đo trên Raspberry Pi 4](#10-lưu-ý-khi-đo-trên-raspberry-pi-4)
11. [Hạn chế đã biết](#11-hạn-chế-đã-biết)

---

## 1. Cấu trúc repo

| Đường dẫn | Vai trò |
|---|---|
| `config.env` | Cấu hình dùng chung: địa chỉ server, cổng, SNI, thư mục cài đặt, danh sách file test, cipher của client, commit picoquic, thông tin SSH |
| `patches/picoquic-mpstat.patch` | Patch cho `picoquicdemo`: khi kết thúc kết nối, client in một dòng `MPSTAT` cho mỗi path (byte nhận, sRTT, RTT min, loss) và một dòng `MPSTAT_SUMMARY`. Đây là bằng chứng dữ liệu thực sự đi trên từng path |
| `install_picoquic.sh` | **Cài picoquic bằng một lệnh**: cài dependency, build ở commit cố định có áp patch, kiểm tra binary |
| `common/build_picoquic.sh` | Bước build mà `install_picoquic.sh` gọi: clone, checkout, áp patch, CMake |
| `server/deploy.sh` | Chạy từ máy trạm: đồng bộ repo lên server qua SSH và chạy setup |
| `server/setup_server.sh` | Chạy trên server: cài dependency, build, tạo cert, sinh file test, tuỳ chọn cài service systemd |
| `server/start_server.sh` | Khởi động, dừng hoặc xem trạng thái server khi không dùng systemd |
| `server/run_server.sh` | Lệnh chạy server ở foreground (được systemd hoặc `start_server.sh` gọi) |
| `server/gen_cert.sh`, `server/gen_testfiles.sh` | Các bước con của setup: tạo cert và sinh file test |
| `server/mpquic-server.service` | Template unit systemd |
| `client/download.sh` | Tải một file qua multipath để kiểm tra setup |
| `client/run_experiment.py` | Tải lặp N lần, kiểm tra SHA-256, ghi `runs.csv` |
| `client/shape_paths.sh` | (Linux) Giả lập băng thông, delay và loss cho chiều tải xuống của từng interface |
| `analysis/analyze.py` | Thống kê goodput, tỉ lệ thành công, tỉ lệ multipath hoạt động và số liệu theo từng path |

## 2. Yêu cầu

| | Server | Client |
|---|---|---|
| Hệ điều hành | Ubuntu 22.04/24.04, Debian, Amazon Linux | Raspberry Pi OS 64-bit (Bookworm/Trixie) hoặc Linux khác |
| Gói | `build-essential cmake git pkg-config libssl-dev` | như server, thêm `python3` |
| Mạng | UDP 4443 inbound | **Hai interface**, mỗi interface có đường ra Internet tới server |
| Khác | SSH bằng key, sudo không cần mật khẩu | Nguồn 5V/3A, tản nhiệt; tuỳ chọn `matplotlib` để vẽ biểu đồ |

## 3. Cấu hình

Mọi script đều đọc `config.env`. Hãy kiểm tra file này trước khi triển khai:

```bash
SERVER_IP="47.129.174.173"
SERVER_PORT="4443"
SERVER_SNI="mpquic.local"
SERVER_INSTALL_DIR="/data/mpquic-download-testbed/run"   # bin/, certs/, www/, logs/ trên server
TEST_FILES="file_1MB.bin:1M file_10MB.bin:10M file_50MB.bin:50M file_100MB.bin:100M"
CLIENT_CIPHER="20"                                       # ChaCha20-Poly1305
CLIENT_DL_DIR="/dev/shm/mpquic-dl"                       # tải vào RAM
PICOQUIC_COMMIT="36f49b73d532369882d97474ac018655b6739a58"
SSH_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_ed25519"
REMOTE_REPO_DIR="/data/mpquic-download-testbed"
```

Picoquic được ghim ở một commit cố định để kết quả có thể tái lập. Khi đổi commit, hãy ghi lại
lý do và kiểm tra lại xem patch còn áp được hay không.

---

## 4. Cài đặt picoquic

Client và server dùng chung một binary là `picoquicdemo`. Binary này được build từ picoquic ở commit
`PICOQUIC_COMMIT` và có áp patch `MPSTAT`. Bản picoquic cài từ nguồn khác **không có** dòng
`MPSTAT`, nên các script đo sẽ không đọc được số liệu theo từng path.

### 4.1 Cài bằng một lệnh (khuyến nghị)

```bash
git clone https://github.com/AhDuxng/mpquic-download-testbed.git
cd mpquic-download-testbed
./install_picoquic.sh
```

| Tuỳ chọn | Ý nghĩa |
|---|---|
| (không có) | Cài dependency (cần sudo) rồi build vào `./bin` |
| `--no-deps` | Bỏ qua bước cài gói, dùng khi đã có sẵn dependency hoặc không có quyền sudo |
| `--prefix DIR` | Đặt binary vào `DIR` thay cho `./bin` (`setup_server.sh` dùng tuỳ chọn này) |

Script chạy ba bước:
1. **Cài dependency.** Dùng `apt-get` trên Debian, Ubuntu và Raspberry Pi OS; `dnf` trên Amazon Linux, RHEL và Fedora; Homebrew trên macOS.
2. **Build.** Clone picoquic vào `third_party/picoquic`, checkout `PICOQUIC_COMMIT`, áp `patches/picoquic-mpstat.patch`, configure bằng CMake (picotls được tải tự động theo revision mà picoquic ghim), rồi build `picoquicdemo` và `picolog_t`.
3. **Kiểm tra.** Xác nhận binary chạy được, có tuỳ chọn multipath `-M`, và mã nguồn đã có patch `MPSTAT`.

Kết quả thành công kết thúc bằng:
```
==> [3/3] Verify
OK: /home/<user>/mpquic-download-testbed/bin/picoquicdemo
```

Thời gian build khoảng 2 phút trên server 2 vCPU và 5–10 phút trên Raspberry Pi 4. Khi cài qua
SSH, nên tách tiến trình khỏi phiên SSH để build không bị ngắt khi rớt kết nối:
```bash
setsid nohup ./install_picoquic.sh > install.log 2>&1 &
tail -f install.log
```
Nếu một lần build bị ngắt giữa chừng, lần chạy sau sẽ tự xoá thư mục build dở rồi build lại từ đầu.

### 4.2 Cài thủ công

Các lệnh dưới đây tương đương với những gì `install_picoquic.sh` thực hiện:
```bash
sudo apt-get install -y build-essential cmake git pkg-config libssl-dev openssl python3

git clone https://github.com/private-octopus/picoquic.git third_party/picoquic
git -C third_party/picoquic checkout 36f49b73d532369882d97474ac018655b6739a58
git -C third_party/picoquic apply ../../patches/picoquic-mpstat.patch

cmake -S third_party/picoquic -B third_party/picoquic/build \
      -DPICOQUIC_FETCH_PTLS=Y -DCMAKE_BUILD_TYPE=Release \
      -Dpicoquic_BUILD_TESTS=OFF -DBUILD_PICO_SIM=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build third_party/picoquic/build -j"$(nproc)" --target picoquicdemo picolog_t

mkdir -p bin && cp third_party/picoquic/build/picoquicdemo third_party/picoquic/build/picolog_t bin/
```
Trên macOS, cài dependency bằng `brew install cmake pkg-config openssl@3`, rồi thêm
`-DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"` vào lệnh `cmake`.

---

## 5. Setup server (AWS)

### 5.1 Mở cổng
EC2 → Security Groups → Inbound rules, thêm hai rule:

| Type | Port | Source |
|---|---|---|
| Custom UDP | 4443 | IP public của client (hoặc `0.0.0.0/0` khi thử nghiệm) |
| SSH | 22 | IP của máy trạm dùng để deploy |

### 5.2 Triển khai từ máy trạm

```bash
./server/deploy.sh --no-service   # đồng bộ repo vào /data/mpquic-download-testbed, setup, không dùng systemd
./server/deploy.sh                # như trên, cài thêm service systemd mpquic-server
./server/deploy.sh --copy         # chỉ đồng bộ mã nguồn
```

Nếu muốn làm trực tiếp trên server thì copy repo vào `/data/mpquic-download-testbed`, rồi chạy:

```bash
cd /data/mpquic-download-testbed
./server/setup_server.sh --no-service    # hoặc không có tham số để cài systemd
```

`setup_server.sh` thực hiện lần lượt:
1. Gọi `install_picoquic.sh --prefix SERVER_INSTALL_DIR/bin` để cài dependency và build (mục 4).
2. Tạo cấu trúc thư mục trong `SERVER_INSTALL_DIR`.
3. Tạo cert ECDSA P-256 tự ký, có SNI và IP trong SAN.
4. Sinh các file ngẫu nhiên trong `TEST_FILES`, kèm `SHA256SUMS` và `index.html`.
5. Copy `run_server.sh` và `config.env` vào `SERVER_INSTALL_DIR`.

Khi chạy không có `--no-service`, script làm thêm: nâng giới hạn buffer UDP qua `/etc/sysctl.d/90-mpquic.conf`,
cài và bật service `mpquic-server`, và mở cổng trên ufw nếu ufw đang bật.

Thư mục trên server sau khi setup:
```
/data/mpquic-download-testbed/        mã nguồn
/data/mpquic-download-testbed/run/    SERVER_INSTALL_DIR
├── bin/picoquicdemo
├── certs/{cert.pem,key.pem}
├── www/{file_*.bin,SHA256SUMS,index.html}
├── logs/        thư mục làm việc của server
├── run_server.sh, config.env
└── server.log, server.pid           (khi chạy bằng start_server.sh)
```

### 5.3 Vận hành

Khi không dùng systemd (`--no-service`):
```bash
./server/start_server.sh             # chạy nền (setsid + nohup), không tự chạy lại sau reboot
./server/start_server.sh --status
./server/start_server.sh --stop
tail -f /data/mpquic-download-testbed/run/server.log
```

Khi dùng systemd:
```bash
sudo systemctl status mpquic-server
journalctl -u mpquic-server -f
sudo systemctl restart mpquic-server
```

Server luôn chạy với cờ `-M`. Cờ này quảng bá hỗ trợ multipath (`initial_max_path_id = 2`), nên mỗi
kết nối có tối đa 3 path. Để bật qlog phía server, chạy `QLOG=1 ./server/start_server.sh` hoặc thêm
`Environment=QLOG=1` vào unit systemd. qlog của file lớn rất nặng, chỉ nên bật khi debug.

Kiểm tra server đang lắng nghe:
```bash
ss -ulpn | grep 4443      # phải thấy picoquicdemo trên 0.0.0.0:4443 và [::]:4443
```

---

## 6. Setup client (Raspberry Pi 4)

1. Dùng Raspberry Pi OS 64-bit, nguồn 5V/3A chính hãng và có tản nhiệt.
2. Cài picoquic theo mục 4:
   ```bash
   git clone https://github.com/AhDuxng/mpquic-download-testbed.git
   cd mpquic-download-testbed
   ./install_picoquic.sh
   ```
3. Kiểm tra nguồn điện. Kết quả phải là `throttled=0x0`; giá trị khác nghĩa là Pi đang hoặc đã từng thiếu điện áp hay quá nhiệt (xem mục 10):
   ```bash
   vcgencmd get_throttled
   ```
4. Cấu hình multipath theo mục 7, rồi chạy smoke test ở mục 8.

---

## 7. Setup multipath trên client

Multipath chỉ cho kết quả có ý nghĩa khi **mỗi path đi qua một interface vật lý riêng và có đường
ra Internet riêng**. Picoquic mở path 0 theo default route của kernel, sau đó mở thêm một path cho
mỗi địa chỉ khai báo trong `ALT_PATHS` (cờ `-A <ip>/<ifindex>`).

### 7.1 Chọn cặp đường

Pi 4 có sẵn `eth0` (Gigabit Ethernet) và `wlan0` (Wi-Fi 5). Có thể cắm thêm USB 4G hoặc điện thoại
chia sẻ mạng qua USB, khi đó interface mới hiện thành `usb0`, `eth1` hoặc `wwan0`.

| Cặp đường | Đặc điểm |
|---|---|
| `eth0` + `wlan0` cùng một router | Dễ dựng, nhưng hai path **chung đường ISP**. Multipath chỉ có lợi khi đoạn LAN hoặc Wi-Fi là nút cổ chai |
| `eth0` hoặc `wlan0` + 4G | **Hai đường độc lập**, phù hợp để đo khả năng cộng băng thông. RTT hai path chênh nhau nhiều, nên cũng đo được ảnh hưởng của lệch RTT |

### 7.2 Đưa cả hai interface lên và có đường ra Internet

```bash
ip -o -4 addr show      # IP và ifindex của từng interface
ip route                # mỗi interface cần một dòng "default via ..."
```

Ví dụ kết quả mong muốn (Pi thường có `lo`=1, `eth0`=2, `wlan0`=3, USB=4):
```
2: eth0    inet 192.168.2.100/24 ...
3: wlan0   inet 10.50.40.68/24 ...
default via 192.168.2.1 dev eth0  metric 100
default via 10.50.40.1  dev wlan0 metric 600
```

Nếu một interface có IP tĩnh nhưng **không có gateway** (chỉ có route `192.168.2.0/24 dev eth0`
mà không có dòng `default`), path đó sẽ không ra được Internet. Khai báo gateway bằng NetworkManager:
```bash
nmcli -t -f NAME,DEVICE con show --active
sudo nmcli con mod "Wired connection 1" ipv4.gateway 192.168.2.1 ipv4.route-metric 100
sudo nmcli con up  "Wired connection 1"
```

### 7.3 Policy routing (định tuyến theo địa chỉ nguồn)

Khi có hai default route, kernel chỉ dùng route có metric thấp nhất. Để gói mang IP nguồn của
interface thứ hai thực sự đi ra interface đó, cần thêm một bảng định tuyến riêng cho mỗi interface:

```bash
# wlan0: 10.50.40.68, gateway 10.50.40.1
sudo ip route add default via 10.50.40.1 dev wlan0 table 103
sudo ip rule  add from 10.50.40.68 table 103 priority 103

# eth0: 192.168.2.100, gateway 192.168.2.1
sudo ip route add default via 192.168.2.1 dev eth0 table 102
sudo ip rule  add from 192.168.2.100 table 102 priority 102

# rp_filter loose mode, để kernel không drop gói trả về trên interface phụ
sudo sysctl -w net.ipv4.conf.all.rp_filter=2
sudo sysctl -w net.ipv4.conf.default.rp_filter=2
```

Các lệnh trên mất sau khi reboot. Để giữ cố định, khai báo trong NetworkManager. Chỉ áp dụng cho
interface **phụ**: `ipv4.route-table` đưa toàn bộ route của kết nối đó sang bảng riêng, nên nếu áp
cho interface đang làm path 0, Pi sẽ mất default route trong bảng chính.
```bash
sudo nmcli con mod "<tên kết nối wlan0>" ipv4.route-table 103 \
     ipv4.routing-rules "priority 103 from 10.50.40.68 table 103"
echo -e "net.ipv4.conf.all.rp_filter=2\nnet.ipv4.conf.default.rp_filter=2" | \
     sudo tee /etc/sysctl.d/90-mpquic-client.conf
```

### 7.4 Kiểm tra từng đường

```bash
ip route get 47.129.174.173 from 10.50.40.68      # phải ra "dev wlan0"
ip route get 47.129.174.173 from 192.168.2.100    # phải ra "dev eth0"
ping -c 5 -I wlan0 47.129.174.173
ping -c 5 -I eth0  47.129.174.173
curl -s --interface wlan0 https://ifconfig.me; echo
curl -s --interface eth0  https://ifconfig.me; echo   # hai đường độc lập thì ra hai IP public khác nhau
```

Mỗi đường phải ping được tới server và tỉ lệ mất gói thấp. Nếu một path mất gói liên tục,
picoquic sẽ đánh dấu path đó suspended và gần như không gửi dữ liệu trên nó.

### 7.5 Khai báo path cho client

| Biến | Ý nghĩa | Ví dụ |
|---|---|---|
| `ALT_PATHS` | **Bắt buộc.** `<IP>/<ifindex>` của interface thứ hai. Nhiều path thì cách nhau bằng dấu phẩy | `10.50.40.68/3` |
| `PRIMARY_IF` | Tuỳ chọn. Ép path 0 ra một interface cụ thể (cờ `-e`) | `2` |

```bash
export PRIMARY_IF=2                    # path 0 = eth0
export ALT_PATHS="10.50.40.68/3"       # path 1 = wlan0
```

`ALT_PATHS` phải trỏ tới interface **khác** với interface của path 0. Nếu hai dòng `MPSTAT` có cùng
IP `local=`, nghĩa là `ALT_PATHS` đang trỏ nhầm vào interface mặc định.

---

## 8. Smoke test

```bash
PRIMARY_IF=2 ALT_PATHS="10.50.40.68/3" ./client/download.sh file_10MB.bin
```

Kết quả đạt yêu cầu khi có đủ bốn dấu hiệu:
1. `Negotiated ALPN: h3`
2. `Enable multipath: Success`
3. Mỗi path có một dòng `MPSTAT path=N`, các path có **IP `local=` khác nhau**, và mọi path đều có `bytes_received` > 0
4. `MPSTAT_SUMMARY multipath=1 nb_paths=2`

Định dạng đầu ra:
```
Negotiated ALPN: h3
Enable multipath: Success.
Received 10485827 bytes in <t> seconds, <rate> Mbps.
MPSTAT path=0 unique_id=0 local=192.168.2.100:<port> peer=47.129.174.173:4443 bytes_received=<n> ... srtt_us=<n> ...
MPSTAT path=1 unique_id=1 local=10.50.40.68:<port>   peer=47.129.174.173:4443 bytes_received=<n> ... srtt_us=<n> ...
MPSTAT_SUMMARY multipath=1 nb_paths=2 bytes_received=10485827 duration_us=<n>
```

So SHA-256 với bản trên server:
```bash
sha256sum /dev/shm/mpquic-dl/file_10MB.bin
```

| Triệu chứng | Nguyên nhân thường gặp |
|---|---|
| Treo rồi timeout, không thấy `Negotiated ALPN` | Security Group chưa mở UDP 4443, server chưa chạy, hoặc mạng client chặn UDP |
| `Enable multipath: Refused` | Server chạy thiếu cờ `-M` |
| Chỉ có `MPSTAT path=0` | Sai IP hoặc ifindex trong `ALT_PATHS`, interface thứ hai không có route ra Internet, hoặc thiếu policy routing/rp_filter (mục 7.3) |
| Có path 1 nhưng `bytes_received` ≈ 0 | Path 1 mất gói nặng nên bị suspended. Kiểm tra bằng `ping -I <iface> 47.129.174.173` |
| `Cannot parse the specified scenario` | Tên file truyền cho picoquic phải bắt đầu bằng `/` (các script đã tự thêm) |

---

## 9. Chạy thí nghiệm và phân tích

```bash
PRIMARY_IF=2 ALT_PATHS="10.50.40.68/3" \
python3 client/run_experiment.py -n 30 -f file_10MB.bin,file_100MB.bin --label "eth0+wlan0"

python3 analysis/analyze.py results/<stamp>/runs.csv --plot
```

| Tuỳ chọn | Mặc định | Ý nghĩa |
|---|---|---|
| `-n` | 10 | Số lần lặp cho mỗi file |
| `-f` | toàn bộ `TEST_FILES` | Danh sách file, cách nhau bằng dấu phẩy. Các file phải có trên server |
| `-t` | 300 | Timeout cho mỗi lần tải (giây) |
| `-p` | 1.0 | Thời gian nghỉ giữa hai lần tải (giây) |
| `--label` | | Ghi chú lưu vào mọi dòng CSV, nên ghi cặp interface và cấu hình shaping |
| `--seed` | ngẫu nhiên | Seed để xáo thứ tự file, được ghi vào `meta.txt` |
| `--qlog` | tắt | Ghi qlog cho mỗi lần tải, xem bằng [qvis](https://qvis.quictools.info) |

Mỗi lần chạy tạo thư mục `results/<stamp>/` gồm:
- `runs.csv`: mỗi dòng là một lần tải, gồm kết quả SHA-256 (`ok`), trạng thái multipath, goodput, CPU, nhiệt độ, và với mỗi path: IP local, số byte, tỉ lệ byte, sRTT, RTT min, số lần mất gói.
- `meta.txt`: commit picoquic, seed, `ALT_PATHS`, thông tin máy, trạng thái throttling của Pi lúc bắt đầu và kết thúc.
- `logs/`: toàn bộ đầu ra của client cho từng lần tải.

Phương pháp đo:
- Mỗi lần tải dùng một thư mục làm việc trống, nên không có session ticket: luôn full handshake, không có 0-RTT.
- Thứ tự các file được xáo trong mỗi lần lặp.
- Lần tải hỏng (SHA sai hoặc timeout) vẫn được giữ lại trong CSV với `ok=0`.

`analyze.py` báo cáo theo từng file:
- `ok/n`: số lần tải thành công trên tổng số lần.
- `mp/ok`: số lần thành công mà multipath được bật **và** ít nhất hai path có dữ liệu.
- Goodput: median, P25, P75, P95, mean, độ lệch chuẩn.
- Thời gian tải median và CPU median.
- Theo từng path: median tỉ lệ byte, sRTT, RTT min và loss.

Goodput = kích thước file / thời gian kết nối của picoquic, **tính cả handshake**.

### Giả lập điều kiện đường truyền (tuỳ chọn)
```bash
sudo client/shape_paths.sh add eth0  20mbit 10ms
sudo client/shape_paths.sh add wlan0 5mbit  60ms 0.5%
sudo client/shape_paths.sh show
sudo client/shape_paths.sh del eth0; sudo client/shape_paths.sh del wlan0
```
Script chỉ shape chiều tải xuống (ingress → ifb → netem). Nên ghi cấu hình shaping vào `--label`.

---

## 10. Lưu ý khi đo trên Raspberry Pi 4

| Yếu tố | Ảnh hưởng | Cách testbed xử lý |
|---|---|---|
| CPU không có lệnh AES | BCM2711 (Cortex-A72) không có ARMv8 Crypto Extensions. AES-GCM chạy bằng phần mềm, nên CPU dễ nghẽn trước mạng | Client ép **ChaCha20** (`CLIENT_CIPHER="20"`) và ghi `cpu_pct` cho mỗi lần tải. `analyze.py` cảnh báo khi median vượt 85 % |
| Thẻ SD ghi chậm | Thẻ SD thường chỉ ghi được 20–40 MB/s | File được tải vào RAM (`/dev/shm/mpquic-dl`), kiểm SHA-256 rồi xoá ngay |
| Thiếu điện áp, quá nhiệt | Pi hạ xung CPU (ví dụ xuống 600 MHz) | Ghi `soc_temp_c` cho mỗi lần tải. `meta.txt` ghi `throttled_start/end`, script cảnh báo khi giá trị khác `0x0` |

Khi `cpu_pct` gần 100 %, kết quả phản ánh giới hạn CPU chứ không phải giới hạn mạng. Khi đó nên
giảm tốc độ đường truyền bằng `shape_paths.sh`, hoặc ghi rõ hạn chế này trong báo cáo.

## 11. Hạn chế đã biết

- **Chỉ hỗ trợ client Linux.** Trên macOS không có `IP_PKTINFO`, nên picoquic không ép được gói ra
  đúng interface, và path phụ có thể vẫn đi qua interface mặc định.
- **Multipath chỉ cộng được băng thông khi các path có bottleneck riêng.** Nếu hai interface dùng
  chung đường ISP, hoặc băng thông của instance AWS nhỏ hơn tổng băng thông hai path, thì mức lợi
  bị giới hạn bởi nút cổ chai chung đó.
- Scheduler của picoquic phân phối gói theo congestion window của từng path. Khi RTT hai path chênh
  nhau nhiều, gói về không theo thứ tự có thể gây head-of-line blocking ở tầng stream. Các cột
  `pN_share` và `pN_srtt_ms` giúp phân tích hiện tượng này.
- Với file nhỏ, handshake chiếm phần lớn thời gian kết nối, nên ảnh hưởng của multipath thể hiện
  rõ nhất ở file lớn.
