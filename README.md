# mpquic-download-testbed

Testbed đo và so sánh hiệu năng tải file qua **Multipath QUIC** ([draft-ietf-quic-multipath](https://datatracker.ietf.org/doc/draft-ietf-quic-multipath/))
và **Multipath TCP** ([RFC 8684](https://www.rfc-editor.org/rfc/rfc8684)). MPQUIC dùng bản cài đặt
multipath có sẵn trong [picoquic](https://github.com/private-octopus/picoquic). MPTCP dùng bản cài
đặt trong kernel Linux. Client (Raspberry Pi 4) tải **cùng một bộ file từ cùng một web server**
trên AWS, đồng thời qua **hai interface mạng thật**. Mỗi lần tải được kiểm tra toàn vẹn bằng
SHA-256 và ghi lại thống kê theo từng path.

```
 Client: Raspberry Pi 4                                    Server: AWS EC2 (47.129.174.173)
 ┌───────────────────────────────┐   path 0 (eth0)        ┌───────────────────────────────────┐
 │ client/mpquic/  picoquicdemo  │ ─────────────────────► │ MPQUIC  picoquicdemo -M  UDP 4443 │
 │ client/mptcp/   curl --mptcp  │   path 1 (wlan0 / 4G)  │ MPTCP   HTTPS server     TCP 8443 │
 │ client/lib/     đo chung      │ ─────────────────────► │ cùng www/: file_1MB … file_100MB  │
 └───────────────────────────────┘                        └───────────────────────────────────┘
```

| | MPQUIC | MPTCP |
|---|---|---|
| Client | `picoquicdemo -M -A <ip>/<ifindex>` | `curl --mptcp` |
| Server | `picoquicdemo -M`, HTTP/3, UDP 4443 | `mptcp_https_server.py`, HTTP/1.1 over TLS, TCP 8443 |
| Mở path phụ | Client khai báo bằng `-A` | Kernel path manager, theo endpoint khai báo bằng `ip mptcp` |
| Bằng chứng đa đường | Dòng `MPSTAT` cho từng path (patch của repo) | Bộ đếm `MPTcpExt` trong kernel (MP_CAPABLE, MP_JOIN) |

Dự án không tự cài đặt giao thức nào. Repo cung cấp phần build có thể tái lập, phần triển khai
server, hai client đo theo cùng một phương pháp, và phần phân tích so sánh.

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

```
mpquic-download-testbed/
├── config.env                 cấu hình dùng chung
├── install_picoquic.sh        cài picoquic bằng một lệnh
├── common/build_picoquic.sh   bước build (clone, checkout, áp patch, CMake)
├── patches/picoquic-mpstat.patch
├── server/
│   ├── deploy.sh              đồng bộ repo lên server và chạy setup (chạy từ máy trạm)
│   ├── setup_server.sh        cài đặt cả hai server
│   ├── start_server.sh        start/stop/status khi không dùng systemd
│   ├── run_mpquic_server.sh   chạy server MPQUIC (foreground)
│   ├── run_mptcp_server.sh    chạy server MPTCP (foreground)
│   ├── mptcp_https_server.py  web server HTTPS trên socket MPTCP
│   ├── gen_cert.sh, gen_testfiles.sh
│   └── mpquic-server.service, mptcp-server.service
├── client/
│   ├── lib/testbed.py         phần đo dùng chung cho cả hai giao thức
│   ├── mpquic/                download.sh, run_experiment.py
│   ├── mptcp/                 setup_mptcp.sh, download.sh, run_experiment.py
│   └── shape_paths.sh         giả lập băng thông, delay, loss
└── analysis/analyze.py        thống kê và so sánh MPQUIC với MPTCP
```

| Thành phần | Vai trò |
|---|---|
| `patches/picoquic-mpstat.patch` | Khi kết thúc kết nối, client picoquic in một dòng `MPSTAT` cho mỗi path (byte nhận, sRTT, RTT min, loss) và một dòng `MPSTAT_SUMMARY` |
| `server/mptcp_https_server.py` | Web server HTTPS (TLS 1.3) mở socket `IPPROTO_MPTCP`, phục vụ cùng thư mục `www/` và cùng cert với server MPQUIC, đặt cùng thuật toán congestion control |
| `client/lib/testbed.py` | Phần đo dùng chung: cấu hình, kiểm tra SHA-256, xáo thứ tự, đo CPU, nhiệt độ, throttling, byte nhận theo interface, ghi CSV. Nhờ đó hai giao thức được đo giống hệt nhau |
| `client/mptcp/setup_mptcp.sh` | Khai báo endpoint MPTCP trong kernel từ cùng danh sách `ALT_PATHS` mà MPQUIC dùng |
| `analysis/analyze.py` | Thống kê goodput, tỉ lệ thành công, tỉ lệ multipath hoạt động, số liệu theo từng path, và so sánh hai giao thức |

## 2. Yêu cầu

| | Server | Client |
|---|---|---|
| Hệ điều hành | Linux có MPTCP (Ubuntu 22.04/24.04, Debian, Amazon Linux) | Linux có MPTCP (Raspberry Pi OS 64-bit Bookworm/Trixie) |
| Gói | `build-essential cmake git pkg-config libssl-dev`, Python ≥ 3.10 | như server, thêm `curl` ≥ 8.9 (có `--mptcp`) |
| Mạng | UDP 4443 và TCP 8443 inbound | **Hai interface**, mỗi interface có đường ra Internet tới server |
| Khác | SSH bằng key, sudo không cần mật khẩu | Nguồn 5V/3A, tản nhiệt; tuỳ chọn `matplotlib` để vẽ biểu đồ |

Kiểm tra MPTCP trên cả hai máy: `cat /proc/sys/net/mptcp/enabled` phải ra `1`, và `ip mptcp limits`
phải chạy được.

## 3. Cấu hình

Mọi script đều đọc `config.env`. Hãy kiểm tra file này trước khi triển khai:

```bash
SERVER_IP="47.129.174.173"
SERVER_PORT="4443"                                       # UDP, server MPQUIC
MPTCP_PORT="8443"                                        # TCP, server MPTCP
SERVER_SNI="mpquic.local"
SERVER_INSTALL_DIR="/data/mpquic-download-testbed/run"   # bin/, certs/, www/, logs/ trên server
TEST_FILES="file_1MB.bin:1M file_10MB.bin:10M file_50MB.bin:50M file_100MB.bin:100M"
CONGESTION_CONTROL="cubic"                               # áp cho cả hai server
CLIENT_CIPHER="20"                                       # ChaCha20-Poly1305, cho cả hai client
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

Client và server MPQUIC dùng chung một binary là `picoquicdemo`. MPTCP không cần cài gì thêm vì nằm sẵn trong kernel Linux. Binary này được build từ picoquic ở commit
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

Server chạy hai web server song song, cùng phục vụ một thư mục `www/` với cùng cert và cùng
thuật toán congestion control (`CONGESTION_CONTROL`):

| Server | Lệnh | Cổng |
|---|---|---|
| MPQUIC | `picoquicdemo -M -G cubic` (HTTP/3) | UDP 4443 |
| MPTCP | `mptcp_https_server.py --cc cubic` (HTTPS, TLS 1.3) | TCP 8443 |

Server MPTCP viết bằng Python và chỉ dùng thư viện chuẩn, không cần cài thêm gì. Socket lắng nghe
được tạo với `IPPROTO_MPTCP`. Client có MPTCP sẽ thương lượng MPTCP; client không có MPTCP vẫn tải
được qua TCP thường (fallback).

### 5.1 Mở cổng
EC2 → Security Groups → Inbound rules, thêm các rule:

| Type | Port | Source |
|---|---|---|
| Custom UDP | 4443 | IP public của client (hoặc `0.0.0.0/0` khi thử nghiệm) |
| Custom TCP | 8443 | như trên |
| SSH | 22 | IP của máy trạm dùng để deploy |

### 5.2 Triển khai

Từ máy trạm:
```bash
./server/deploy.sh --no-service   # đồng bộ repo vào /data/mpquic-download-testbed, setup, không dùng systemd
./server/deploy.sh                # như trên, cài thêm hai service systemd
./server/deploy.sh --copy         # chỉ đồng bộ mã nguồn
```

Hoặc trực tiếp trên server, sau khi copy repo vào `/data/mpquic-download-testbed`:
```bash
cd /data/mpquic-download-testbed
./server/setup_server.sh --no-service    # hoặc không có tham số để cài systemd
```

`setup_server.sh` thực hiện lần lượt:
1. Tạo cấu trúc thư mục trong `SERVER_INSTALL_DIR`.
2. Gọi `install_picoquic.sh --prefix SERVER_INSTALL_DIR/bin` để cài dependency và build (mục 4).
3. Tạo cert ECDSA P-256 tự ký, có SNI và IP trong SAN.
4. Sinh các file ngẫu nhiên trong `TEST_FILES`, kèm `SHA256SUMS` và `index.html`.
5. Copy hai script chạy server, `mptcp_https_server.py` và `config.env` vào `SERVER_INSTALL_DIR`.

Khi chạy không có `--no-service`, script làm thêm: nâng giới hạn buffer UDP qua
`/etc/sysctl.d/90-mpquic.conf`, bật `net.mptcp.enabled`, cài và bật hai service `mpquic-server` và
`mptcp-server`, và mở cả hai cổng trên ufw nếu ufw đang bật.

Thư mục trên server sau khi setup:
```
/data/mpquic-download-testbed/        mã nguồn
/data/mpquic-download-testbed/run/    SERVER_INSTALL_DIR
├── bin/picoquicdemo
├── certs/{cert.pem,key.pem}          dùng chung cho cả hai server
├── www/{file_*.bin,SHA256SUMS,index.html}
├── logs/                             thư mục làm việc của picoquic
├── run_mpquic_server.sh, run_mptcp_server.sh, mptcp_https_server.py, config.env
└── mpquic.{pid,log}, mptcp.{pid,log} (khi chạy bằng start_server.sh)
```

### 5.3 Vận hành

Khi không dùng systemd:
```bash
./server/start_server.sh                   # chạy nền cả hai server (setsid + nohup)
./server/start_server.sh --status          # trạng thái cả hai
./server/start_server.sh --stop mptcp      # dừng một server: mpquic | mptcp | all
QLOG=1 ./server/start_server.sh mpquic     # server MPQUIC có ghi qlog
tail -f /data/mpquic-download-testbed/run/mptcp.log
```
Các tiến trình chạy nền vẫn sống sau khi đóng SSH, nhưng không tự chạy lại sau khi reboot.

Khi dùng systemd:
```bash
sudo systemctl status mpquic-server mptcp-server
journalctl -u mptcp-server -f
sudo systemctl restart mpquic-server mptcp-server
```

Kiểm tra hai server đang lắng nghe:
```bash
ss -ulpn | grep 4443      # picoquicdemo trên 0.0.0.0:4443 và [::]:4443
ss -tlpn | grep 8443      # python3 trên 0.0.0.0:8443
```

Kiểm tra từ một máy bên ngoài rằng cổng TCP đã mở (một lệnh curl thường là đủ, không cần MPTCP):
```bash
curl -k --resolve mpquic.local:8443:47.129.174.173 -o /dev/null -w "%{http_code}\n" \
     https://mpquic.local:8443/SHA256SUMS          # phải ra 200; timeout nghĩa là Security Group đang chặn
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
3. Kiểm tra MPTCP và curl. MPTCP nằm sẵn trong kernel, không cần cài thêm:
   ```bash
   cat /proc/sys/net/mptcp/enabled        # 1
   curl --help all | grep -- --mptcp      # phải có dòng "--mptcp"
   ```
   Nếu curl cũ hơn 8.9, cài `mptcpd` (`sudo apt-get install mptcpd`). Client sẽ tự chuyển sang
   chạy `mptcpize run curl`.
4. Kiểm tra nguồn điện. Kết quả phải là `throttled=0x0`; giá trị khác nghĩa là Pi đang hoặc đã từng
   thiếu điện áp hay quá nhiệt (xem mục 10):
   ```bash
   vcgencmd get_throttled
   ```
5. Cấu hình multipath theo mục 7, rồi chạy smoke test ở mục 8.

---

## 7. Setup multipath trên client

Multipath chỉ cho kết quả có ý nghĩa khi **mỗi path đi qua một interface vật lý riêng và có đường
ra Internet riêng**. Các bước 7.1–7.5 dùng chung cho cả hai giao thức. Bước 7.6 chỉ dành cho MPTCP.

| | Path 0 | Path phụ |
|---|---|---|
| MPQUIC | Theo default route của kernel (hoặc `PRIMARY_IF`) | Một path cho mỗi địa chỉ trong `ALT_PATHS` (cờ `-A`) |
| MPTCP | Subflow đầu tiên theo default route | Một subflow cho mỗi endpoint khai báo bằng `setup_mptcp.sh`, dùng cùng `ALT_PATHS` |

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
interface thứ hai thực sự đi ra interface đó, cần thêm một bảng định tuyến riêng cho mỗi interface.
Bước này cần cho cả MPQUIC lẫn MPTCP:

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

Mỗi đường phải ping được tới server và tỉ lệ mất gói thấp. Nếu một path mất gói liên tục, cả
picoquic lẫn MPTCP đều gần như không gửi dữ liệu trên path đó.

### 7.5 Khai báo path cho client

| Biến | Ý nghĩa | Ví dụ |
|---|---|---|
| `ALT_PATHS` | **Bắt buộc.** `<IP>/<ifindex>` của interface thứ hai. Nhiều path thì cách nhau bằng dấu phẩy | `10.50.40.68/3` |
| `PRIMARY_IF` | Tuỳ chọn. ifindex của path 0. MPQUIC ép path 0 ra interface này (cờ `-e`); cả hai client dùng nó để biết interface nào cần đếm byte | `2` |

```bash
export PRIMARY_IF=2                    # path 0 = eth0
export ALT_PATHS="10.50.40.68/3"       # path 1 = wlan0
```

`ALT_PATHS` phải trỏ tới interface **khác** với interface của path 0.

### 7.6 Endpoint MPTCP (chỉ cho MPTCP)

Kernel chỉ mở subflow phụ khi có endpoint được khai báo. `setup_mptcp.sh` dùng đúng giá trị
`ALT_PATHS`, nên MPTCP và MPQUIC chạy trên cùng các interface:

```bash
sudo client/mptcp/setup_mptcp.sh add 10.50.40.68/3      # hoặc: sudo -E client/mptcp/setup_mptcp.sh add
sudo client/mptcp/setup_mptcp.sh show
```

Kết quả mong muốn:
```
net.mptcp.enabled = 1
add_addr_accepted 2 subflows 2
10.50.40.68 id 1 subflow dev wlan0
```

Script bật `net.mptcp.enabled`, đặt giới hạn `subflows 2`, xoá các endpoint cũ, rồi thêm một
endpoint `subflow` cho mỗi địa chỉ. Cấu hình này mất sau khi reboot. NetworkManager cũng có thể tự
quản lý endpoint MPTCP, nên hãy chạy `show` lại sau khi các interface lên. Gỡ cấu hình bằng
`sudo client/mptcp/setup_mptcp.sh del`.

---

## 8. Smoke test

### 8.1 MPQUIC

```bash
PRIMARY_IF=2 ALT_PATHS="10.50.40.68/3" ./client/mpquic/download.sh file_10MB.bin
```

Kết quả đạt yêu cầu khi có đủ bốn dấu hiệu:
1. `Negotiated ALPN: h3`
2. `Enable multipath: Success`
3. Mỗi path có một dòng `MPSTAT path=N`, các path có **IP `local=` khác nhau**, và mọi path đều có `bytes_received` > 0
4. `MPSTAT_SUMMARY multipath=1 nb_paths=2`

```
Negotiated ALPN: h3
Enable multipath: Success.
Received 10485827 bytes in <t> seconds, <rate> Mbps.
MPSTAT path=0 unique_id=0 local=192.168.2.100:<port> peer=47.129.174.173:4443 bytes_received=<n> ... srtt_us=<n> ...
MPSTAT path=1 unique_id=1 local=10.50.40.68:<port>   peer=47.129.174.173:4443 bytes_received=<n> ... srtt_us=<n> ...
MPSTAT_SUMMARY multipath=1 nb_paths=2 bytes_received=10485827 duration_us=<n>
```

### 8.2 MPTCP

```bash
./client/mptcp/download.sh file_10MB.bin
```

Kết quả đạt yêu cầu khi:
1. `http=200` và `size=` đúng bằng kích thước file
2. `MPCapableSYNACKRX=1`: server đã đồng ý MPTCP, không fallback về TCP thường
3. `MPCapableFallbackSYNACK=0`
4. `MPJoinSynAckRx=1`: subflow thứ hai qua interface kia đã được thiết lập

```
http=200 size=10485760 connect=<t>s tls=<t>s first_byte=<t>s total=<t>s speed=<n>B/s local=192.168.2.100
MPCapableSYNTX=1
MPCapableSYNACKRX=1
MPCapableFallbackSYNACK=0
MPJoinSynAckRx=1
```

Để xem các subflow trong lúc đang tải, mở một terminal khác và chạy `ss -tiM dst 47.129.174.173`.

So SHA-256 với bản trên server (áp dụng cho cả hai giao thức):
```bash
sha256sum /dev/shm/mpquic-dl/file_10MB.bin
```

### 8.3 Xử lý sự cố

| Triệu chứng | Nguyên nhân thường gặp |
|---|---|
| MPQUIC treo rồi timeout, không thấy `Negotiated ALPN` | Security Group chưa mở UDP 4443, server chưa chạy, hoặc mạng client chặn UDP |
| MPTCP báo `curl: (28) Connection timed out`, `MPCapableSYNTX=1` nhưng `MPCapableSYNACKRX=0` | Security Group chưa mở TCP 8443, hoặc server MPTCP chưa chạy |
| `Enable multipath: Refused` | Server MPQUIC chạy thiếu cờ `-M` |
| `MPCapableFallbackSYNACK=1` | Một middlebox trên đường đi (Wi-Fi công cộng, nhà mạng) đã xoá option MPTCP. Kết nối chạy như TCP thường |
| Chỉ có `MPSTAT path=0`, hoặc `MPJoinSynAckRx=0` | Sai IP hoặc ifindex trong `ALT_PATHS`, interface thứ hai không có route ra Internet, thiếu policy routing/rp_filter (mục 7.3), hoặc (MPTCP) chưa khai báo endpoint (mục 7.6) |
| `MPTCP is not configured for ALT_PATHS=...` | Chưa chạy `setup_mptcp.sh add`, hoặc endpoint khác với `ALT_PATHS` |
| Path phụ có nhưng gần như không có byte | Path đó mất gói nặng. Kiểm tra bằng `ping -I <iface> 47.129.174.173` |

---

## 9. Chạy thí nghiệm và phân tích

Hai runner có cùng tuỳ chọn và cùng định dạng kết quả. Nên chạy hai thí nghiệm **nối tiếp nhau,
trong cùng điều kiện mạng và cùng cấu hình shaping**:

```bash
export PRIMARY_IF=2 ALT_PATHS="10.50.40.68/3"
sudo -E client/mptcp/setup_mptcp.sh add

python3 client/mpquic/run_experiment.py -n 30 -f file_10MB.bin,file_100MB.bin --label "eth0+wlan0"
python3 client/mptcp/run_experiment.py  -n 30 -f file_10MB.bin,file_100MB.bin --label "eth0+wlan0"

python3 analysis/analyze.py results/mpquic/<stamp>/runs.csv results/mptcp/<stamp>/runs.csv --plot
```

| Tuỳ chọn | Mặc định | Ý nghĩa |
|---|---|---|
| `-n` | 10 | Số lần lặp cho mỗi file |
| `-f` | toàn bộ `TEST_FILES` | Danh sách file, cách nhau bằng dấu phẩy. Các file phải có trên server |
| `-t` | 300 | Timeout cho mỗi lần tải (giây) |
| `-p` | 1.0 | Thời gian nghỉ giữa hai lần tải (giây) |
| `--label` | | Ghi chú lưu vào mọi dòng CSV, nên ghi cặp interface và cấu hình shaping |
| `--seed` | ngẫu nhiên | Seed để xáo thứ tự file, được ghi vào `meta.txt` |
| `--qlog` | tắt | (chỉ MPQUIC) Ghi qlog cho mỗi lần tải, xem bằng [qvis](https://qvis.quictools.info) |

Mỗi lần chạy tạo thư mục `results/<mpquic|mptcp>/<stamp>/` gồm:
- `runs.csv`: mỗi dòng là một lần tải.
- `meta.txt`: giao thức, cổng, commit picoquic, seed, `ALT_PATHS`, các interface được đếm byte, thông tin máy, trạng thái throttling của Pi lúc bắt đầu và kết thúc.
- `logs/`: toàn bộ đầu ra của client cho từng lần tải.

### 9.1 Các cột trong `runs.csv`

| Nhóm | Cột | Ý nghĩa |
|---|---|---|
| Chung | `ok` | 1 nếu SHA-256 khớp |
| | `mp_active` | 1 nếu multipath thực sự được dùng (định nghĩa ở bảng dưới) |
| | `nb_paths` | Số path (MPQUIC) hoặc số subflow (MPTCP) |
| | `duration_s`, `goodput_mbps` | Thời gian tải và goodput, xem mục 9.2 |
| | `wall_s`, `cpu_s`, `cpu_pct`, `soc_temp_c` | Thời gian đo bằng đồng hồ của runner, CPU của client, nhiệt độ SoC |
| | `rx_<if>`, `rx_share_<if>` | Byte nhận và tỉ lệ byte trên từng interface (từ bộ đếm kernel, gồm cả lưu lượng nền) |
| MPQUIC | `mp_negotiated`, `pN_local`, `pN_bytes`, `pN_share`, `pN_srtt_ms`, `pN_rtt_min_ms`, `pN_losses` | Từ dòng `MPSTAT`, với N = 0..2 |
| MPTCP | `mptcp_capable`, `mptcp_fallback`, `subflows_joined` | Từ bộ đếm `MPTcpExt` của kernel |
| | `http_code`, `t_connect_s`, `t_tls_s`, `t_first_byte_s` | Các mốc thời gian của curl |

| | Điều kiện để `mp_active = 1` |
|---|---|
| MPQUIC | Multipath được thương lượng **và** ít nhất 2 path có byte nhận > 0 |
| MPTCP | MP_CAPABLE được chấp nhận, ít nhất 1 subflow join thành công, **và** ít nhất 2 interface nhận ≥ 1 % kích thước file |

### 9.2 Phương pháp đo và các yếu tố được giữ giống nhau

| Yếu tố | MPQUIC | MPTCP |
|---|---|---|
| File, server, đường mạng | cùng `www/`, cùng máy AWS, cùng `ALT_PATHS` | như MPQUIC |
| Bảo mật | TLS 1.3, cipher theo `CLIENT_CIPHER` | như MPQUIC |
| Congestion control (phía gửi) | `picoquicdemo -G $CONGESTION_CONTROL` | `TCP_CONGESTION = $CONGESTION_CONTROL` |
| Phiên mới mỗi lần | thư mục làm việc trống, không 0-RTT | tiến trình curl mới, không resume TLS |
| Lưu file | RAM (`/dev/shm`) | RAM (`/dev/shm`) |
| Thời gian tải (`duration_s`) | Thời gian kết nối do picoquic đo, gồm handshake | `time_total` của curl, gồm bắt tay TCP và TLS |
| Đồng hồ đối chiếu (`wall_s`) | Cùng một đồng hồ của runner | như MPQUIC |
| Kiểm tra toàn vẹn | SHA-256 | SHA-256 |

Goodput = kích thước file × 8 / `duration_s`. Thứ tự file được xáo trong mỗi lần lặp. Lần tải hỏng
(SHA sai hoặc timeout) vẫn được giữ lại trong CSV với `ok=0`.

### 9.3 Báo cáo của `analyze.py`

Script nhận một hoặc nhiều file `runs.csv`, rồi báo cáo theo từng giao thức và từng file:
- `ok/n`: số lần tải thành công trên tổng số lần.
- `mp/ok`: số lần thành công có `mp_active = 1`.
- Goodput: median, P25, P75, P95, mean, độ lệch chuẩn. Kèm thời gian tải median và CPU median.
- MPQUIC theo từng path: tỉ lệ byte, sRTT, RTT min, loss.
- MPTCP: số subflow, số lần fallback, các mốc thời gian kết nối, TLS và byte đầu tiên.
- Cả hai giao thức: tỉ lệ byte nhận theo từng interface.
- Khi có cả hai giao thức: tỉ số median goodput MPTCP / MPQUIC cho từng file. Tỉ số này chỉ mang
  tính mô tả, vì hai thí nghiệm chạy riêng nên các lần tải không ghép cặp được với nhau.

### 9.4 Giả lập điều kiện đường truyền (tuỳ chọn)
```bash
sudo client/shape_paths.sh add eth0  20mbit 10ms
sudo client/shape_paths.sh add wlan0 5mbit  60ms 0.5%
sudo client/shape_paths.sh show
sudo client/shape_paths.sh del eth0; sudo client/shape_paths.sh del wlan0
```
Script chỉ shape chiều tải xuống (ingress → ifb → netem), áp dụng như nhau cho UDP và TCP. Nên
ghi cấu hình shaping vào `--label`.

---

## 10. Lưu ý khi đo trên Raspberry Pi 4

| Yếu tố | Ảnh hưởng | Cách testbed xử lý |
|---|---|---|
| CPU không có lệnh AES | BCM2711 (Cortex-A72) không có ARMv8 Crypto Extensions. AES-GCM chạy bằng phần mềm, nên CPU dễ nghẽn trước mạng | Cả hai client dùng **ChaCha20** (`CLIENT_CIPHER="20"`) và ghi `cpu_pct` cho mỗi lần tải. `analyze.py` cảnh báo khi median vượt 85 % |
| QUIC chạy ở userspace, TCP chạy trong kernel | TCP được kernel hỗ trợ (GRO, checksum offload), còn QUIC xử lý từng gói trong userspace. Trên CPU yếu, MPQUIC có thể chậm hơn vì CPU chứ không phải vì giao thức | So sánh `cpu_pct` giữa hai giao thức. Lưu ý `cpu_pct` chỉ tính thời gian CPU của tiến trình client, không tính phần TCP mà kernel xử lý |
| Thẻ SD ghi chậm | Thẻ SD thường chỉ ghi được 20–40 MB/s | File được tải vào RAM (`/dev/shm/mpquic-dl`), kiểm SHA-256 rồi xoá ngay |
| Thiếu điện áp, quá nhiệt | Pi hạ xung CPU (ví dụ xuống 600 MHz) | Ghi `soc_temp_c` cho mỗi lần tải. `meta.txt` ghi `throttled_start/end`, script cảnh báo khi giá trị khác `0x0` |

Khi `cpu_pct` gần 100 %, kết quả phản ánh giới hạn CPU chứ không phải giới hạn mạng. Khi đó nên
giảm tốc độ đường truyền bằng `shape_paths.sh`, hoặc ghi rõ hạn chế này trong báo cáo.

## 11. Hạn chế đã biết

- **Chỉ hỗ trợ client Linux.** Trên macOS không có `IP_PKTINFO` cho picoquic và không có MPTCP trong kernel.
- **Multipath chỉ cộng được băng thông khi các path có bottleneck riêng.** Nếu hai interface dùng
  chung đường ISP, hoặc băng thông của instance AWS nhỏ hơn tổng băng thông hai path, thì mức lợi
  bị giới hạn bởi nút cổ chai chung đó. Điều này đúng cho cả hai giao thức.
- **Scheduler khác nhau.** Picoquic dùng scheduler riêng, còn MPTCP dùng scheduler mặc định của
  kernel. Chênh lệch giữa hai giao thức gồm cả chênh lệch về scheduler. Khi RTT hai path chênh nhau
  nhiều, gói về không theo thứ tự có thể gây head-of-line blocking (trong stream QUIC, và ở tầng
  kết nối của MPTCP).
- **Phiên bản HTTP khác nhau.** MPQUIC dùng HTTP/3, MPTCP dùng HTTP/1.1. Với một lần tải một file
  lớn, khác biệt này không đáng kể so với tầng transport.
- **Middlebox có thể xoá option MPTCP.** Khi đó kết nối âm thầm fallback về TCP thường. Cột
  `mptcp_fallback` và `mp_active` cho thấy điều này.
- **Bộ đếm `MPTcpExt` và `rx_<if>` tính trên toàn máy.** Không chạy lưu lượng MPTCP hay tải lớn
  khác trong lúc đo.
- Với file nhỏ, handshake chiếm phần lớn thời gian tải, nên ảnh hưởng của multipath thể hiện rõ
  nhất ở file lớn.
