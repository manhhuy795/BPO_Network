# BPO Network Monitoring Lab

## 1. Giới thiệu

Tên đề tài:

> **Xây dựng hệ thống giám sát, gom nhóm cảnh báo và hỗ trợ xử lý sự cố mạng cho doanh nghiệp BPO bằng n8n.**

Dự án mô phỏng hệ thống mạng tại trụ sở chính của doanh nghiệp BPO/Call Center. Hệ thống phát hiện lỗi mạng và dịch vụ, chuyển đường Internet dự phòng, gom nhiều cảnh báo liên quan thành một sự cố, lưu dữ liệu, tạo phiếu GLPI và hiển thị trên Grafana.

Các Giai đã hoàn thành trong môi trường lab. Kiểm thử tích hợp cuối đạt **9/9 tình huống, exit code 0**.

## 2. Phạm vi

Đã mô phỏng:

- Năm VLAN nội bộ cho bốn dự án và khối Office/IT.
- CRM và CFONO phía đối tác.
- Hai đường Internet FPT/Viettel.
- Failover, failback và đo thời gian chuyển đường.
- Exporter, Prometheus, Alertmanager, PostgreSQL, n8n, GLPI và Grafana.

Không thuộc phạm vi:

- Chi nhánh, MPLS, thiết bị mạng vật lý hoặc Internet thật.
- Điện thoại IP vật lý, PBX và CRM nội bộ thật.
- SMTP thật, hệ thống HA và môi trường production.

## 3. Luồng hoạt động

```text
Mininet / Open vSwitch
        ↓
BPO Exporter trên Ubuntu VM
        ↓
Prometheus → Alertmanager
        ↓
n8n chuẩn hóa, chống trùng và gom nhóm
        ↓
PostgreSQL
        ↓
Email thử nghiệm / GLPI
        ↓
Grafana
```

Khi một thành phần lỗi:

1. Mininet và `wan_monitor.py` cập nhật trạng thái thực.
2. `bpo_exporter.py` xuất trạng thái qua `/metrics`.
3. Prometheus thu thập metric và đánh giá luật cảnh báo.
4. Alertmanager gửi `firing` hoặc `resolved` tới n8n.
5. n8n chuẩn hóa payload và gọi hàm xử lý trong PostgreSQL.
6. PostgreSQL chống trùng bằng `event_key`, sau đó tạo hoặc cập nhật incident.
7. Workflow thông báo ghi email thử nghiệm và tạo/cập nhật phiếu GLPI.
8. Grafana đọc metric từ Prometheus và incident từ PostgreSQL.

## 4. Mục đích của từng thành phần

| Thành phần | Nơi chạy | Mục đích |
|---|---|---|
| Mininet | Ubuntu VM | Tạo host, router, switch và liên kết mạng mô phỏng. |
| Open vSwitch | Ubuntu VM | Chuyển mạch VLAN trong topology. |
| `topology_v2_dual_wan.py` | Ubuntu VM | Tạo mạng VLAN, FPT/Viettel, CRM/CFONO và Mininet CLI. |
| `wan_monitor.py` | Namespace router `r1` | Ping hai WAN, đo latency/loss, failover và failback. |
| `bpo_exporter.py` | Ubuntu VM | Chuyển trạng thái runtime thành metric Prometheus, đồng thời phát hiện file WAN lỗi hoặc stale trên cổng 9105. |
| Prometheus | Windows Docker | Thu thập metric, lưu chuỗi thời gian và đánh giá luật cảnh báo. |
| Blackbox Exporter | Windows Docker | Kiểm tra HTTP endpoint mà Windows thực sự truy cập được. |
| Alertmanager | Windows Docker | Gom nhóm thông báo và gửi webhook `firing/resolved` tới n8n. |
| PostgreSQL | Windows Docker | Lưu raw alert, incident, lịch sử và trạng thái tích hợp. |
| n8n | Windows Docker | Chuẩn hóa, chống trùng, tương quan cảnh báo và điều phối GLPI/email. |
| GLPI | Windows Docker | Lưu phiếu xử lý sự cố và lịch sử cập nhật/phục hồi. |
| MySQL | Windows Docker | Database riêng của GLPI. |
| Grafana | Windows Docker | Hiển thị trạng thái WAN, dịch vụ, chất lượng mạng và incident. |

## 5. Mục đích sử dụng các công nghệ và thành phần trong đề tài

Các công nghệ trong đề tài được lựa chọn để xây dựng một môi trường thử nghiệm hoàn chỉnh, từ mô phỏng mạng, thu thập dữ liệu, phát hiện cảnh báo, gom nhóm sự cố đến hỗ trợ theo dõi và xử lý sự cố.

| Công nghệ hoặc thành phần | Mục đích sử dụng trong đề tài |
|---|---|
| **VMware Workstation** | Tạo máy ảo Ubuntu riêng để triển khai môi trường mạng mô phỏng, tách biệt với các dịch vụ giám sát chạy trên Windows. |
| **Ubuntu VM** | Làm môi trường chạy Mininet, Open vSwitch, các dịch vụ CRM/CFONO mô phỏng, Dual-WAN, BPO Exporter và các script gây lỗi, phục hồi, kiểm thử. |
| **Mininet** | Mô phỏng hệ thống mạng nội bộ của doanh nghiệp BPO gồm router, switch, máy người dùng, VLAN, mạng ngoài và các đường truyền Internet mà không cần sử dụng thiết bị mạng vật lý. |
| **Open vSwitch** | Mô phỏng các switch trong hệ thống, hỗ trợ cấu hình VLAN, cổng access, đường trunk và liên kết giữa các lớp Core, Distribution và Access. |
| **iptables** | Thiết lập chính sách truy cập giữa các VLAN, cô lập các nhóm dự án và chỉ cho phép máy IT quản trị các máy thuộc dự án. |
| **Python HTTP Server** | Tạo các dịch vụ CRM và CFONO đơn giản để mô phỏng dịch vụ của đối tác bên ngoài doanh nghiệp. |
| **Script Dual-WAN** | Mô phỏng đường Internet chính FPT và đường dự phòng Viettel, đồng thời thực hiện chuyển đường tự động khi FPT gặp lỗi và chuyển về FPT khi đường truyền phục hồi ổn định. |
| **tc netem** | Tạo độ trễ và mất gói có kiểm soát để kiểm thử các tình huống suy giảm chất lượng đường truyền. |
| **BPO Exporter** | Thu thập trạng thái thực tế của mạng mô phỏng và cung cấp dữ liệu qua các endpoint `/health` và `/metrics` để Prometheus có thể giám sát. |
| **Prometheus** | Thu thập và lưu trữ dữ liệu giám sát như trạng thái FPT/Viettel, đường truyền đang sử dụng, độ trễ, mất gói, thời gian failover/failback và trạng thái CRM/CFONO. |
| **Blackbox Exporter** | Kiểm tra khả năng truy cập HTTP đến các endpoint từ góc nhìn của hệ thống giám sát trên Windows. |
| **Alertmanager** | Nhận cảnh báo từ Prometheus, quản lý trạng thái `firing` và `resolved`, sau đó gửi webhook cảnh báo đến n8n để xử lý tiếp. |
| **PostgreSQL** | Lưu cảnh báo gốc, sự cố đã được gom nhóm, quan hệ giữa cảnh báo và sự cố, lịch sử thay đổi, trạng thái email và mã phiếu GLPI. |
| **n8n** | Tự động hóa quá trình nhận cảnh báo, chuẩn hóa dữ liệu, chống trùng, gom nhiều cảnh báo liên quan thành một sự cố và hỗ trợ xác định nguyên nhân nghi ngờ. |
| **GLPI** | Quản lý phiếu sự cố, theo dõi quá trình tạo, cập nhật và đóng phiếu tương ứng với vòng đời của incident trong hệ thống. |
| **Email thử nghiệm** | Tạo nội dung thông báo sự cố để kiểm chứng chức năng cảnh báo người quản trị. Trong phạm vi hiện tại, nội dung email được lưu vào hệ thống thay vì gửi qua SMTP thật. |
| **Grafana** | Xây dựng dashboard tập trung để hiển thị trạng thái WAN, dịch vụ, exporter, độ trễ, mất gói, failover/failback, sự cố và phiếu GLPI. |
| **Docker Desktop** | Triển khai và quản lý Prometheus, Blackbox Exporter, Alertmanager, PostgreSQL, n8n, GLPI và Grafana dưới dạng container trên Windows. |
| **PowerShell và Shell Script** | Tự động hóa việc khởi động, dừng, gây lỗi, phục hồi, kiểm thử và ghi log cho từng thành phần của hệ thống. |

## 6. Cấu trúc thư mục

```text
BPO_Network/
├── topology/           # Topology Mininet VLAN và Dual-WAN
├── scripts/            # Điều khiển WAN, CRM/CFONO và WAN monitor
├── metrics/            # BPO Exporter
├── docker/             # Docker Compose và cấu hình các container
├── database/           # Schema, hàm xử lý và migration PostgreSQL
├── n8n/                # Bootstrap, payload mẫu và workflow n8n
├── tests/              # Kiểm thử từng giai đoạn và toàn hệ thống
├── logs/               # Log và CSV số liệu thực tế
├── docs/               # Thiết kế, kết quả và giới hạn
├── runtime/            # Trạng thái WAN hiện tại
├── backups/            # Bản sao cấu hình trước các thay đổi quan trọng
└── video_work_flow/    # Tài nguyên video trình diễn, không cần để chạy hệ thống
```

## 7. Tài khoản và mật khẩu

### Nguyên tắc bảo mật

Mật khẩu thật nằm trong file `.env` cục bộ và `.env` đã được loại khỏi Git. README không chứa mật khẩu thật để tránh lộ khi nộp hoặc chia sẻ dự án.

Không gửi file `.env`, không chụp ảnh màn hình có mật khẩu và không sao chép giá trị mật khẩu vào báo cáo công khai.

### Tài khoản đăng nhập

| Hệ thống | Tài khoản | Mật khẩu |
|---|---|---|
| n8n | Giá trị `N8N_OWNER_EMAIL`, mẫu: `admin@bpo.local` | Giá trị `N8N_OWNER_PASSWORD` trong `.env` |
| Grafana | `GRAFANA_ADMIN_USER`, mặc định `admin` | `GRAFANA_ADMIN_PASSWORD`; nếu biến này không có thì dùng `N8N_OWNER_PASSWORD` |
| GLPI Web/API | `GLPI_API_USER`, mẫu: `glpi` | `GLPI_API_PASSWORD` trong `.env` |
| PostgreSQL | `POSTGRES_USER`, mẫu: `bpo_app` | `POSTGRES_PASSWORD` trong `.env`; chỉ dùng nội bộ Docker |
| MySQL của GLPI | `GLPI_DB_USER`, mẫu: `glpi` | `GLPI_DB_PASSWORD` trong `.env`; chỉ dùng nội bộ Docker |
| Ubuntu SSH | `UBUNTU_SSH_USER`, hiện là `huy` | Dự án dùng khóa tại `UBUNTU_SSH_KEY`, không lưu mật khẩu SSH |
| Prometheus | Không có đăng nhập trong lab | Không có |
| Alertmanager | Không có đăng nhập trong lab | Không có |
| Blackbox Exporter | Không có đăng nhập trong lab | Không có |

Xem tài khoản và mật khẩu hiện tại trên chính máy Windows:

```powershell
cd D:\HK5\Project\BPO_Network
Get-Content .env | Select-String '^(N8N_OWNER_EMAIL|N8N_OWNER_PASSWORD|GRAFANA_ADMIN_USER|GRAFANA_ADMIN_PASSWORD|GLPI_API_USER|GLPI_API_PASSWORD)='
```

Lệnh trên hiển thị bí mật ra terminal. Chỉ chạy trên máy cá nhân và xóa màn hình terminal trước khi quay video hoặc chụp ảnh.

Lưu ý:

- n8n và Grafana giữ dữ liệu trong volume. Đổi `.env` sau lần khởi tạo đầu tiên không chắc tự đổi mật khẩu của tài khoản đang tồn tại.
- Tài khoản `GLPI_API_USER` phải là tài khoản GLPI có thật và được phép đăng nhập API.
- Không dùng `docker compose down -v` để thử đặt lại mật khẩu vì lệnh đó xóa dữ liệu volume.

## 8. Yêu cầu trước khi chạy

### Ubuntu VM

- Ubuntu có Mininet, Open vSwitch, Python 3, `iproute2`, `iptables`, `curl` và SSH Server.
- IP hiện tại: `192.168.192.133`.
- Dự án tồn tại tại `/home/huy/BPO_Network`.
- Người dùng có thể chạy `sudo` không tương tác cho bài test tự động.

Kiểm tra nhanh:

```bash
python3 --version
mn --version
ovs-vsctl --version
ip -4 addr
```

### Windows

- Docker Desktop đang chạy Linux containers.
- PowerShell và OpenSSH Client hoạt động.
- Dự án nằm tại `D:\HK5\Project\BPO_Network`.
- Windows truy cập được Ubuntu VM qua SSH và cổng 9105.

## 9. Chuẩn bị file `.env`

Mở PowerShell tại thư mục dự án:

```powershell
cd D:\HK5\Project\BPO_Network
```

Chỉ tạo `.env` từ file mẫu nếu `.env` chưa tồn tại:

```powershell
if (-not (Test-Path .env)) {
    Copy-Item .env.example .env
}
notepad .env
```

Thay toàn bộ giá trị `thay_bang_...` bằng mật khẩu riêng. Tối thiểu phải kiểm tra:

```dotenv
UBUNTU_VM_IP=192.168.192.133
UBUNTU_SSH_USER=huy
UBUNTU_SSH_KEY=C:/Users/huy/.ssh/manhhuy

POSTGRES_PASSWORD=...
N8N_ENCRYPTION_KEY=...
N8N_OWNER_PASSWORD=...
GLPI_DB_PASSWORD=...
GLPI_DB_ROOT_PASSWORD=...
GLPI_API_PASSWORD=...
GRAFANA_ADMIN_PASSWORD=...
```

Giữ `EMAIL_MODE=log` trong môi trường lab. Không cần điền tài khoản SMTP thật để chạy dự án hiện tại.

## 10. Chạy hệ thống từng bước

### Bước 1 – Bật Ubuntu VM và kiểm tra kết nối

Từ Windows:

```powershell
Test-NetConnection 192.168.192.133 -Port 22
ssh -i C:\Users\huy\.ssh\manhhuy huy@192.168.192.133
```

Kết quả mong đợi: `TcpTestSucceeded : True` và SSH đăng nhập thành công.

### Bước 2 – Khởi động BPO Exporter trên Ubuntu

Mở terminal Ubuntu thứ nhất:

```bash
cd /home/huy/BPO_Network
pgrep -af '^python3 metrics/bpo_exporter.py$'
```

Nếu chưa có tiến trình, khởi động exporter:

```bash
nohup python3 metrics/bpo_exporter.py \
  >/tmp/bpo_exporter.log 2>&1 </dev/null &
```

Kiểm tra ngay trên Ubuntu:

```bash
curl http://127.0.0.1:9105/health
curl http://127.0.0.1:9105/metrics
```

Mục đích: exporter đọc `runtime/wan_status.json` và PID CRM/CFONO, kiểm tra độ mới của trạng thái WAN, sau đó cung cấp metric cho Prometheus trên Windows.

### Bước 3 – Khởi động topology Dual-WAN trên Ubuntu

Mở terminal Ubuntu thứ hai:

```bash
cd /home/huy/BPO_Network
sudo mn -c
sudo python3 topology/topology_v2_dual_wan.py
```

Giữ terminal này mở. Khi thấy dấu nhắc `mininet>`, topology đã chạy và tự khởi động:

- Các host VLAN.
- Router `r1`.
- Hai ISP FPT/Viettel.
- CRM và CFONO.
- `wan_monitor.py` trong namespace `r1`.

Kiểm tra từ Mininet CLI:

```text
pc_du_an_1 ping -c 2 10.10.20.1
pc_du_an_1 curl -fsS http://172.16.100.10
pc_du_an_1 curl -fsS http://172.16.100.20
```

Mục đích: tạo nguồn dữ liệu và lỗi mạng thật cho toàn bộ chuỗi giám sát.

### Bước 4 – Kiểm tra exporter từ Windows

```powershell
Invoke-WebRequest -UseBasicParsing http://192.168.192.133:9105/health
Invoke-WebRequest -UseBasicParsing http://192.168.192.133:9105/metrics
```

Không khởi động Docker nếu Windows chưa nhận HTTP 200 từ hai endpoint này.

### Bước 5 – Khởi động các container trên Windows

```powershell
cd D:\HK5\Project\BPO_Network
docker compose --env-file .env -f docker/docker-compose.yml up -d
```

Theo dõi trạng thái:

```powershell
docker compose --env-file .env -f docker/docker-compose.yml ps -a
```

Các container dịch vụ phải `healthy`:

- `bpo-prometheus`
- `bpo-blackbox`
- `bpo-alertmanager`
- `bpo-postgres`
- `bpo-n8n`
- `bpo-glpi-db`
- `bpo-glpi`
- `bpo-grafana`

Các container khởi tạo như `bpo-database-init`, `bpo-n8n-config`, `bpo-glpi-init` và `bpo-glpi-api-init` ở trạng thái `Exited (0)` là bình thường.

### Bước 6 – Mở giao diện

| Hệ thống | URL | Dùng để làm gì |
|---|---|---|
| Prometheus | http://localhost:9090 | Xem target, metric, luật và trạng thái alert. |
| Alertmanager | http://localhost:9093 | Xem cảnh báo đang firing và nhóm cảnh báo. |
| Blackbox Exporter | http://localhost:9115 | Xem trạng thái exporter HTTP probe. |
| n8n | http://localhost:5678 | Xem workflow và lịch sử execution. |
| GLPI | http://localhost:8080 | Xem phiếu sự cố và ghi chú xử lý. |
| Grafana | http://localhost:3000 | Xem dashboard mạng và incident. |

Dashboard Grafana có UID `bpo-network-overview`:

```text
http://localhost:3000/d/bpo-network-overview
```

## 11. Quan sát hệ thống đang làm gì

### Prometheus

Mở http://localhost:9090/query và chạy lần lượt:

```promql
bpo_exporter_up
bpo_wan_status_read_success
bpo_wan_status_age_seconds
bpo_wan_status_last_update_timestamp_seconds
bpo_wan_monitor_up
bpo_link_up
bpo_active_link
bpo_service_up
bpo_latency_ms
bpo_packet_loss_percent
ALERTS
```

Các metric kiểm tra độ tin cậy của dữ liệu WAN:

| Metric | Ý nghĩa |
|---|---|
| `bpo_exporter_up` | HTTP exporter còn hoạt động; không khẳng định dữ liệu WAN còn mới. |
| `bpo_wan_status_read_success` | Bằng `1` khi đọc và parse được `wan_status.json`; bằng `0` khi file mất, không đọc được hoặc JSON lỗi. |
| `bpo_wan_status_age_seconds` | Số giây từ `checked_at` gần nhất; không xuất khi timestamp thiếu hoặc không hợp lệ. |
| `bpo_wan_status_last_update_timestamp_seconds` | Giá trị `checked_at` được đổi sang Unix timestamp; không xuất khi timestamp thiếu hoặc không hợp lệ. |
| `bpo_wan_monitor_up` | Bằng `1` khi file đọc được, timestamp không ở tương lai và tuổi dữ liệu không quá 10 giây. |

`wan_monitor.py` chạy mỗi 2 giây. Ngưỡng stale là 10 giây, tương đương bỏ lỡ 5 chu kỳ liên tiếp. `WANMonitorDown` dùng cho lỗi đọc/JSON; `WANStatusStale` dùng cho JSON đọc được nhưng timestamp thiếu, ở tương lai hoặc quá cũ. Hai alert được thiết kế không firing trùng nhau.

Mở http://localhost:9090/targets để kiểm tra target `bpo_exporter` có trạng thái `UP`.

### Alertmanager

Mở http://localhost:9093 để xem cảnh báo đang hoạt động. Khi khôi phục thành phần, cảnh báo biến mất sau khi Prometheus và Alertmanager xử lý bản tin `resolved`.

### n8n

Đăng nhập http://localhost:5678, sau đó xem:

- Workflow **BPO - Chuẩn hóa và gom nhóm cảnh báo**.
- Workflow **BPO - Thông báo email và phiếu GLPI**.
- Mục **Executions** để xem payload, trạng thái xử lý và lỗi từng node.

Webhook production:

```text
http://n8n:5678/webhook/bpo-alertmanager
```

### PostgreSQL

Mở `psql` trong container, không cần mở cổng database ra Windows:

```powershell
docker exec -it bpo-postgres sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

Một số truy vấn hữu ích:

```sql
SELECT id, alert_name, status, received_at
FROM raw_alerts
ORDER BY id DESC
LIMIT 20;

SELECT incident_key, severity, status, alert_count, updated_at
FROM incidents
ORDER BY updated_at DESC;

SELECT i.incident_key, x.glpi_ticket_id, x.glpi_status
FROM incidents i
LEFT JOIN incident_integrations x ON x.incident_id = i.id
ORDER BY i.updated_at DESC;
```

Thoát `psql` bằng `\q`.

### GLPI

Đăng nhập http://localhost:8080 bằng `GLPI_API_USER` và `GLPI_API_PASSWORD`. Phiếu chứa tiêu đề, mức độ, nguyên nhân nghi ngờ và ghi chú khi sự cố cập nhật hoặc phục hồi.

### Grafana

Đăng nhập http://localhost:3000 bằng tài khoản Grafana. Dashboard 19 panel hiển thị:

- Trạng thái FPT/Viettel và đường active.
- CRM, CFONO và exporter.
- Latency, packet loss và thời gian chuyển đường.
- Incident mở, mức độ, nguyên nhân và mã phiếu GLPI.

## 12. Gây lỗi thủ công để trình diễn

Các lệnh sau phải chạy tại dấu nhắc `mininet>`, không chạy ở Bash thông thường.

### Ngắt và khôi phục FPT

```text
r1 bash scripts/fpt_down.sh
r1 bash scripts/fpt_up.sh
```

Mục đích: chứng minh tự động failover sang Viettel và failback về FPT.

### Ngắt và khôi phục Viettel

```text
r1 bash scripts/viettel_down.sh
r1 bash scripts/viettel_up.sh
```

### Dừng và mở CRM

```text
srv_crm bash scripts/stop_crm.sh
srv_crm bash scripts/start_crm.sh
```

### Dừng và mở CFONO

```text
srv_cfono bash scripts/stop_cfono.sh
srv_cfono bash scripts/start_cfono.sh
```

### Mô phỏng chất lượng FPT suy giảm

```text
r1 tc qdisc replace dev r1-eth1 root netem delay 180ms loss 40%
```

Khôi phục:

```text
r1 tc qdisc del dev r1-eth1 root
```

Mục đích: kích hoạt `HighLatency` và `HighPacketLoss` cho cùng provider FPT mà không mô phỏng mất toàn bộ Internet.

### Dừng exporter

Chạy trên terminal Ubuntu thông thường:

```bash
pkill -f '^python3 metrics/bpo_exporter.py$'
```

Khởi động lại:

```bash
cd /home/huy/BPO_Network
nohup python3 metrics/bpo_exporter.py \
  >/tmp/bpo_exporter.log 2>&1 </dev/null &
```

Mục đích: kiểm tra `BPOExporterDown` nhưng không kết luận sai rằng doanh nghiệp mất Internet.

## 13. Chạy kiểm thử

Không chạy hai topology Mininet cùng lúc. Nếu đang mở topology thủ công, gõ `exit` trước khi chạy các test D–H.

### Trên Ubuntu – Giai đoạn D đến H

```bash
cd /home/huy/BPO_Network
sudo bash tests/test_phase_d.sh
sudo bash tests/test_phase_e.sh
sudo bash tests/test_phase_f.sh
sudo bash tests/test_phase_g.sh
sudo bash tests/test_phase_h.sh
```

Mỗi script ghi log tiếng Việt vào `logs/` và trả mã khác 0 nếu có lỗi.

### Trên Windows – Giai đoạn I đến O

```powershell
cd D:\HK5\Project\BPO_Network

powershell -ExecutionPolicy Bypass -File tests/test_phase_i.ps1
powershell -ExecutionPolicy Bypass -File tests/test_phase_j.ps1
powershell -ExecutionPolicy Bypass -File tests/test_phase_k.ps1
powershell -ExecutionPolicy Bypass -File tests/test_phase_l.ps1
powershell -ExecutionPolicy Bypass -File tests/test_phase_m.ps1
powershell -ExecutionPolicy Bypass -File tests/test_phase_n.ps1
powershell -ExecutionPolicy Bypass -File tests/test_wan_status_stale.ps1
powershell -ExecutionPolicy Bypass -File tests/run_full_integration.ps1
```

Chỉ cần kiểm thử toàn hệ thống cuối cùng:

```powershell
powershell -ExecutionPolicy Bypass -File tests/run_full_integration.ps1
Write-Host "Exit code: $LASTEXITCODE"
```

Kết quả mong đợi:

```text
[ĐẠT] Giai đoạn O: 9/9 tình huống đạt, mã thoát 0.
Exit code: 0
```

Kết quả và số liệu:

- `logs/phase_o_test.log`
- `logs/phase_o_measurements.csv`
- `docs/phase_o_result.md`

## 14. Dừng và khởi động lại

### Dừng topology thủ công

Tại `mininet>`:

```text
exit
```

Sau đó trên Ubuntu:

```bash
sudo mn -c
```

### Dừng topology nền do bài test O tạo

```bash
printf 'exit\n' >> /tmp/bpo_phase_o_commands
sleep 3
sudo mn -c
```

### Dừng exporter

```bash
pkill -f '^python3 metrics/bpo_exporter.py$'
```

### Dừng các container nhưng giữ dữ liệu

```powershell
docker compose --env-file .env -f docker/docker-compose.yml stop
```

Khởi động lại:

```powershell
docker compose --env-file .env -f docker/docker-compose.yml up -d
```

Restart container vẫn giữ volume:

```powershell
docker compose --env-file .env -f docker/docker-compose.yml restart
```

Không dùng lệnh sau trong dự án đang có dữ liệu:

```text
docker compose down -v
```

## 15. Dữ liệu được lưu ở đâu

Các Docker volume:

- `prometheus_data`: chuỗi thời gian Prometheus.
- `alertmanager_data`: trạng thái Alertmanager.
- `postgres_data`: cảnh báo, incident và cấu hình n8n.
- `n8n_data`: dữ liệu cục bộ n8n.
- `glpi_db_data`: database MySQL của GLPI.
- `glpi_data`: file ứng dụng GLPI.
- `grafana_data`: cấu hình runtime Grafana.

Liệt kê volume:

```powershell
docker volume ls | Select-String 'bpo-network-monitoring'
```

## 16. Lỗi thường gặp

### `Error creating interface pair` hoặc `RTNETLINK answers: File exists`

Nguyên nhân: topology Mininet cũ chưa được dọn hoặc đang có hai topology chạy cùng lúc.

```bash
sudo mn -c
pgrep -af topology_v2_dual_wan.py
```

Chỉ khởi động topology mới khi tiến trình cũ đã dừng.

### `srv_crm: command not found`

`srv_crm` và `srv_cfono` là tên node Mininet, không phải lệnh Bash. Chạy lệnh tại `mininet>`:

```text
srv_crm bash scripts/start_crm.sh
srv_cfono bash scripts/start_cfono.sh
```

### Windows không mở được cổng 9105

Kiểm tra:

```powershell
Test-NetConnection 192.168.192.133 -Port 9105
```

Trên Ubuntu:

```bash
pgrep -af '^python3 metrics/bpo_exporter.py$'
ss -lntp | grep 9105
```

### Prometheus target `bpo_exporter` DOWN

1. Kiểm tra exporter trên Ubuntu.
2. Kiểm tra `UBUNTU_VM_IP` trong `.env`.
3. Kiểm tra Windows truy cập được `/metrics`.
4. Nếu vừa đổi IP, cập nhật container:

```powershell
docker compose --env-file .env -f docker/docker-compose.yml up -d --force-recreate prometheus blackbox
```

### `WANMonitorDown` hoặc `WANStatusStale`

- `WANMonitorDown`: kiểm tra file `runtime/wan_status.json`, quyền đọc và cú pháp JSON.
- `WANStatusStale`: kiểm tra tiến trình `wan_monitor.py`, trường `checked_at` và đồng hồ Ubuntu.

```bash
pgrep -af '[w]an_monitor.py'
cat runtime/wan_status.json
curl -s http://127.0.0.1:9105/metrics | grep '^bpo_wan_'
```

### CRM/CFONO hiển thị DOWN

Hai dịch vụ nằm trong namespace Mininet. Hãy khởi động topology trước khi đánh giá metric dịch vụ.

### n8n báo webhook `bpo-alertmanager` chưa đăng ký

Kiểm tra workflow đang active. Nếu database active nhưng webhook vẫn trả 404:

```powershell
docker compose --env-file .env -f docker/docker-compose.yml up -d --no-deps --force-recreate n8n-config
docker compose --env-file .env -f docker/docker-compose.yml restart n8n
```

Bootstrap hiện không import lại hai workflow nếu chúng đã active, tránh làm registry webhook runtime bị cũ.

### Không đăng nhập được Grafana

- Tài khoản mặc định: `admin` hoặc giá trị `GRAFANA_ADMIN_USER`.
- Xem mật khẩu trong `GRAFANA_ADMIN_PASSWORD`.
- Nếu biến này không tồn tại, thử giá trị `N8N_OWNER_PASSWORD`.
- Nếu volume Grafana đã được khởi tạo, việc đổi `.env` không tự đổi mật khẩu hiện có.

### Container khởi tạo ở trạng thái `Exited (0)`

Đây là trạng thái bình thường. Các container `database-init`, `n8n-config`, `glpi-init` và `glpi-api-init` chỉ chạy một lần rồi kết thúc.

## 17. Kết quả hiện tại

Kiểm thử tích hợp cuối:

- O-01 đến O-09: **9/9 ĐẠT**.
- Tỷ lệ: **100%**.
- Exit code: **0**.
- Phát hiện trung bình: **7,712 giây**.
- Tạo/cập nhật incident trung bình: **18,502 giây**.
- Failover: **4,002 giây**.
- Failback: **8,775 giây**.
- Incident đang mở sau kiểm thử: **0**.

Xem báo cáo đầy đủ tại [docs/phase_o_result.md](docs/phase_o_result.md) và các hạn chế tại [docs/phase_o_limitations.md](docs/phase_o_limitations.md).

## 18. Hạn chế quan trọng

- Email chỉ được ghi log, chưa gửi SMTP thật.
- CRM/CFONO là HTTP server Python mô phỏng.
- Metric dịch vụ chủ yếu phản ánh tiến trình, chưa phải probe end-to-end từ mọi VLAN.
- Dual-WAN là mô phỏng Mininet, không phải hai ISP vật lý.
- Tương quan n8n dùng quy tắc tĩnh và cửa sổ 120 giây.
- Hệ thống chưa có HA, backup tự động, TLS, SSO hoặc kiểm thử tải lớn.
- Prometheus, Alertmanager và Blackbox Exporter chưa có xác thực trong lab.
- Grafana được kiểm chứng tự động bằng API/datasource, chưa chụp ảnh trình duyệt.

Hệ thống phù hợp để trình diễn và bảo vệ đề tài trong môi trường lab; chưa nên dùng trực tiếp cho production nếu chưa xử lý các hạn chế trên.
