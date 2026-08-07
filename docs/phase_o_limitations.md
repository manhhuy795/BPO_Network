# Hạn chế Giai đoạn O

- Email dùng chế độ `log`, không gửi SMTP thật.
- CRM/CFONO thuộc namespace Mininet nên chỉ được đánh giá khi topology đang chạy.
- `bpo_service_process_up` đo tiến trình HTTP server, còn `probe_success` đo khả năng truy cập HTTP. Trong O-02, sau khi chứng minh máy dự án không truy cập được dịch vụ vì hai WAN mất, bài test dừng thật hai tiến trình để sinh cảnh báo CRM/CFONO và kiểm chứng quy tắc gom triệu chứng; đây là lỗi bổ sung có chủ đích, không phải kết luận rằng WAN down tự làm tiến trình dừng.
- Grafana được kiểm chứng bằng API dashboard và truy vấn datasource, không chụp ảnh trình duyệt tự động.
- PostgreSQL tái sử dụng một incident theo `incident_key`; khi sự cố tái diễn, thời điểm “tạo incident” trong CSV là thời điểm event mở lại/cập nhật được ghi, không phải tạo thêm hàng incident.
- Phiếu GLPI cũ được cập nhật/mở lại theo incident đã có; bài test xác minh một liên kết phiếu cho mỗi incident và không coi việc tái sử dụng phiếu là tạo mới.
- Số liệu phụ thuộc chu kỳ ping, scrape, thời gian `for` của Prometheus và lịch xử lý thực tế trên máy lab.
