# Kết quả Giai đoạn M

Thời điểm kiểm thử cuối: 03/08/2026. Kết quả: **ĐẠT 14/14**, mã thoát `0`.

## File thay đổi

Cập nhật:

- `docker/docker-compose.yml`
- `.env.example`
- `n8n/bootstrap.sh`
- `n8n/workflows/bpo_alert_correlation.json`

Tạo:

- `backups/phase_m_before/n8n/workflows/bpo_alert_correlation.json`
- `database/migrations/003_glpi_integration.sql`
- `n8n/workflows/bpo_notification_ticket.json`
- `tests/test_phase_m.ps1`
- `logs/phase_m_test.log`
- `docs/phase_m_email.md`
- `docs/phase_m_glpi.md`
- `docs/phase_m_result.md`

## Kết quả chính

- PostgreSQL, n8n, GLPI và MySQL healthy.
- Hai workflow `bpoAlertFlow01` và `bpoNotifyTicket01` active.
- Incident mới tạo đúng một ticket.
- Payload trùng không tạo email/ticket mới.
- Tăng mức độ cập nhật ticket cũ.
- Phục hồi thêm ghi chú và đóng đúng ticket.
- CRM và CFONO có hai ticket độc lập.
- Dữ liệu còn sau restart.
- Prometheus và Alertmanager không bị ảnh hưởng.

Email hiện chạy chế độ `log`: nội dung và WAN thực được lưu với trạng thái `logged`; **chưa gửi SMTP thật**.

Chạy lại:

```powershell
powershell -ExecutionPolicy Bypass -File tests/test_phase_m.ps1
```

Log gốc: `logs/phase_m_test.log`.
