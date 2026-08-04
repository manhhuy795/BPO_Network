# Kết quả Giai đoạn K – PostgreSQL

Thời điểm kiểm thử: 2026-08-03

| Nội dung | Kết quả |
|---|---|
| PostgreSQL khởi động và healthy | ĐẠT |
| Tạo đủ `raw_alerts`, `incidents`, `incident_alerts`, `incident_events` | ĐẠT |
| Volume giữ bản ghi sau restart container | ĐẠT |
| `event_key` từ chối bản ghi trùng | ĐẠT |
| Prometheus, Blackbox và Alertmanager tiếp tục healthy | ĐẠT |

Tổng kết: `5/5` kiểm thử đạt, mã thoát `0`.

PostgreSQL chỉ xuất cổng `5432` trong Docker network nội bộ, không publish ra Windows. Bản ghi dùng để thử restart và chống trùng đã được xóa sau kiểm thử; dữ liệu và volume hiện có không bị xóa.

Chi tiết được lưu tại `logs/phase_k_test.log`.
