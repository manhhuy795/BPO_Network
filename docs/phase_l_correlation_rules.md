# Giai đoạn L - Quy tắc gom nhóm cảnh báo

## Cửa sổ tương quan

Cửa sổ mặc định là 120 giây. Thời gian chỉ là một điều kiện; workflow còn xét alertname, provider, service và sự cố đang mở.

## Tạo incident_key và thứ tự ưu tiên

| Cảnh báo | `incident_key` | Mức độ | Xử lý |
|---|---|---|---|
| `BothWANDown` | `wan-total` | cao | Sự cố gốc ưu tiên cao nhất. |
| `FPTDownViettelAvailable` | `wan-fpt` | trung bình | Không coi là mất toàn bộ Internet. |
| `CRMDown` | `service-crm` | trung bình | Độc lập khi không có `wan-total`. |
| `CFONODown` | `service-cfono` | trung bình | Độc lập khi không có `wan-total`. |
| `HighLatency`, `HighPacketLoss` | `wan-quality:<provider>` | mức cao nhất của nhóm | Chỉ gom cùng nhà mạng. |
| `BPOExporterDown` | `monitoring-exporter` | cao | Sự cố hệ thống giám sát, không tự coi là mất mạng doanh nghiệp. |
| Alertname khác | `other:<alertname>:<pham_vi>` | theo alert | Vẫn lưu và tạo sự cố. |

Phạm vi của cảnh báo chưa có quy tắc ưu tiên theo: provider, service, VLAN, project, instance, global.

## Mất WAN tổng

`BothWANDown` tạo hoặc cập nhật `wan-total`. Trong 120 giây, các cảnh báo FPT, CRM, CFONO, độ trễ và mất gói liên quan được chuyển vào `wan-total`. Các incident nguồn được đánh dấu `resolved` với event `merged`, nhờ đó không có hai sự cố gốc cùng mở.

Tiêu đề: “Mất toàn bộ kết nối Internet”. Nguyên nhân nghi ngờ chỉ nêu khả năng mất hai đường hoặc lỗi router, firewall, thiết bị biên; không khẳng định khi chưa có đủ dữ liệu.

## Dịch vụ và chất lượng đường truyền

- CRM và CFONO tạo hai incident riêng khi WAN bình thường.
- Khi `wan-total` đang mở trong cửa sổ, CRM/CFONO là triệu chứng và được gắn vào sự cố WAN tổng.
- `HighLatency` và `HighPacketLoss` chỉ gom khi cùng provider. FPT và Viettel không bị trộn khi chỉ một đường suy giảm.
- Mức độ incident chỉ tăng theo `cao > trung_binh > thap`, không bị hạ bởi một alert mới nhẹ hơn.

## Chống trùng

- Firing: `fingerprint|status|startsAt`.
- Resolved: `fingerprint|status|startsAt|endsAt`.
- `received_at` không tham gia `event_key`.
- `raw_alerts.event_key` có ràng buộc duy nhất và lệnh ghi dùng `ON CONFLICT DO NOTHING`.
- Event trùng không tăng `alert_count`, không tạo liên kết và không ghi lịch sử lần nữa.

## Phục hồi

Resolved luôn được lưu vào `raw_alerts`. Workflow tìm firing cùng fingerprint và `startsAt`, gắn bản ghi phục hồi vào incident và ghi `incident_events`. Incident chỉ chuyển sang `resolved` khi không còn firing nào chưa có resolved tương ứng.

Resolved không có firing tương ứng chỉ tạo raw alert, trả trạng thái `resolved` và không tạo incident mới.

## Tính nhất quán và giới hạn

Hàm PostgreSQL chạy trong một transaction và dùng advisory lock theo fingerprint/incident key. Ràng buộc duy nhất tiếp tục là lớp bảo vệ cuối cùng khi webhook đến đồng thời.

Tương quan là suy luận dựa trên thời gian và quan hệ phụ thuộc, không phải chẩn đoán chắc chắn. Mô hình chưa phân tích theo từng máy người dùng, chưa có topology graph động và dùng một bản ghi incident cho mỗi `incident_key`, tái sử dụng bản ghi khi sự cố tái diễn.
