# Thiết kế Dual-WAN Giai đoạn F

## Mục tiêu

Giữ nguyên mạng VLAN và dịch vụ của Giai đoạn D/E, đồng thời bổ sung FPT làm đường chính và Viettel làm đường dự phòng.

## Topology

```text
Máy người dùng
  -> Access Switch -> Distribution -> Core -> r1
       -> isp_fpt     -> r_internet -> s_outside -> CRM/CFONO
       -> isp_viettel -> r_internet -> s_outside -> CRM/CFONO
```

Các mạng trung chuyển:

- `r1` – FPT: `100.64.10.0/30`.
- `r1` – Viettel: `100.64.20.0/30`.
- FPT – Internet chung: `100.64.30.0/30`.
- Viettel – Internet chung: `100.64.40.0/30`.
- Dịch vụ đối tác giữ nguyên: `172.16.100.0/24`.

## Cơ chế chuyển đường

`wan_monitor.py` chạy trong namespace của `r1` và kiểm tra mỗi 2 giây:

- FPT: ping `100.64.30.2` qua `r1-eth1`.
- Viettel: ping `100.64.40.2` qua `r1-eth2`.
- FPT thất bại 3 lần liên tiếp: route `172.16.100.0/24` chuyển sang Viettel.
- FPT thành công 5 lần liên tiếp: route chuyển về FPT.
- Route chỉ được sửa khi `active_wan` thay đổi.

Lưu lượng nội bộ ra mạng đối tác được NAT tại `r1`. Chính sách cô lập VLAN vẫn dùng iptables như Giai đoạn D/E.

## Điều khiển lỗi

Trong Mininet CLI:

```text
r1 bash scripts/fpt_down.sh
r1 bash scripts/fpt_up.sh
r1 bash scripts/viettel_down.sh
r1 bash scripts/viettel_up.sh
```

Các script thay đổi trạng thái thật của `r1-eth1` hoặc `r1-eth2`, không thay đổi biến giả.
