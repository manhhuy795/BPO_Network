# Email thông báo Giai đoạn M

## Cách hoạt động

Workflow `BPO - Thông báo email và phiếu GLPI` chỉ xử lý email khi PostgreSQL tạo một bản ghi duy nhất trong `notification_events` cho một trong bốn loại sự kiện:

- incident mới;
- mức độ tăng;
- thay đổi quan trọng;
- incident phục hồi.

`notification_key` có ràng buộc duy nhất. Payload Alertmanager gửi lại với cùng `event_key` không tạo thêm bản ghi và không gửi lại email.

Tiêu đề có dạng:

```text
[BPO][MỨC ĐỘ][TRẠNG THÁI] Tên sự cố
```

Nội dung gồm mã sự cố, tiêu đề, mức độ, trạng thái, thời gian bắt đầu, cảnh báo liên quan, nguyên nhân nghi ngờ, WAN đang dùng và hướng xử lý đề xuất. WAN được truy vấn trực tiếp từ Prometheus trước khi lưu/gửi.

## Chế độ hiện tại

`EMAIL_MODE=log`. Hệ thống lưu nội dung email đã hoàn chỉnh vào PostgreSQL với `email_status='logged'`; chưa gửi tới hộp thư thật và không tuyên bố đã gửi SMTP.

Kiểm tra nhật ký:

```sql
SELECT id, incident_id, event_type, email_status, email_subject, email_body, created_at
FROM notification_events
ORDER BY id DESC;
```

## Chuyển sang SMTP thật

Điền các biến `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_SECURE`, `SMTP_FROM`, `SMTP_TO` trong `.env`, đổi `EMAIL_MODE=smtp`, rồi nạp lại credential/workflow:

```powershell
docker compose --env-file .env -f docker/docker-compose.yml stop n8n
docker compose --env-file .env -f docker/docker-compose.yml up n8n-config --no-deps --force-recreate
docker compose --env-file .env -f docker/docker-compose.yml up -d n8n
```

Chỉ xem là gửi email thật khi `email_status='sent'` và hộp thư đích đã nhận được thư.
