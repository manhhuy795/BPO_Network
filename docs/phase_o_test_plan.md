# Kế hoạch kiểm thử tích hợp Giai đoạn O

## Mục tiêu

Kiểm chứng bằng lỗi thật toàn bộ luồng:

```text
Mininet → BPO Exporter → Prometheus → Alertmanager → n8n
→ PostgreSQL → email thử nghiệm/GLPI → Grafana
```

Không cấu hình SMTP thật, không xóa volume và không dùng `docker compose down -v`.

## Tiền điều kiện

- Tám container dịch vụ phải `healthy`.
- Windows SSH được tới Ubuntu và đọc được `/health`, `/metrics`.
- Topology chạy; FPT/Viettel UP, FPT active, CRM/CFONO UP.
- Prometheus target `bpo_exporter` UP.
- Hai workflow n8n active.
- Không có alert active hoặc incident mở.
- GLPI và dashboard Grafana 19 panel truy cập được.

Nếu tiền điều kiện không đạt, script dừng với mã `2` trước khi gây lỗi.

## Tình huống và lỗi được gây

| Mã | Lỗi thật | Bằng chứng chính |
|---|---|---|
| O-01 | Hạ interface FPT | Metric, failover Viettel, alert, `wan-fpt`, GLPI, Grafana |
| O-02 | Hạ FPT và Viettel; sau đó dừng hai tiến trình dịch vụ | `BothWANDown`, gateway nội bộ, gom triệu chứng vào `wan-total` |
| O-03 | Hạ rồi mở lại FPT | đủ chu kỳ ổn định, resolved, dùng lại phiếu cũ |
| O-04 | Dừng HTTP server CRM | `service-crm`, CFONO và WAN không ảnh hưởng |
| O-05 | Dừng HTTP server CFONO | `service-cfono`, CRM và WAN không ảnh hưởng |
| O-06 | Dừng tiến trình exporter | target DOWN, `monitoring-exporter`, không suy diễn WAN down |
| O-07 | Phát lại hai lần payload Alertmanager thật | ràng buộc `event_key`, không tăng dữ liệu/email/phiếu |
| O-08 | `tc netem delay 180ms loss 40%` trên FPT | `HighLatency` và `HighPacketLoss` cùng `wan-quality:fpt` |
| O-09 | Restart container, không xóa volume | dữ liệu, workflow, GLPI, dashboard và target còn nguyên |

Sau mỗi tình huống, script gỡ netem, mở hai WAN, mở hai dịch vụ, khởi động exporter nếu cần và chờ không còn alert/incident mở.

## Đo lường

`logs/phase_o_measurements.csv` ghi thời điểm quan sát trực tiếp từ Windows và thời điểm lưu trong PostgreSQL. Thời gian trung bình được tính từ các timestamp có thật; ô không áp dụng được để trống.

## Lệnh chạy

```powershell
powershell -ExecutionPolicy Bypass -File tests/run_full_integration.ps1
```
