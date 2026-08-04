# Kết quả Giai đoạn I – Prometheus và Blackbox Exporter

Thời điểm kiểm thử: 2026-08-03

## Cấu hình

- Prometheus `v3.13.2`: `http://localhost:9090`.
- Blackbox Exporter `v0.28.0`: `http://localhost:9115`.
- Ubuntu exporter: hostname Docker `ubuntu-vm:9105`.
- IP của Ubuntu chỉ lấy từ biến `UBUNTU_VM_IP` trong `.env.example`.
- Nhãn nhận dạng: `environment="bpo_lab"`, `site="tru_so_345"`.
- Volume dữ liệu: `bpo-network-monitoring_prometheus_data`.
- Blackbox chỉ kiểm tra `http://ubuntu-vm:9105/health`; không khai báo CRM/CFONO là endpoint mà Windows truy cập trực tiếp.

## Kết quả thực tế

| Nội dung | Kết quả |
|---|---|
| Container Prometheus và Blackbox khởi động | ĐẠT |
| Prometheus healthy | ĐẠT |
| Blackbox Exporter healthy | ĐẠT |
| Prometheus truy cập được qua cổng 9090 | ĐẠT |
| Target `bpo_exporter` | UP |
| Target `blackbox_http` | UP, `probe_success=1` |
| Prometheus nhận metric `bpo_*` | ĐẠT |
| Dữ liệu còn sau khi restart Prometheus | ĐẠT |
| Endpoint Ubuntu không bị gián đoạn | ĐẠT |

Tổng kết: `8/8` kiểm thử đạt, mã thoát `0`.

Chi tiết được lưu tại `logs/phase_i_test.log`.
