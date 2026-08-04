# Kết quả Giai đoạn J – Alertmanager và luật cảnh báo

Thời điểm kiểm thử: 2026-08-03

## Thành phần

- Prometheus `v3.13.2`.
- Blackbox Exporter `v0.28.0`.
- Alertmanager `v0.33.1` tại `http://localhost:9093`.
- Prometheus đã kết nối một Alertmanager active.
- `promtool` tải thành công `7` luật trong `bpo_alerts.yml`.
- `amtool` xác nhận `alertmanager.yml` hợp lệ.

## Kết quả kiểm thử thực tế

| Nội dung | Kết quả |
|---|---|
| Prometheus tải đủ 7 luật BPO | ĐẠT |
| Alertmanager healthy và được Prometheus kết nối | ĐẠT |
| Dừng exporter tạo `BPOExporterDown`, mức cao | ĐẠT |
| Khởi động exporter giải quyết `BPOExporterDown` | ĐẠT |
| Ngắt FPT tạo `FPTDownViettelAvailable`, mức trung bình | ĐẠT |
| Ngắt cả hai WAN tạo `BothWANDown`, mức cao; cảnh báo FPT đơn lẻ biến mất | ĐẠT |
| Dừng CRM tạo `CRMDown`, không tạo `CFONODown`; khởi động lại thì phục hồi | ĐẠT |
| Khôi phục thành phần giải quyết toàn bộ cảnh báo thử nghiệm | ĐẠT |

Tổng kết: `8/8` kiểm thử đạt, mã thoát `0`.

Sau khi bổ sung J, kiểm thử lại Giai đoạn I cũng đạt `8/8`, mã thoát `0`. Dữ liệu Prometheus vẫn còn sau khi restart container.

## Giới hạn hiện tại

- Alertmanager dùng receiver cục bộ `local_only`, chưa gửi webhook.
- Chưa triển khai hoặc giả lập n8n, PostgreSQL, Grafana hay GLPI.
- `HighPacketLoss` và `HighLatency` đã được `promtool` kiểm tra và Prometheus nạp thành công, nhưng không cố ý tạo suy hao/độ trễ giả trong lượt kiểm thử J.
- Khi topology Mininet không chạy, CRM và CFONO thực sự dừng nên hai cảnh báo dịch vụ có thể firing. Khởi động topology sẽ đưa chúng về trạng thái phục hồi.

Chi tiết được lưu tại `logs/phase_j_test.log`.
