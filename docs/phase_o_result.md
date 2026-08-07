# Kết quả kiểm thử tích hợp Giai đoạn O

Lần chạy đầy đủ gần nhất: 03/08/2026. Kết quả: **ĐẠT 9/9 (100%)**; `tests/test_phase_o.ps1` và wrapper `tests/run_full_integration.ps1` đều trả mã thoát `0`.

## Trạng thái ban đầu

- Tám container dịch vụ `healthy`.
- Windows SSH được tới Ubuntu `192.168.192.133`.
- Topology Mininet chạy nền; FPT/Viettel UP, FPT active.
- CRM và CFONO UP, truy cập được từ máy dự án.
- Exporter `/health`, `/metrics` HTTP 200; target Prometheus `bpo_exporter` UP.
- Hai workflow n8n active và webhook runtime đã đăng ký.
- PostgreSQL, GLPI và dashboard Grafana 19 panel hoạt động.
- Không có alert active hoặc incident mở trước khi gây lỗi.

Một cảnh báo thử nghiệm cũ của Giai đoạn M còn thiếu bản tin resolved đã được đóng bằng đúng fingerprint/startsAt; không xóa hàng dữ liệu hoặc volume.

## Kết quả từng tình huống

| Mã | Kết quả | Raw alert | Incident | Phiếu | Bằng chứng chính |
|---|---|---:|---:|---:|---|
| O-01 | ĐẠT | 2 | 1 | 1 | Failover 4,002 giây; Viettel active; CRM/CFONO còn truy cập được; `wan-fpt` |
| O-02 | ĐẠT | 6 | 1 | 1 | `BothWANDown`; gateway VLAN còn hoạt động; CRM/CFONO gom vào `wan-total` |
| O-03 | ĐẠT | 1 | 1 | 1 | Failback 8,775 giây; resolved; dùng lại và đóng ticket #6 |
| O-04 | ĐẠT | 2 | 1 | 1 | CRM độc lập; CFONO/WAN không ảnh hưởng; ticket #2 đóng |
| O-05 | ĐẠT | 2 | 1 | 1 | CFONO độc lập; CRM/WAN không ảnh hưởng; ticket #1 đóng |
| O-06 | ĐẠT | 2 | 1 | 1 | Target DOWN/UP; `monitoring-exporter`; không tạo incident WAN; ticket #8 đóng |
| O-07 | ĐẠT | 0 mới | 0 mới | 0 mới | Phát lại hai lần payload thật; DB/email/phiếu/alert_count không đổi |
| O-08 | ĐẠT | 4 | 1 | 1 | Netem 180 ms/40%; `HighLatency` + `HighPacketLoss` vào `wan-quality:fpt`; ticket #9 |
| O-09 | ĐẠT | 0 mới | 0 mới | 0 mới | Restart 8 container không xóa volume; dữ liệu, workflow, GLPI, dashboard và target còn nguyên |

Raw alert trong bảng gồm cả bản tin `firing` và `resolved`.

## Công thức và nguồn số liệu sau Phase 5

- `Time to Detect = thoi_gian_phat_hien - thoi_gian_bat_dau`.
- `Time to Incident = incident_events.created_at - thoi_gian_bat_dau`.
- `Time to Ticket = notification_events.glpi_completed_at - thoi_gian_bat_dau`; kết quả GLPI `created` hoặc `updated` đều là một hành động ticket hoàn tất.
- `Time to Correlate = incident_events.created_at - raw_alerts.received_at`.
- `Time to Resolve = incident_events.created_at(event_type='alert_resolved') - thoi_gian_bat_dau`.
- `alert duplicate` lấy từ response `duplicate` thực của n8n; số incident/ticket tránh trùng chỉ được ghi khi các bộ đếm PostgreSQL trước và sau không đổi.
- `alert accepted` là số hàng `raw_alerts` mới; `incident created/updated` lấy từ `incident_events`.
- `ticket created/updated/failed` lấy từ `notification_events.glpi_status`; `ticket reused` là trường hợp action `updated` dùng lại ticket đã gắn với incident.

Timestamp thiếu, sai hoặc tạo khoảng thời gian âm được ghi `N/A`; script không tự điền `0`. CSV lịch sử ngày 03/08 chỉ tính lại các khoảng có đủ timestamp gốc. Các trường trước đây chưa ghi riêng, đặc biệt `glpi_completed_at` và duplicate dạng cấu trúc, giữ `N/A` thay vì suy diễn từ ghi chú.

`runtime/wan_status.json` cung cấp `internal_failover_decision_time`; đây là thời gian quyết định nội bộ của monitor. `logs/wan_measurements.csv` cung cấp `fault_to_route_switch_time_seconds`; đây là thời gian end-to-end từ lúc gây lỗi đến khi route đổi. Hai số đo không được gộp thành một metric.

Kết quả 9/9 ở trên là lần chạy lịch sử. Smoke test Phase 5 ngày 07/08/2026 đạt O-01 và O-07, mã thoát `0`. Dữ liệu mới trong `logs/phase_o_smoke_measurements.csv` ghi O-01 có Time to Incident `26.531` giây, Time to Ticket `26.963` giây và Time to Correlate `0.017` giây. O-07 nhận `2` response duplicate; raw alert, incident, `alert_count`, notification và ticket đều tăng `0`, nên số incident/ticket tránh trùng cùng bằng số response duplicate đo được.

## Trạng thái incident và GLPI sau kiểm thử

| Incident | Mức độ | Trạng thái | Ticket | Trạng thái GLPI |
|---|---|---|---:|---|
| `wan-fpt` | trung bình | resolved | 6 | closed |
| `wan-total` | cao | resolved | 7 | closed |
| `service-crm` | trung bình | resolved | 2 | closed |
| `service-cfono` | trung bình | resolved | 1 | closed |
| `monitoring-exporter` | cao | resolved | 8 | closed |
| `wan-quality:fpt` | trung bình | resolved | 9 | closed |

Email tiếp tục ở chế độ `log`; bài test không cấu hình hoặc tuyên bố gửi SMTP thật.

## SQL và API xác minh

Các nhóm truy vấn SQL thực tế trong script:

```sql
SELECT count(*)
FROM n8n.workflow_entity
WHERE id IN ('bpoAlertFlow01','bpoNotifyTicket01') AND active;

SELECT count(*)
FROM raw_alerts r
JOIN incident_alerts ia ON ia.alert_id=r.id
JOIN incidents i ON i.id=ia.incident_id
WHERE r.received_at >= :moc
  AND r.alert_name=:alert_name
  AND r.status=:status
  AND i.incident_key=:incident_key;

SELECT i.incident_key, i.status, x.glpi_ticket_id, x.glpi_status
FROM incidents i
LEFT JOIN incident_integrations x ON x.incident_id=i.id;
```

API đã dùng:

- Exporter: `GET /health`, `GET /metrics`.
- Prometheus: `GET /api/v1/targets`, `GET /api/v1/query`.
- Alertmanager: `GET /api/v2/alerts`.
- n8n: `POST /webhook/bpo-alertmanager`.
- Grafana: `GET /api/dashboards/uid/bpo-network-overview`, `POST /api/ds/query`.
- GLPI: `POST /apirest.php/initSession`, `GET /apirest.php/Ticket/:id`, `GET /apirest.php/killSession`.

## File và lệnh

Tạo:

- `tests/test_phase_o.ps1`
- `tests/run_full_integration.ps1`
- `logs/phase_o_test.log`
- `logs/phase_o_measurements.csv`
- `docs/phase_o_test_plan.md`
- `docs/phase_o_result.md`
- `docs/phase_o_limitations.md`

Sửa tối thiểu do lỗi tích hợp trực tiếp:

- `scripts/wan_monitor.py`: đo mất gói bằng nhiều gói và không coi mất một phần là link down.
- `n8n/bootstrap.sh`: không import lại workflow đang active làm registry webhook runtime bị cũ.

Không sửa topology, Compose, luật cảnh báo hoặc workflow nghiệp vụ.

Chạy lại:

```powershell
powershell -ExecutionPolicy Bypass -File tests/run_full_integration.ps1
```

## Kết luận

Giai đoạn O đã đạt trong môi trường lab. Hệ thống sẵn sàng sang Giai đoạn P để hoàn thiện tài liệu và kịch bản trình diễn, với các giới hạn ghi tại `docs/phase_o_limitations.md`.
