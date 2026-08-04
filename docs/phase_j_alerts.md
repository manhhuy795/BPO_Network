# Luật cảnh báo Giai đoạn J

Prometheus đánh giá luật mỗi 5 giây. Các điều kiện WAN và dịch vụ chỉ được đánh giá khi `bpo_exporter` còn UP, tránh dùng dữ liệu cũ khi exporter mất kết nối.

| Cảnh báo | Điều kiện | Chờ | Mức độ | Nguyên nhân nghi ngờ |
|---|---|---:|---|---|
| `BPOExporterDown` | Target `bpo_exporter` DOWN | 10 giây | cao | Exporter dừng, cổng 9105 bị chặn hoặc VM mất kết nối |
| `FPTDownViettelAvailable` | FPT DOWN và Viettel UP | 10 giây | trung bình | Tuyến hoặc interface FPT lỗi |
| `BothWANDown` | FPT và Viettel cùng DOWN | 10 giây | cao | Router, kết nối chung hoặc cả hai nhà mạng lỗi |
| `CRMDown` | CRM DOWN độc lập | 10 giây | trung bình | HTTP server CRM dừng |
| `CFONODown` | CFONO DOWN độc lập | 10 giây | trung bình | HTTP server CFONO dừng |
| `HighPacketLoss` | Mất gói `>20%`, link vẫn UP | 15 giây | trung bình | Nghẽn hoặc chất lượng tuyến suy giảm |
| `HighLatency` | Độ trễ `>100 ms`, link vẫn UP | 30 giây | thấp | Nghẽn hoặc định tuyến không tối ưu |

`FPTDownViettelAvailable` và `BothWANDown` loại trừ nhau ngay trong biểu thức: khi Viettel DOWN, cảnh báo FPT đơn lẻ không còn đúng và `BothWANDown` trở thành cảnh báo chính.

Alertmanager hiện chỉ nhận, gom nhóm và hiển thị cảnh báo tại chỗ. Chưa cấu hình webhook n8n hoặc giả lập rằng n8n hoạt động.
