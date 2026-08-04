# GLPI Giai đoạn M

## Thành phần

- GLPI: `glpi/glpi:10.0.26`, URL `http://localhost:8080`.
- MySQL riêng: `mysql:8.4`, không mở cổng ra Windows.
- Volume: `glpi_data` và `glpi_db_data`.
- API GLPI được bật bằng one-shot service `glpi-init`.
- API client chỉ cho phép mạng Docker nội bộ `172.18.0.0/16` bằng `glpi-api-init`.

Thông tin đăng nhập/API lấy từ `.env`: `GLPI_API_USER`, `GLPI_API_PASSWORD` và các biến `GLPI_DB_*`. Không có mật khẩu trong workflow hoặc file Compose.

## Quy tắc phiếu

| Incident | Ưu tiên GLPI |
|---|---:|
| `wan-total`, `monitoring-exporter` | 5 - cao |
| `wan-fpt`, CRM, CFONO | 3 - trung bình |
| Cảnh báo mức thấp khác | 2 - thấp |

- Incident mới: tạo một ticket.
- Incident cập nhật: thêm follow-up và cập nhật ticket cũ.
- Incident phục hồi: thêm ghi chú phục hồi, đặt trạng thái GLPI `6` và đóng ticket.
- Payload trùng: không gọi API.
- Cảnh báo dịch vụ được gom vào `wan-total`: dùng ticket `wan-total`, không tạo ticket triệu chứng.

Liên kết duy nhất được lưu trong `incident_integrations`; khóa chính `incident_id` bảo đảm mỗi incident có tối đa một ticket. Mọi nội dung dùng cụm từ “nguyên nhân nghi ngờ”, không khẳng định nguyên nhân chắc chắn.

## Kiểm tra

```powershell
Invoke-RestMethod http://localhost:8080
docker compose --env-file .env -f docker/docker-compose.yml ps -a glpi glpi-db glpi-init glpi-api-init
```

```sql
SELECT i.incident_key, x.glpi_ticket_id, x.glpi_status, x.updated_at
FROM incident_integrations x
JOIN incidents i ON i.id=x.incident_id
ORDER BY x.updated_at DESC;
```

Lưu ý: dải API phụ thuộc subnet Docker hiện tại. Nếu Docker cấp subnet khác `172.18.0.0/16`, cần cập nhật hai giá trị `INET_ATON` trong `glpi-api-init`.
