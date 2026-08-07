# Dashboard Grafana Giai đoạn N

## Truy cập và nguồn dữ liệu

- Grafana: `http://localhost:3000`.
- Dashboard: `BPO 345 - Giám sát mạng và sự cố`.
- UID: `bpo-network-overview`.
- Prometheus datasource UID: `bpo-prometheus`.
- PostgreSQL datasource UID: `bpo-postgres`.

Datasource PostgreSQL dùng role `bpo_grafana` chỉ có `SELECT`; phép ghi đã được kiểm thử và bị từ chối. Dashboard/datasource được provision từ file và không cần cấu hình thủ công.

## Danh sách 19 panel

Tổng quan:

1. Trạng thái FPT.
2. Trạng thái Viettel.
3. Đường WAN đang sử dụng.
4. Dịch vụ CRM.
5. Dịch vụ CFONO.
6. Ubuntu exporter.
7. Sự cố đang mở.
8. Sự cố mức cao đang mở.

Chất lượng và chuyển đường:

9. Failover gần nhất.
10. Failback gần nhất.
11. Số lần FPT gặp lỗi trong khoảng thời gian đang xem.
12. Số lần chuyển sang Viettel trong khoảng thời gian đang xem.
13. RTT min/avg/max/mdev của FPT và Viettel.
14. Tỷ lệ mất gói.
15. Lịch sử thời gian failover và failback.

Sự cố và thống kê:

16. Danh sách sự cố, nguyên nhân nghi ngờ, số cảnh báo, trạng thái GLPI và thời gian phục hồi.
17. Số sự cố theo loại.
18. Số sự cố theo mức độ.
19. Thời gian xử lý trung bình.

Không panel nào dùng Grafana TestData hoặc số liệu nhập cố định. Hai bộ đếm lỗi FPT/chuyển Viettel được suy ra từ số lần thay đổi metric trong khoảng thời gian dashboard; đây là phép đếm từ chuỗi thời gian thật, không phải bộ đếm tích lũy vĩnh viễn.

`bpo_ping_rtt_mdev_ms` biểu diễn độ biến thiên RTT trong môi trường lab. Không coi đây là jitter RTP hoặc jitter VoIP chính xác.

## Tài khoản

Tên người dùng mặc định là `admin`. Mật khẩu lấy từ `GRAFANA_ADMIN_PASSWORD`; nếu biến này chưa có, cấu hình lab dùng giá trị `N8N_OWNER_PASSWORD`. Nên đặt mật khẩu Grafana riêng trong `.env` trước khi trình diễn ngoài máy cá nhân.
