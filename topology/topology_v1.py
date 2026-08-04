#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""Topology mạng nội bộ và dịch vụ đối tác - Giai đoạn D, E."""

import os
import subprocess
import sys

from mininet.cli import CLI
from mininet.log import setLogLevel
from mininet.net import Mininet
from mininet.node import Node, OVSSwitch
from mininet.topo import Topo


CAC_VLAN = {
    20: "10.10.20.1/24",
    30: "10.10.30.1/24",
    40: "10.10.40.1/24",
    50: "10.10.50.1/24",
    60: "10.10.60.1/24",
}

CAC_MAY = {
    "pc_du_an_1": ("10.10.20.10/24", "10.10.20.1", 20),
    "pc_du_an_2": ("10.10.30.10/24", "10.10.30.1", 30),
    "pc_du_an_3": ("10.10.40.10/24", "10.10.40.1", 40),
    "pc_du_an_4": ("10.10.50.10/24", "10.10.50.1", 50),
    "pc_it": ("10.10.60.10/24", "10.10.60.1", 60),
    "pc_office": ("10.10.60.20/24", "10.10.60.1", 60),
}

NOI_DUNG_CRM = "CRM phía đối tác đang hoạt động"
NOI_DUNG_CFONO = "CFONO phía đối tác đang hoạt động"


class LinuxRouter(Node):
    """Router Linux làm gateway cho các VLAN."""

    def config(self, **params):
        super().config(**params)
        self.cmd("sysctl -w net.ipv4.ip_forward=1 >/dev/null")

    def terminate(self):
        self.cmd("sysctl -w net.ipv4.ip_forward=0 >/dev/null")
        super().terminate()


class BPOTopology(Topo):
    """Router -> Core -> Distribution -> Access -> Máy người dùng."""

    def build(self):
        router = self.addNode("r1", cls=LinuxRouter)
        core = self.addSwitch(
            "s_core",
            cls=OVSSwitch,
            failMode="standalone",
            dpid="0000000000000001",
        )
        distribution = self.addSwitch(
            "s_dist",
            cls=OVSSwitch,
            failMode="standalone",
            dpid="0000000000000002",
        )
        outside = self.addSwitch(
            "s_outside",
            cls=OVSSwitch,
            failMode="standalone",
            dpid="0000000000000100",
        )

        access = {
            vlan: self.addSwitch(
                f"s_a{vlan}",
                cls=OVSSwitch,
                failMode="standalone",
                dpid=f"{vlan:016x}",
            )
            for vlan in CAC_VLAN
        }
        may = {
            ten: self.addHost(ten, ip=ip, defaultRoute=f"via {gateway}")
            for ten, (ip, gateway, _vlan) in CAC_MAY.items()
        }
        crm = self.addHost(
            "srv_crm",
            ip="172.16.100.10/24",
            defaultRoute="via 172.16.100.1",
        )
        cfono = self.addHost(
            "srv_cfono",
            ip="172.16.100.20/24",
            defaultRoute="via 172.16.100.1",
        )

        # Hai đường trunk mang toàn bộ VLAN nội bộ.
        self.addLink(router, core)
        self.addLink(core, distribution)

        # Mỗi Access Switch chỉ nhận VLAN của chính nó.
        for vlan, switch in access.items():
            self.addLink(distribution, switch)

        for ten, host in may.items():
            vlan = CAC_MAY[ten][2]
            self.addLink(access[vlan], host)

        # Mạng đối tác chỉ nối với interface ngoài của router.
        self.addLink(router, outside)
        self.addLink(outside, crm)
        self.addLink(outside, cfono)


def dat_cong_ovs(ten_cong, che_do, vlan):
    """Đặt một cổng Open vSwitch ở chế độ trunk hoặc access."""
    tham_so_vlan = f"trunks={vlan}" if che_do == "trunk" else f"tag={vlan}"
    subprocess.run(
        [
            "ovs-vsctl",
            "set",
            "port",
            ten_cong,
            f"vlan_mode={che_do}",
            tham_so_vlan,
        ],
        check=True,
    )


def ten_cong_noi(net, ten_node, ten_doi_tac):
    """Lấy tên interface thật giữa hai node Mininet."""
    ket_noi = net.get(ten_node).connectionsTo(net.get(ten_doi_tac))
    if not ket_noi:
        raise RuntimeError(f"Không có kết nối {ten_node} - {ten_doi_tac}.")
    return ket_noi[0][0].name


def cau_hinh_vlan(net):
    """Cấu hình các cổng trunk và access trên Open vSwitch."""
    tat_ca_vlan = ",".join(str(vlan) for vlan in CAC_VLAN)

    dat_cong_ovs(ten_cong_noi(net, "s_core", "r1"), "trunk", tat_ca_vlan)
    dat_cong_ovs(
        ten_cong_noi(net, "s_core", "s_dist"), "trunk", tat_ca_vlan
    )
    dat_cong_ovs(
        ten_cong_noi(net, "s_dist", "s_core"), "trunk", tat_ca_vlan
    )

    for vlan in CAC_VLAN:
        ten_access = f"s_a{vlan}"
        dat_cong_ovs(ten_cong_noi(net, "s_dist", ten_access), "trunk", vlan)
        dat_cong_ovs(ten_cong_noi(net, ten_access, "s_dist"), "trunk", vlan)

    for ten_may, (_ip, _gateway, vlan) in CAC_MAY.items():
        dat_cong_ovs(
            ten_cong_noi(net, f"s_a{vlan}", ten_may), "access", vlan
        )


def cau_hinh_router(router):
    """Tạo gateway VLAN và chính sách cô lập bằng iptables."""
    router.cmd("ip link set r1-eth0 up")

    for vlan, gateway in CAC_VLAN.items():
        giao_dien = f"r1-eth0.{vlan}"
        router.cmd(
            f"ip link add link r1-eth0 name {giao_dien} type vlan id {vlan}"
        )
        router.cmd(f"ip addr add {gateway} dev {giao_dien}")
        router.cmd(f"ip link set {giao_dien} up")

    # Interface mạng ngoài không thuộc VLAN nội bộ.
    router.cmd("ip addr add 172.16.100.1/24 dev r1-eth1")
    router.cmd("ip link set r1-eth1 up")

    # Mặc định chặn định tuyến giữa các VLAN.
    router.cmd("iptables -F")
    router.cmd("iptables -t nat -F")
    router.cmd("iptables -X")
    router.cmd("iptables -P FORWARD DROP")
    router.cmd(
        "iptables -A FORWARD "
        "-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
    )

    # Chỉ máy IT được chủ động ping các máy dự án.
    for vlan in (20, 30, 40, 50):
        router.cmd(
            "iptables -A FORWARD "
            f"-s 10.10.60.10 -d 10.10.{vlan}.0/24 -p icmp -j ACCEPT"
        )

    # Máy nội bộ chỉ được mở kết nối HTTP tới dịch vụ phía đối tác.
    router.cmd(
        "iptables -A FORWARD -s 10.10.0.0/16 -d 172.16.100.0/24 "
        "-p tcp --dport 80 -j ACCEPT"
    )


def ping_duoc(host, dich):
    """Trả về True khi host ping được địa chỉ đích."""
    ma_loi = host.cmd(
        f"ping -c 1 -W 2 {dich} >/dev/null 2>&1; printf '%s' $?"
    ).strip()
    return ma_loi == "0"


def ghi_ket_qua(ten, thuc_te, mong_doi):
    """In một kết quả và trả về trạng thái đạt."""
    dat = thuc_te == mong_doi
    print(f"[{'ĐẠT' if dat else 'KHÔNG ĐẠT'}] {ten}")
    return dat


def doc_http(host, dia_chi):
    """Đọc nội dung HTTP bằng thư viện chuẩn Python trong host Mininet."""
    lenh = (
        'python3 -c "import urllib.request; '
        f"print(urllib.request.urlopen('http://{dia_chi}', timeout=2)"
        ".read().decode('utf-8'))\" 2>/dev/null"
    )
    return host.cmd(lenh).strip()


def chay_script_dich_vu(host, ten_script):
    """Chạy script dịch vụ trong namespace của máy chủ."""
    ma_loi = host.cmd(
        f"bash scripts/{ten_script} >/dev/null 2>&1; printf '%s' $?"
    ).strip()
    return ma_loi == "0"


def kiem_tra_giai_doan_d(net):
    """Kiểm tra đầy đủ gateway và chính sách VLAN của Giai đoạn D."""
    print("\nKIỂM THỬ GIAI ĐOẠN D")
    ket_qua = []
    du_an = [net.get(f"pc_du_an_{so}") for so in range(1, 5)]
    office = net.get("pc_office")
    it = net.get("pc_it")

    for ten, (_ip, gateway, _vlan) in CAC_MAY.items():
        ket_qua.append(
            ghi_ket_qua(
                f"{ten} ping được gateway {gateway}",
                ping_duoc(net.get(ten), gateway),
                True,
            )
        )

    ket_qua.append(
        ghi_ket_qua(
            "PC Office và PC IT liên lạc được trong VLAN 60",
            ping_duoc(office, "10.10.60.10"),
            True,
        )
    )

    # Kiểm tra cả hai chiều giữa mọi cặp dự án.
    for nguon in du_an:
        for dich in du_an:
            if nguon is dich:
                continue
            ket_qua.append(
                ghi_ket_qua(
                    f"{nguon.name} không truy cập được {dich.name}",
                    ping_duoc(nguon, dich.IP()),
                    False,
                )
            )

    # Dự án không được chủ động truy cập bất kỳ máy nào trong VLAN 60.
    for host in du_an:
        for dich in (it, office):
            ket_qua.append(
                ghi_ket_qua(
                    f"{host.name} không truy cập được {dich.name}",
                    ping_duoc(host, dich.IP()),
                    False,
                )
            )

    for host in du_an:
        ket_qua.append(
            ghi_ket_qua(
                f"PC Office không truy cập được {host.name}",
                ping_duoc(office, host.IP()),
                False,
            )
        )
        ket_qua.append(
            ghi_ket_qua(
                f"PC IT ping được {host.name}",
                ping_duoc(it, host.IP()),
                True,
            )
        )

    so_dat = sum(ket_qua)
    print(f"KẾT QUẢ GIAI ĐOẠN D: {so_dat}/{len(ket_qua)} kiểm thử đạt.")
    return so_dat == len(ket_qua)


def kiem_tra_giai_doan_e(net):
    """Kiểm tra truy cập và khả năng bật/tắt riêng CRM, CFONO."""
    print("\nKIỂM THỬ GIAI ĐOẠN E")
    ket_qua = []
    crm = net.get("srv_crm")
    cfono = net.get("srv_cfono")
    may_nguoi_dung = [
        net.get(f"pc_du_an_{so}") for so in range(1, 5)
    ] + [net.get("pc_office")]

    for host in may_nguoi_dung:
        ket_qua.append(
            ghi_ket_qua(
                f"{host.name} truy cập được CRM",
                doc_http(host, "172.16.100.10"),
                NOI_DUNG_CRM,
            )
        )
        ket_qua.append(
            ghi_ket_qua(
                f"{host.name} truy cập được CFONO",
                doc_http(host, "172.16.100.20"),
                NOI_DUNG_CFONO,
            )
        )

    ket_qua.append(
        ghi_ket_qua(
            "Dừng riêng CRM",
            chay_script_dich_vu(crm, "stop_crm.sh"),
            True,
        )
    )
    ket_qua.append(
        ghi_ket_qua(
            "CRM không còn truy cập được sau khi dừng",
            doc_http(net.get("pc_du_an_1"), "172.16.100.10"),
            "",
        )
    )
    ket_qua.append(
        ghi_ket_qua(
            "CFONO vẫn hoạt động khi CRM dừng",
            doc_http(net.get("pc_du_an_1"), "172.16.100.20"),
            NOI_DUNG_CFONO,
        )
    )
    ket_qua.append(
        ghi_ket_qua(
            "Gateway nội bộ vẫn hoạt động khi CRM dừng",
            ping_duoc(net.get("pc_office"), "10.10.60.1"),
            True,
        )
    )
    ket_qua.append(
        ghi_ket_qua(
            "Khởi động lại CRM",
            chay_script_dich_vu(crm, "start_crm.sh"),
            True,
        )
    )
    ket_qua.append(
        ghi_ket_qua(
            "CRM hoạt động lại",
            doc_http(net.get("pc_du_an_1"), "172.16.100.10"),
            NOI_DUNG_CRM,
        )
    )

    ket_qua.append(
        ghi_ket_qua(
            "Dừng riêng CFONO",
            chay_script_dich_vu(cfono, "stop_cfono.sh"),
            True,
        )
    )
    ket_qua.append(
        ghi_ket_qua(
            "CFONO không còn truy cập được sau khi dừng",
            doc_http(net.get("pc_du_an_1"), "172.16.100.20"),
            "",
        )
    )
    ket_qua.append(
        ghi_ket_qua(
            "CRM vẫn hoạt động khi CFONO dừng",
            doc_http(net.get("pc_du_an_1"), "172.16.100.10"),
            NOI_DUNG_CRM,
        )
    )
    ket_qua.append(
        ghi_ket_qua(
            "Gateway nội bộ vẫn hoạt động khi CFONO dừng",
            ping_duoc(net.get("pc_du_an_1"), "10.10.20.1"),
            True,
        )
    )
    ket_qua.append(
        ghi_ket_qua(
            "Khởi động lại CFONO",
            chay_script_dich_vu(cfono, "start_cfono.sh"),
            True,
        )
    )
    ket_qua.append(
        ghi_ket_qua(
            "CFONO hoạt động lại",
            doc_http(net.get("pc_du_an_1"), "172.16.100.20"),
            NOI_DUNG_CFONO,
        )
    )

    ket_qua.append(
        ghi_ket_qua(
            "Mạng ngoài không phá chính sách cô lập VLAN",
            kiem_tra_giai_doan_d(net),
            True,
        )
    )

    so_dat = sum(ket_qua)
    print(f"KẾT QUẢ GIAI ĐOẠN E: {so_dat}/{len(ket_qua)} kiểm thử đạt.")
    return so_dat == len(ket_qua)


def chay(kiem_thu_d=False, kiem_thu_e=False):
    """Khởi động topology; trả exit code theo kết quả kiểm thử."""
    if os.geteuid() != 0:
        print("[KHÔNG ĐẠT] Cần chạy chương trình bằng sudo.")
        return 2

    net = None
    da_khoi_dong_dich_vu = False
    try:
        subprocess.run(["modprobe", "8021q"], check=True)
        net = Mininet(
            topo=BPOTopology(),
            controller=None,
            switch=OVSSwitch,
            autoSetMacs=True,
            waitConnected=True,
        )
        print("Khởi động mạng Mininet...")
        net.start()
        cau_hinh_vlan(net)
        cau_hinh_router(net.get("r1"))

        if kiem_thu_d:
            return 0 if kiem_tra_giai_doan_d(net) else 1

        da_khoi_dong_dich_vu = True
        crm_ok = chay_script_dich_vu(net.get("srv_crm"), "start_crm.sh")
        cfono_ok = chay_script_dich_vu(
            net.get("srv_cfono"), "start_cfono.sh"
        )
        if not crm_ok or not cfono_ok:
            raise RuntimeError("Không thể khởi động dịch vụ CRM hoặc CFONO.")

        if kiem_thu_e:
            return 0 if kiem_tra_giai_doan_e(net) else 1

        print("Mạng và hai dịch vụ đối tác đã khởi động.")
        print("Gõ 'exit' để dừng mô hình.")
        CLI(net)
        return 0
    except Exception as loi:
        print(f"[KHÔNG ĐẠT] Không thể cấu hình topology: {loi}")
        return 2
    finally:
        if net is not None:
            if da_khoi_dong_dich_vu:
                chay_script_dich_vu(net.get("srv_crm"), "stop_crm.sh")
                chay_script_dich_vu(net.get("srv_cfono"), "stop_cfono.sh")
            print("Dừng mạng Mininet...")
            net.stop()


if __name__ == "__main__":
    thu_d = "--kiem-thu-d" in sys.argv
    thu_e = "--kiem-thu-e" in sys.argv
    if thu_d and thu_e:
        print("[KHÔNG ĐẠT] Chỉ được chọn một giai đoạn kiểm thử.")
        sys.exit(2)
    setLogLevel("warning" if thu_d or thu_e else "info")
    sys.exit(chay(kiem_thu_d=thu_d, kiem_thu_e=thu_e))
