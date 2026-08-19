# Giai đoạn 11 – Bảo mật lab, CI và phạm vi sử dụng

## Tuyên bố phạm vi

Lab system, not production-ready.

Rule-based topology correlation.

Suspected root cause.

Hệ thống dùng ánh xạ alert, quan hệ phụ thuộc topology và cửa sổ thời gian để đề xuất nguyên nhân nghi ngờ. Kết quả không phải kết luận tuyệt đối.

## Biện pháp đã áp dụng

- `.env` bị loại khỏi Git; `.env.example` chỉ chứa giá trị mẫu.
- `N8N_ENCRYPTION_KEY`, mật khẩu và `ALERTMANAGER_WEBHOOK_TOKEN` là biến bắt buộc, không ghi trực tiếp trong Compose.
- Alertmanager render cấu hình runtime và gửi Bearer token trong header `Authorization`.
- Workflow n8n kiểm tra token trước khi kiểm tra hoặc lưu payload; thiếu token trả HTTP 401.
- Mật khẩu Grafana và tài khoản PostgreSQL chỉ đọc Grafana không còn fallback sang mật khẩu thành phần khác.
- Các cổng giao diện Docker chỉ bind `127.0.0.1`; PostgreSQL và MySQL không publish cổng ra host.
- Token chỉ dùng ký tự chữ, số, `_`, `-` và dài tối thiểu 32 ký tự để render an toàn bằng `sed`.

Prometheus, Alertmanager và Blackbox Exporter vẫn không có cơ chế đăng nhập người dùng. Bind loopback chỉ giảm bề mặt truy cập trong môi trường lab, không thay thế TLS, firewall hoặc xác thực production.

## Đổi token webhook

1. Tạo token ngẫu nhiên mới dài tối thiểu 32 ký tự và cập nhật `ALERTMANAGER_WEBHOOK_TOKEN` trong `.env`.
2. Recreate riêng n8n và Alertmanager:

```powershell
docker compose --env-file .env -f docker/docker-compose.yml up -d --force-recreate n8n alertmanager
```

3. Chạy `tests/test_phase_11_security.ps1` để xác nhận request thiếu token bị từ chối và request có token đi qua bước xác thực.

Không commit token, `.env` hoặc cấu hình runtime `/tmp/alertmanager.yml`.

## CI

Workflow `.github/workflows/ci.yml` chạy:

- compile và unit test Python;
- `docker compose config` với `.env.example`;
- parse toàn bộ YAML và JSON;
- `promtool check config` và `promtool check rules`;
- `amtool check-config`;
- quét secret bằng gitleaks.

File `.gitleaks.toml` vẫn kế thừa toàn bộ rule mặc định và chỉ cho phép đúng hai
chuỗi giả đã xác minh: giá trị mẫu khóa mã hóa trong `.env.example` và định danh
`p8-duplicate-second` của kiểm thử SQL. Không có file hoặc nhóm secret nào bị bỏ qua.

CI không khởi động topology hoặc chạy kiểm thử tích hợp phụ thuộc máy ảo. Regression end-to-end O-01–O-16 phải chạy trong lab Windows + Ubuntu trước khi commit release.

## Kiểm tra cục bộ

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test_phase_11_security.ps1
py -3 -m pytest -q
docker compose --env-file .env -f docker/docker-compose.yml config --quiet
```

Các test gây dừng container hoặc network phải luôn có cleanup. Không dùng `docker compose down -v`.
