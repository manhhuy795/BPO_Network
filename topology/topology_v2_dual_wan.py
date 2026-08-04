#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""Topology Giai đoạn F/G: mạng D/E giữ nguyên và bổ sung Dual-WAN."""

import csv
import json
import os
import statistics
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

from mininet.cli import CLI
from mininet.log import setLogLevel
from mininet.net import Mininet
from mininet.node import OVSSwitch
from mininet.topo import Topo

from topology_v1 import (
    CAC_MAY,
    CAC_VLAN,
    LinuxRouter,
    NOI_DUNG_CFONO,
    NOI_DUNG_CRM,
    cau_hinh_vlan,
    chay_script_dich_vu,
    doc_http,
    ghi_ket_qua as ghi_ket_qua_goc,
    kiem_tra_giai_doan_d,
    ping_duoc,
)


THU_MUC_GOC = Path(__file__).resolve().parent.parent
FILE_TRANG_THAI = THU_MUC_GOC / "runtime/wan_status.json"
FILE_DO_LUONG = THU_MUC_GOC / "logs/wan_measurements.csv"
FILE_BAO_CAO = THU_MUC_GOC / "docs/phase_g_result.md"


class DualWanTopology(Topo):
    """Mạng nội bộ -> r1 -> FPT/Viettel -> Internet -> CRM/CFONO."""

    def build(self):
        r1 = self.addNode("r1", cls=LinuxRouter)
        isp_fpt = self.addNode("isp_fpt", cls=LinuxRouter)
        isp_viettel = self.addNode("isp_viettel", cls=LinuxRouter)
        r_internet = self.addNode("r_internet", cls=LinuxRouter)

        core = self.addSwitch(
            "s_core", cls=OVSSwitch, failMode="standalone",
            dpid="0000000000000001",
        )
        distribution = self.addSwitch(
            "s_dist", cls=OVSSwitch, failMode="standalone",
            dpid="0000000000000002",
        )
        outside = self.addSwitch(
            "s_outside", cls=OVSSwitch, failMode="standalone",
            dpid="0000000000000100",
        )
        access = {
            vlan: self.addSwitch(
                f"s_a{vlan}", cls=OVSSwitch, failMode="standalone",
                dpid=f"{vlan:016x}",
            )
            for vlan in CAC_VLAN
        }
        may = {
            ten: self.addHost(ten, ip=ip, defaultRoute=f"via {gateway}")
            for ten, (ip, gateway, _vlan) in CAC_MAY.items()
        }
        crm = self.addHost(
            "srv_crm", ip="172.16.100.10/24",
            defaultRoute="via 172.16.100.1",
        )
        cfono = self.addHost(
            "srv_cfono", ip="172.16.100.20/24",
            defaultRoute="via 172.16.100.1",
        )

        # Giữ nguyên chuỗi Core -> Distribution -> Access của D/E.
        self.addLink(r1, core)
        self.addLink(core, distribution)
        for vlan, switch in access.items():
            self.addLink(distribution, switch)
        for ten, host in may.items():
            self.addLink(access[CAC_MAY[ten][2]], host)

        # Thứ tự link cố định interface r1-eth1=FPT, r1-eth2=Viettel.
        self.addLink(r1, isp_fpt)
        self.addLink(r1, isp_viettel, intfName2="viettel-eth0")
        self.addLink(isp_fpt, r_internet)
        self.addLink(
            isp_viettel, r_internet, intfName1="viettel-eth1"
        )
        self.addLink(r_internet, outside)
        self.addLink(outside, crm)
        self.addLink(outside, cfono)


def cau_hinh_dual_wan(net):
    """Cấu hình VLAN, router doanh nghiệp, hai ISP và Internet chung."""
    cau_hinh_vlan(net)
    r1 = net.get("r1")
    fpt = net.get("isp_fpt")
    viettel = net.get("isp_viettel")
    internet = net.get("r_internet")

    r1.cmd("ip link set r1-eth0 up")
    for vlan, gateway in CAC_VLAN.items():
        giao_dien = f"r1-eth0.{vlan}"
        r1.cmd(
            f"ip link add link r1-eth0 name {giao_dien} type vlan id {vlan}"
        )
        r1.cmd(f"ip addr add {gateway} dev {giao_dien}")
        r1.cmd(f"ip link set {giao_dien} up")

    r1.cmd("ip addr add 100.64.10.1/30 dev r1-eth1")
    r1.cmd("ip addr add 100.64.20.1/30 dev r1-eth2")
    r1.cmd("ip link set r1-eth1 up")
    r1.cmd("ip link set r1-eth2 up")
    r1.cmd("ip route add 100.64.30.2/32 via 100.64.10.2 dev r1-eth1")
    r1.cmd("ip route add 100.64.40.2/32 via 100.64.20.2 dev r1-eth2")
    r1.cmd("ip route add 172.16.100.0/24 via 100.64.10.2 dev r1-eth1")

    fpt.cmd("ip addr add 100.64.10.2/30 dev isp_fpt-eth0")
    fpt.cmd("ip addr add 100.64.30.1/30 dev isp_fpt-eth1")
    fpt.cmd("ip route add 172.16.100.0/24 via 100.64.30.2")

    viettel.cmd("ip addr add 100.64.20.2/30 dev viettel-eth0")
    viettel.cmd("ip addr add 100.64.40.1/30 dev viettel-eth1")
    viettel.cmd("ip route add 172.16.100.0/24 via 100.64.40.2")

    internet.cmd("ip addr add 100.64.30.2/30 dev r_internet-eth0")
    internet.cmd("ip addr add 100.64.40.2/30 dev r_internet-eth1")
    internet.cmd("ip addr add 172.16.100.1/24 dev r_internet-eth2")
    internet.cmd("ip route add 100.64.10.0/30 via 100.64.30.1")
    internet.cmd("ip route add 100.64.20.0/30 via 100.64.40.1")

    r1.cmd("iptables -F")
    r1.cmd("iptables -t nat -F")
    r1.cmd("iptables -X")
    r1.cmd("iptables -P FORWARD DROP")
    r1.cmd(
        "iptables -A FORWARD "
        "-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
    )
    for vlan in (20, 30, 40, 50):
        r1.cmd(
            "iptables -A FORWARD "
            f"-s 10.10.60.10 -d 10.10.{vlan}.0/24 -p icmp -j ACCEPT"
        )
    r1.cmd(
        "iptables -A FORWARD -s 10.10.0.0/16 -d 172.16.100.0/24 "
        "-p tcp --dport 80 -j ACCEPT"
    )
    r1.cmd(
        "iptables -t nat -A POSTROUTING -s 10.10.0.0/16 "
        "-o r1-eth1 -j MASQUERADE"
    )
    r1.cmd(
        "iptables -t nat -A POSTROUTING -s 10.10.0.0/16 "
        "-o r1-eth2 -j MASQUERADE"
    )


def chay_script_wan(r1, ten_script):
    """Chạy script tác động link thật trong namespace r1."""
    ma_loi = r1.cmd(
        f"bash scripts/{ten_script} >/dev/null 2>&1; printf '%s' $?"
    ).strip()
    return ma_loi == "0"


def khoi_dong_giam_sat(r1):
    """Khởi động chương trình giám sát trong namespace router doanh nghiệp."""
    r1.cmd("rm -f runtime/wan_status.json /tmp/bpo_wan_monitor.pid")
    r1.cmd(
        "nohup python3 scripts/wan_monitor.py "
        ">/tmp/bpo_wan_monitor.log 2>&1 </dev/null & "
        "printf '%s\\n' $! >/tmp/bpo_wan_monitor.pid"
    )
    for _lan in range(20):
        ma_loi = r1.cmd(
            "kill -0 $(cat /tmp/bpo_wan_monitor.pid 2>/dev/null) "
            "2>/dev/null; printf '%s' $?"
        ).strip()
        if ma_loi.endswith("0") and FILE_TRANG_THAI.exists():
            return True
        time.sleep(0.1)
    return False


def dung_giam_sat(r1):
    """Dừng tiến trình giám sát nếu đang chạy."""
    r1.cmd(
        "if test -f /tmp/bpo_wan_monitor.pid; then "
        "kill $(cat /tmp/bpo_wan_monitor.pid) 2>/dev/null || true; fi; "
        "rm -f /tmp/bpo_wan_monitor.pid"
    )


def doc_trang_thai():
    """Đọc trạng thái WAN; trả dict rỗng nếu file chưa sẵn sàng."""
    try:
        return json.loads(FILE_TRANG_THAI.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def cho_duong_hoat_dong(duong, timeout):
    """Chờ active_wan đạt giá trị cần tìm và trả thời gian chờ."""
    bat_dau = time.monotonic()
    while time.monotonic() - bat_dau < timeout:
        if doc_trang_thai().get("active_wan") == duong:
            return round(time.monotonic() - bat_dau, 3)
        time.sleep(0.25)
    return None


def http_dung(host, dia_chi, noi_dung):
    """Kiểm tra nội dung HTTP chính xác."""
    return doc_http(host, dia_chi) == noi_dung


def ghi_ket_qua(ten, thuc_te, mong_doi):
    """In kết quả F/G và giải thích rõ khi điều kiện không đạt."""
    dat = ghi_ket_qua_goc(ten, thuc_te, mong_doi)
    if not dat:
        print(f"    Nguyên nhân: không đạt điều kiện “{ten}”.")
    return dat


def kiem_tra_dich_vu_doc_lap(net):
    """Kiểm tra CRM và CFONO vẫn dừng/mở riêng được như Giai đoạn E."""
    pc = net.get("pc_du_an_1")
    crm = net.get("srv_crm")
    cfono = net.get("srv_cfono")
    ket_qua = chay_script_dich_vu(crm, "stop_crm.sh")
    ket_qua &= http_dung(pc, "172.16.100.20", NOI_DUNG_CFONO)
    ket_qua &= chay_script_dich_vu(crm, "start_crm.sh")
    ket_qua &= chay_script_dich_vu(cfono, "stop_cfono.sh")
    ket_qua &= http_dung(pc, "172.16.100.10", NOI_DUNG_CRM)
    ket_qua &= chay_script_dich_vu(cfono, "start_cfono.sh")
    return bool(ket_qua)


def kiem_tra_giai_doan_f(net):
    """Chạy 10 nhóm kiểm thử chức năng Dual-WAN."""
    print("\nKIỂM THỬ GIAI ĐOẠN F")
    ket_qua = []
    r1 = net.get("r1")
    pc = net.get("pc_du_an_1")

    cho_duong_hoat_dong("fpt", 5)
    trang_thai = doc_trang_thai()
    ket_qua.append(ghi_ket_qua(
        "Cả hai WAN hoạt động và FPT là đường chính",
        trang_thai.get("fpt_up") and trang_thai.get("viettel_up")
        and trang_thai.get("active_wan") == "fpt",
        True,
    ))
    ket_qua.append(ghi_ket_qua(
        "Máy người dùng truy cập CRM và CFONO qua FPT",
        http_dung(pc, "172.16.100.10", NOI_DUNG_CRM)
        and http_dung(pc, "172.16.100.20", NOI_DUNG_CFONO),
        True,
    ))

    da_ngat_fpt = chay_script_wan(r1, "fpt_down.sh")
    thoi_gian_chuyen = cho_duong_hoat_dong("viettel", 10)
    ket_qua.append(ghi_ket_qua(
        "Ngắt FPT thì tự động chuyển sang Viettel",
        da_ngat_fpt and thoi_gian_chuyen is not None,
        True,
    ))
    ket_qua.append(ghi_ket_qua(
        "CRM và CFONO vẫn truy cập được qua Viettel",
        http_dung(pc, "172.16.100.10", NOI_DUNG_CRM)
        and http_dung(pc, "172.16.100.20", NOI_DUNG_CFONO),
        True,
    ))

    da_mo_fpt = chay_script_wan(r1, "fpt_up.sh")
    thoi_gian_ve = cho_duong_hoat_dong("fpt", 13)
    ket_qua.append(ghi_ket_qua(
        "FPT phục hồi ổn định 5 lần mới chuyển về đường chính",
        da_mo_fpt and thoi_gian_ve is not None
        and doc_trang_thai().get("fpt_recovery_count", 0) >= 5,
        True,
    ))

    da_ngat_viettel = chay_script_wan(r1, "viettel_down.sh")
    time.sleep(2.5)
    ket_qua.append(ghi_ket_qua(
        "Ngắt Viettel khi FPT hoạt động không làm mất dịch vụ",
        da_ngat_viettel and doc_trang_thai().get("active_wan") == "fpt"
        and http_dung(pc, "172.16.100.10", NOI_DUNG_CRM),
        True,
    ))

    chay_script_wan(r1, "fpt_down.sh")
    mat_ca_hai = cho_duong_hoat_dong("none", 10)
    ket_qua.append(ghi_ket_qua(
        "Cả FPT và Viettel mất thì không truy cập được CRM/CFONO",
        mat_ca_hai is not None
        and doc_http(pc, "172.16.100.10") == ""
        and doc_http(pc, "172.16.100.20") == "",
        True,
    ))
    ket_qua.append(ghi_ket_qua(
        "Hai WAN mất nhưng gateway VLAN vẫn hoạt động",
        ping_duoc(pc, "10.10.20.1"),
        True,
    ))

    chay_script_wan(r1, "viettel_up.sh")
    chay_script_wan(r1, "fpt_up.sh")
    cho_duong_hoat_dong("fpt", 15)
    ket_qua.append(ghi_ket_qua(
        "Dual-WAN không phá chính sách cô lập VLAN",
        kiem_tra_giai_doan_d(net),
        True,
    ))
    ket_qua.append(ghi_ket_qua(
        "CRM và CFONO vẫn có thể dừng riêng",
        kiem_tra_dich_vu_doc_lap(net),
        True,
    ))

    so_dat = sum(ket_qua)
    print(f"KẾT QUẢ GIAI ĐOẠN F: {so_dat}/{len(ket_qua)} nhóm kiểm thử đạt.")
    return so_dat == len(ket_qua)


def ghi_bao_cao_g(cac_lan):
    """Tạo báo cáo Markdown từ số liệu đo thật."""
    cac_lan_dat = [lan for lan in cac_lan if lan[3] == "ĐẠT"]
    failover = [lan[1] for lan in cac_lan_dat]
    failback = [lan[2] for lan in cac_lan_dat]
    FILE_BAO_CAO.parent.mkdir(parents=True, exist_ok=True)
    dong = [
        "# Kết quả đo chuyển đường Giai đoạn G",
        "",
        f"Thời điểm tạo: {datetime.now().astimezone().isoformat(timespec='seconds')}",
        "",
        f"- Số lần đạt: {len(cac_lan_dat)}",
        f"- Số lần không đạt: {len(cac_lan) - len(cac_lan_dat)}",
    ]
    if cac_lan_dat:
        dong += [
            f"- Failover nhỏ nhất/lớn nhất/trung bình: "
            f"{min(failover):.3f}/{max(failover):.3f}/{statistics.mean(failover):.3f} giây",
            f"- Failback nhỏ nhất/lớn nhất/trung bình: "
            f"{min(failback):.3f}/{max(failback):.3f}/{statistics.mean(failback):.3f} giây",
        ]
    dong += [
        "",
        "| Lần | Failover (giây) | Failback (giây) | Kết quả | Ghi chú |",
        "|---:|---:|---:|---|---|",
    ]
    for lan, failover_giay, failback_giay, ket_qua, ghi_chu in cac_lan:
        failover_text = "" if failover_giay is None else f"{failover_giay:.3f}"
        failback_text = "" if failback_giay is None else f"{failback_giay:.3f}"
        dong.append(
            f"| {lan} | {failover_text} | {failback_text} | "
            f"{ket_qua} | {ghi_chu} |"
        )
    FILE_BAO_CAO.write_text("\n".join(dong) + "\n", encoding="utf-8")


def kiem_tra_giai_doan_g(net):
    """Đo thật 5 chu kỳ failover/failback và ghi CSV."""
    print("\nĐO THỜI GIAN CHUYỂN ĐƯỜNG - GIAI ĐOẠN G")
    r1 = net.get("r1")
    cac_lan = []
    FILE_DO_LUONG.parent.mkdir(parents=True, exist_ok=True)

    for lan in range(1, 6):
        chay_script_wan(r1, "viettel_up.sh")
        chay_script_wan(r1, "fpt_up.sh")
        cho_duong_hoat_dong("fpt", 15)

        chay_script_wan(r1, "fpt_down.sh")
        failover = cho_duong_hoat_dong("viettel", 10)

        chay_script_wan(r1, "fpt_up.sh")
        da_ve_fpt = cho_duong_hoat_dong("fpt", 13)
        trang_thai = doc_trang_thai()
        failback = trang_thai.get("failback_duration_seconds")

        if failover is None or da_ve_fpt is None or failback is None:
            failover_giay = failover
            failback_giay = failback
            ket_qua = "KHÔNG ĐẠT"
            ghi_chu = "Không quan sát được đủ một chu kỳ chuyển đường"
        else:
            failover_giay = failover
            failback_giay = float(failback)
            ket_qua = "ĐẠT"
            ghi_chu = "Đo từ sự kiện thật trong Mininet"
        cac_lan.append((lan, failover_giay, failback_giay, ket_qua, ghi_chu))
        ghi_ket_qua(f"Lần đo {lan}", ket_qua, "ĐẠT")

        with FILE_DO_LUONG.open("w", newline="", encoding="utf-8") as tep:
            ghi = csv.writer(tep)
            ghi.writerow([
                "lan_thu", "thoi_gian_failover_giay",
                "thoi_gian_failback_giay", "ket_qua", "ghi_chu",
            ])
            ghi.writerows(cac_lan)

    ghi_bao_cao_g(cac_lan)
    so_dat = sum(lan[3] == "ĐẠT" for lan in cac_lan)
    print(f"KẾT QUẢ GIAI ĐOẠN G: {so_dat}/5 lần đo đạt.")
    return so_dat == 5


def chay(thu_f=False, thu_g=False):
    """Khởi động topology Dual-WAN và chế độ kiểm thử được chọn."""
    if os.geteuid() != 0:
        print("[KHÔNG ĐẠT] Cần chạy chương trình bằng sudo.")
        return 2

    net = None
    da_khoi_dong_dich_vu = False
    da_khoi_dong_giam_sat = False
    try:
        subprocess.run(["modprobe", "8021q"], check=True)
        net = Mininet(
            topo=DualWanTopology(), controller=None, switch=OVSSwitch,
            autoSetMacs=True, waitConnected=True,
        )
        print("Khởi động topology Dual-WAN...")
        net.start()
        cau_hinh_dual_wan(net)

        da_khoi_dong_dich_vu = True
        crm_ok = chay_script_dich_vu(net.get("srv_crm"), "start_crm.sh")
        cfono_ok = chay_script_dich_vu(
            net.get("srv_cfono"), "start_cfono.sh"
        )
        if not crm_ok or not cfono_ok:
            raise RuntimeError("Không thể khởi động CRM hoặc CFONO.")

        da_khoi_dong_giam_sat = khoi_dong_giam_sat(net.get("r1"))
        if not da_khoi_dong_giam_sat:
            raise RuntimeError("Không thể khởi động chương trình giám sát WAN.")
        if cho_duong_hoat_dong("fpt", 5) is None:
            raise RuntimeError("Trạng thái WAN ban đầu chưa sẵn sàng.")

        if thu_f:
            return 0 if kiem_tra_giai_doan_f(net) else 1
        if thu_g:
            return 0 if kiem_tra_giai_doan_g(net) else 1

        print("Dual-WAN đã khởi động; FPT là đường chính.")
        print("Dùng r1 bash scripts/fpt_down.sh để mô phỏng lỗi.")
        print("Gõ 'exit' để dừng mô hình.")
        CLI(net)
        return 0
    except Exception as loi:
        print(f"[KHÔNG ĐẠT] Không thể vận hành Dual-WAN: {loi}")
        return 2
    finally:
        if net is not None:
            r1 = net.get("r1")
            if da_khoi_dong_giam_sat:
                dung_giam_sat(r1)
            r1.cmd("ip link set r1-eth1 up 2>/dev/null || true")
            r1.cmd("ip link set r1-eth2 up 2>/dev/null || true")
            if da_khoi_dong_dich_vu:
                chay_script_dich_vu(net.get("srv_crm"), "stop_crm.sh")
                chay_script_dich_vu(net.get("srv_cfono"), "stop_cfono.sh")
            print("Dừng topology Dual-WAN...")
            net.stop()


if __name__ == "__main__":
    kiem_thu_f = "--kiem-thu-f" in sys.argv
    kiem_thu_g = "--kiem-thu-g" in sys.argv
    if kiem_thu_f and kiem_thu_g:
        print("[KHÔNG ĐẠT] Chỉ được chọn một giai đoạn kiểm thử.")
        raise SystemExit(2)
    setLogLevel("warning" if kiem_thu_f or kiem_thu_g else "info")
    raise SystemExit(chay(thu_f=kiem_thu_f, thu_g=kiem_thu_g))
