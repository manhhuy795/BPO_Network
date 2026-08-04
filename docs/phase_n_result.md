# Kết quả Giai đoạn N

Thời điểm kiểm thử cuối: 03/08/2026. Kết quả: **ĐẠT 14/14**, mã thoát `0`.

## File thay đổi

Cập nhật:

- `docker/docker-compose.yml`
- `.env.example`

Tạo:

- `database/migrations/004_grafana_reader.sql`
- `docker/grafana/provisioning/datasources/datasources.yml`
- `docker/grafana/provisioning/dashboards/dashboards.yml`
- `docker/grafana/provisioning/plugins/plugins.yml`
- `docker/grafana/provisioning/alerting/alerting.yml`
- `docker/grafana/dashboards/bpo_network_overview.json`
- `tests/test_phase_n.ps1`
- `logs/phase_n_test.log`
- `docs/phase_n_dashboard.md`
- `docs/phase_n_result.md`

## Kết quả

- Grafana `13.1.0` healthy tại `http://localhost:3000`.
- Prometheus datasource: `OK`.
- PostgreSQL datasource: `OK`.
- Dashboard tự nạp đủ 19 panel.
- Truy vấn Grafana trả khung dữ liệu thật từ cả hai datasource.
- FPT thay đổi `1 -> 0 -> 1`; Viettel thực sự tiếp quản trong dữ liệu Prometheus/Grafana khi chạy lỗi Mininet.
- Incident xuất hiện qua PostgreSQL datasource.
- Dashboard và datasource còn sau restart Grafana; volume `grafana_data` tồn tại.
- Container các giai đoạn cũ vẫn healthy.

## Bằng chứng luồng đầy đủ

Cặp cảnh báo thật do lỗi Mininet:

- firing raw alert `128` lúc `08:14:31 UTC`;
- resolved raw alert `129` lúc `08:14:36 UTC`;
- fingerprint `5b63b19a481977d7`;
- incident `wan-fpt`;
- ticket GLPI `6`;
- email firing/resolved: `logged`;
- GLPI firing: `created`;
- GLPI resolved: `closed`.

Luồng đã xác minh:

```text
Mininet ngắt FPT
  -> exporter cập nhật bpo_link_up và bpo_active_link
  -> Prometheus sinh FPTDownViettelAvailable
  -> Alertmanager gửi firing/resolved
  -> n8n chuẩn hóa, chống trùng và gom incident
  -> PostgreSQL lưu dữ liệu
  -> email được ghi log an toàn
  -> GLPI tạo rồi đóng ticket
  -> Grafana đọc metric và incident thật
```

Các lần lỗi sau được gom vào ticket `wan-total` đang mở nếu nằm trong cửa sổ tương quan, đúng quy tắc không tạo phiếu triệu chứng trùng.

Chạy lại:

```powershell
powershell -ExecutionPolicy Bypass -File tests/test_phase_n.ps1
```

Log gốc: `logs/phase_n_test.log`.

## Hạn chế

- Chưa có SMTP thật; email chỉ ở chế độ `log`.
- CRM/CFONO hiển thị `MẤT` khi topology Mininet đã dừng, vì hai HTTP server thuộc namespace Mininet.
- Không có phiên trình duyệt tích hợp để chụp ảnh dashboard; QA cuối dùng Grafana API, datasource health, truy vấn dữ liệu và mô hình 19 panel.
- Nếu chưa khai báo biến Grafana riêng, tài khoản quản trị dùng mật khẩu fallback từ n8n; nên tách mật khẩu khi triển khai ngoài lab.
