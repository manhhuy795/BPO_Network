# Kết quả Giai đoạn L

Thời điểm kiểm thử: 03/08/2026. Kết quả: **ĐẠT**, mã thoát `0`.

## File đã cập nhật

- `docker/docker-compose.yml`
- `docker/alertmanager/alertmanager.yml`
- `.env.example`

## File đã tạo

- `backups/phase_l_before/` (bản sao cấu hình trước L, không chứa `.env` thật)
- `database/init/003_alert_processing.sql`
- `n8n/bootstrap.sh`
- `n8n/workflows/bpo_alert_correlation.json`
- Tám payload trong `n8n/payloads/`
- `tests/test_phase_l.ps1`
- `logs/phase_l_test.log`
- `docs/phase_l_workflow.md`
- `docs/phase_l_correlation_rules.md`
- `docs/phase_l_result.md`

Không tạo lại schema Giai đoạn K. File `003_alert_processing.sql` chỉ bổ sung hàm nghiệp vụ của Giai đoạn L.

## Trạng thái container

| Dịch vụ | Trạng thái sau kiểm thử |
|---|---|
| Prometheus | running, healthy |
| Blackbox Exporter | running, healthy |
| Alertmanager | running, healthy |
| PostgreSQL | running, healthy |
| n8n | running, healthy |
| database-init | exited (0), đúng vai trò one-shot |
| n8n-config | exited (0), đúng vai trò one-shot |

Workflow `bpoAlertFlow01` đang active. Alertmanager gửi `firing` và `resolved` tới `http://n8n:5678/webhook/bpo-alertmanager` với `send_resolved: true`.

## Kết quả 24 kiểm thử

| STT | Nội dung | Kết quả |
|---:|---|---|
| 1 | PostgreSQL healthy | ĐẠT |
| 2 | n8n healthy | ĐẠT |
| 3 | Alertmanager healthy | ĐẠT |
| 4 | Workflow active | ĐẠT |
| 5 | Webhook hợp lệ trả HTTP 200 | ĐẠT |
| 6 | Payload sai trả HTTP 400 | ĐẠT |
| 7 | Firing tạo một raw alert | ĐẠT |
| 8 | Gửi lại không tạo raw trùng | ĐẠT |
| 9 | Cảnh báo trùng không tăng alert_count | ĐẠT |
| 10 | FPT mất tạo `wan-fpt` | ĐẠT |
| 11 | CRM mất tạo `service-crm` | ĐẠT |
| 12 | CFONO mất tạo `service-cfono` | ĐẠT |
| 13 | CRM/CFONO độc lập khi WAN bình thường | ĐẠT |
| 14 | Latency/loss FPT gom vào `wan-quality:fpt` | ĐẠT |
| 15 | Chất lượng FPT/Viettel không gom chung | ĐẠT |
| 16 | Cả hai WAN tạo `wan-total` mức cao | ĐẠT |
| 17 | CRM/CFONO trong cửa sổ được gắn vào `wan-total` | ĐẠT |
| 18 | ExporterDown tạo `monitoring-exporter` | ĐẠT |
| 19 | Resolved không tạo incident mới | ĐẠT |
| 20 | Chỉ đóng incident khi không còn firing | ĐẠT |
| 21 | Dữ liệu còn sau restart PostgreSQL | ĐẠT |
| 22 | Prometheus/Alertmanager không bị ảnh hưởng | ĐẠT |
| 23 | Không có liên kết mồ côi | ĐẠT |
| 24 | Không có hai incident mở cùng key | ĐẠT |

Log gốc: `logs/phase_l_test.log`.

## Kiểm chứng sự cố thực tế

Script đã dùng SSH dừng tiến trình `metrics/bpo_exporter.py` trên Ubuntu VM, không chèn dữ liệu trực tiếp vào PostgreSQL.

Kết quả luồng:

```text
Exporter Ubuntu dừng
  -> Prometheus phát hiện BPOExporterDown
  -> Alertmanager nhận firing
  -> n8n webhook xử lý
  -> PostgreSQL lưu firing
  -> Exporter được khởi động lại
  -> Alertmanager gửi resolved
  -> PostgreSQL lưu resolved và đóng incident
```

Cặp sự kiện thực tế gần nhất có cùng fingerprint `8a5f0b4f51e7f677`: firing lúc `07:05:36 UTC`, resolved lúc `07:05:41 UTC`. Exporter đã được khôi phục sau kiểm thử.

## Truy vấn SQL xác minh

```sql
-- 20 cảnh báo gần nhất
SELECT * FROM raw_alerts ORDER BY received_at DESC LIMIT 20;

-- Sự cố đang mở
SELECT * FROM incidents WHERE status = 'open' ORDER BY last_seen DESC;

-- Sự cố đã đóng
SELECT * FROM incidents WHERE status = 'resolved' ORDER BY resolved_at DESC;

-- Các cảnh báo thuộc một sự cố; thay :incident_id bằng ID cần xem
SELECT a.*
FROM incident_alerts ia
JOIN raw_alerts a ON a.id = ia.alert_id
WHERE ia.incident_id = :incident_id
ORDER BY a.received_at;

-- Lịch sử thay đổi của một sự cố
SELECT * FROM incident_events
WHERE incident_id = :incident_id
ORDER BY created_at;

-- Event key bị trùng; kết quả mong đợi là rỗng
SELECT event_key, count(*)
FROM raw_alerts
GROUP BY event_key
HAVING count(*) > 1;

-- Incident key có nhiều hơn một sự cố mở; kết quả mong đợi là rỗng
SELECT incident_key, count(*)
FROM incidents
WHERE status = 'open'
GROUP BY incident_key
HAVING count(*) > 1;

-- Liên kết mồ côi; kết quả mong đợi là rỗng
SELECT ia.*
FROM incident_alerts ia
LEFT JOIN incidents i ON i.id = ia.incident_id
LEFT JOIN raw_alerts a ON a.id = ia.alert_id
WHERE i.id IS NULL OR a.id IS NULL;
```

## Lỗi và hạn chế

- Không có lỗi kiểm thử bắt buộc còn lại.
- Các payload trong `n8n/payloads/` là dữ liệu thử nghiệm, không phải kết quả hệ thống thật.
- Hai incident `service-crm` và `service-cfono` đang mở sau kiểm thử vì Prometheus thực tế vẫn phát hai cảnh báo dịch vụ; đây là dữ liệu thực, không phải kết quả giả.
- Giai đoạn này chưa gửi email, tạo phiếu GLPI hoặc hiển thị Grafana.

Nền tảng PostgreSQL + n8n đã sẵn sàng cho giai đoạn kết nối email, GLPI và Grafana trong phạm vi mô hình lab.
