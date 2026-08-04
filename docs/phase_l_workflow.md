# Giai đoạn L - Workflow n8n xử lý cảnh báo

## Luồng xử lý

```text
Alertmanager
  -> Nhận cảnh báo từ Alertmanager
  -> Kiểm tra payload
  -> Payload hợp lệ?
       -> sai: Trả lỗi payload (HTTP 400)
       -> đúng: Tách từng cảnh báo
          -> Chuẩn hóa cảnh báo
          -> Tạo khóa sự kiện
          -> Chống trùng và gom nhóm trong PostgreSQL
          -> Tổng hợp kết quả
          -> Trả kết quả thành công (HTTP 200)
```

## Chức năng các node

| Node | Chức năng |
|---|---|
| Nhận cảnh báo từ Alertmanager | Nhận `POST` tại webhook production. |
| Kiểm tra payload | Kiểm tra JSON, mảng `alerts`, trạng thái, `alertname`, `fingerprint` và thời gian bắt buộc. |
| Payload hợp lệ? | Tách nhánh hợp lệ và không hợp lệ. |
| Tách từng cảnh báo | Biến mỗi phần tử trong `alerts` thành một item n8n. |
| Chuẩn hóa cảnh báo | Chuẩn hóa nhãn, mức độ, thời gian, annotation và payload gốc. Nhãn tùy chọn có thể khuyết. |
| Tạo khóa sự kiện | Tạo `event_key` ổn định, không dùng thời gian nhận hiện tại. |
| Chống trùng và gom nhóm trong PostgreSQL | Gọi `process_bpo_alert()`; toàn bộ ghi raw, incident, liên kết và lịch sử nằm trong một giao dịch. |
| Tổng hợp kết quả | Gộp kết quả của payload nhiều cảnh báo. |
| Trả kết quả | Trả `created`, `updated`, `duplicate`, `resolved` hoặc `invalid`. |

Việc chống trùng và tương quan được đặt trong PostgreSQL để tận dụng ràng buộc duy nhất, transaction và advisory lock. Cách này tránh hai webhook đến gần nhau tạo hai sự cố trùng.

## Dữ liệu và phản hồi

Payload vào gần giống payload webhook của Alertmanager, có `status` và mảng `alerts`. Mỗi alert có `status`, `labels`, `annotations`, `startsAt`, `endsAt` và `fingerprint`.

Phản hồi thành công có HTTP 200 và dạng:

```json
{
  "status": "created",
  "thong_bao": "Cảnh báo đã được lưu và tạo sự cố.",
  "so_canh_bao": 1,
  "ket_qua": []
}
```

Payload sai trả HTTP 400 và nêu lý do bằng tiếng Việt. Lỗi xử lý nội bộ trả HTTP 500 và transaction PostgreSQL được hoàn tác.

## Nhập và kích hoạt workflow

Lần khởi động đầu, Compose tự tạo tài khoản chủ n8n, nạp credential PostgreSQL, nhập file `n8n/workflows/bpo_alert_correlation.json`, publish workflow rồi mới khởi động n8n chính:

```powershell
docker compose --env-file .env -f docker/docker-compose.yml up -d
```

Khi cần nạp lại workflow từ file mà không xóa dữ liệu hoặc volume:

```powershell
docker compose --env-file .env -f docker/docker-compose.yml stop n8n alertmanager
docker compose --env-file .env -f docker/docker-compose.yml rm -f n8n-config
docker compose --env-file .env -f docker/docker-compose.yml up -d
```

Có thể nhập trực tiếp file JSON trong giao diện n8n, sau đó chọn credential PostgreSQL nghiệp vụ BPO và publish workflow.

## URL

- Giao diện n8n trên Windows: `http://localhost:5678`
- Webhook nội bộ cho Alertmanager: `http://n8n:5678/webhook/bpo-alertmanager`
- Webhook production dùng từ Windows: `http://localhost:5678/webhook/bpo-alertmanager`

Không dùng `/webhook-test` trong cấu hình chính thức.
