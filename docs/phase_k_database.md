# Thiết kế cơ sở dữ liệu Giai đoạn K

PostgreSQL `17.10` chạy trong Docker network `bpo-monitoring`, không mở cổng `5432` ra Windows. Thông tin kết nối được lấy từ `.env`; file này bị loại khỏi Git bằng `.gitignore`.

## Schema

- Schema `public`: các bảng nghiệp vụ BPO.
- Schema `n8n`: dành riêng cho bảng hệ thống của n8n ở Giai đoạn L.

### `raw_alerts`

Lưu payload gốc từ Alertmanager. `event_key` có ràng buộc `UNIQUE` để cùng một sự kiện gửi lại không tạo bản ghi trùng.

### `incidents`

Lưu sự cố đã gom nhóm. `incident_key` là duy nhất; trạng thái chỉ nhận `open` hoặc `resolved`. Sự cố `resolved` bắt buộc có `resolved_at`.

### `incident_alerts`

Liên kết nhiều-nhiều giữa sự cố và cảnh báo bằng khóa chính ghép `(incident_id, alert_id)`. Khóa ngoại dùng `ON DELETE CASCADE`.

### `incident_events`

Lưu lịch sử mở, cập nhật và khôi phục sự cố. `event_data` dùng `JSONB` để giữ chi tiết thay đổi.

## Chỉ mục chính

- Cảnh báo theo fingerprint, tên, trạng thái và thời gian nhận.
- Sự cố theo trạng thái, thời gian gần nhất và mức độ.
- Liên kết theo `alert_id`.
- Lịch sử theo sự cố và thời gian tạo.

Volume dữ liệu: `bpo-network-monitoring_postgres_data`.
