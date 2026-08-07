#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""Giám sát FPT/Viettel và đổi route dịch vụ khi trạng thái thay đổi."""

import json
import os
import re
import signal
import subprocess
import time
from datetime import datetime
from pathlib import Path


CHU_KY_GIAY = 2
SO_LAN_FPT_MAT = 3
SO_LAN_FPT_ON_DINH = 5
SO_LAN_VIETTEL_MAT = 3
MANG_DICH_VU = "172.16.100.0/24"
FILE_TRANG_THAI = Path(__file__).resolve().parent.parent / "runtime/wan_status.json"
DANG_CHAY = True


def thoi_gian_hien_tai():
    """Trả thời gian địa phương theo ISO 8601."""
    return datetime.now().astimezone().isoformat(timespec="seconds")


def phan_tich_ping(noi_dung):
    """Đọc reachability, packet loss và dòng thống kê RTT của ping."""
    so = r"\d+(?:\.\d+)?"
    khop_mat_goi = re.search(rf"({so})%\s+packet loss", noi_dung)
    if not khop_mat_goi:
        raise ValueError("Không tìm thấy thống kê packet loss.")

    mat_goi = float(khop_mat_goi.group(1))
    if not 0 <= mat_goi <= 100:
        raise ValueError("Giá trị packet loss nằm ngoài khoảng 0-100%.")

    if mat_goi == 100:
        rtt = None
    else:
        khop_rtt = re.search(
            rf"^rtt min/avg/max/mdev\s*=\s*"
            rf"({so})/({so})/({so})/({so})\s+ms"
            rf"(?:,\s+pipe\s+\d+)?$",
            noi_dung,
            re.MULTILINE,
        )
        if not khop_rtt:
            raise ValueError("Không tìm thấy dòng thống kê RTT min/avg/max/mdev.")
        rtt = dict(zip(
            ("min", "avg", "max", "mdev"),
            map(float, khop_rtt.groups()),
        ))

    return {
        "reachable": mat_goi < 100,
        "packet_loss_percent": mat_goi,
        "rtt_ms": rtt,
    }


def do_duong(giao_dien, dia_chi):
    """Chạy ping và trả kết quả đo; lỗi không làm dừng monitor."""
    try:
        ket_qua = subprocess.run(
            # Đo nhiều gói để phân biệt suy giảm chất lượng với mất hẳn đường truyền.
            [
                "ping", "-I", giao_dien, "-c", "100", "-i", "0.01",
                "-W", "1", dia_chi,
            ],
            capture_output=True,
            text=True,
            env={**os.environ, "LC_ALL": "C"},
            check=False,
        )
    except OSError as loi:
        thong_bao = f"Không chạy được ping trên {giao_dien}: {loi}"
        print(f"[CẢNH BÁO] {thong_bao}", flush=True)
        return {
            "reachable": False, "packet_loss_percent": None,
            "rtt_ms": None, "error": thong_bao,
        }

    noi_dung = f"{ket_qua.stdout}\n{ket_qua.stderr}"
    try:
        do_duoc = phan_tich_ping(noi_dung)
        do_duoc["error"] = None
        return do_duoc
    except ValueError as loi:
        thong_bao = f"Output ping trên {giao_dien} không hợp lệ: {loi}"
        print(f"[CẢNH BÁO] {thong_bao}", flush=True)
        return {
            "reachable": False, "packet_loss_percent": None,
            "rtt_ms": None, "error": thong_bao,
        }


def dat_route(duong):
    """Đổi route dịch vụ; chỉ được gọi khi trạng thái WAN thay đổi."""
    if duong == "fpt":
        lenh = [
            "ip", "route", "replace", MANG_DICH_VU,
            "via", "100.64.10.2", "dev", "r1-eth1",
        ]
    elif duong == "viettel":
        lenh = [
            "ip", "route", "replace", MANG_DICH_VU,
            "via", "100.64.20.2", "dev", "r1-eth2",
        ]
    else:
        subprocess.run(
            ["ip", "route", "del", MANG_DICH_VU],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return
    subprocess.run(lenh, check=True)


def ghi_trang_thai(trang_thai):
    """Ghi JSON nguyên tử để tiến trình khác không đọc file dang dở."""
    FILE_TRANG_THAI.parent.mkdir(parents=True, exist_ok=True)
    file_tam = FILE_TRANG_THAI.with_suffix(".tmp")
    file_tam.write_text(
        json.dumps(trang_thai, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    os.replace(file_tam, FILE_TRANG_THAI)


def dung_chuong_trinh(_tin_hieu, _khung):
    """Dừng vòng lặp khi nhận SIGTERM hoặc SIGINT."""
    global DANG_CHAY
    DANG_CHAY = False


def doi_duong(trang_thai, duong_moi, ly_do):
    """Đổi route và ghi nhận thời điểm chỉ khi đường thực sự thay đổi."""
    if trang_thai["active_wan"] == duong_moi:
        return
    dat_route(duong_moi)
    trang_thai["active_wan"] = duong_moi
    trang_thai["last_change"] = thoi_gian_hien_tai()
    ten_duong = {"fpt": "FPT", "viettel": "Viettel", "none": "không có"}
    print(
        f"{trang_thai['last_change']} | Chuyển sang {ten_duong[duong_moi]}: {ly_do}",
        flush=True,
    )


def main():
    """Chạy máy trạng thái chuyển đường với ngưỡng chống chập chờn."""
    if os.geteuid() != 0:
        print("[KHÔNG ĐẠT] Chương trình giám sát cần chạy bằng sudo.")
        return 2

    signal.signal(signal.SIGTERM, dung_chuong_trinh)
    signal.signal(signal.SIGINT, dung_chuong_trinh)

    bat_dau = thoi_gian_hien_tai()
    trang_thai = {
        "checked_at": bat_dau,
        "fpt_up": True,
        "viettel_up": True,
        "active_wan": "fpt",
        "last_change": bat_dau,
        "incident_started_at": None,
        "failover_at": None,
        "fpt_recovered_at": None,
        "failback_at": None,
        "failover_duration_seconds": None,
        "failback_duration_seconds": None,
        "ping_rtt_ms": {"fpt": None, "viettel": None},
        "packet_loss_percent": {"fpt": None, "viettel": None},
        "ping_error": {"fpt": None, "viettel": None},
        "fpt_failure_count": 0,
        "fpt_recovery_count": 0,
        "viettel_failure_count": 0,
    }
    so_lan_fpt_mat = 0
    so_lan_fpt_tot = 0
    so_lan_viettel_mat = 0
    bat_dau_su_co = None
    bat_dau_phuc_hoi = None
    ghi_trang_thai(trang_thai)

    while DANG_CHAY:
        moc_do = time.monotonic()
        luc_kiem_tra = thoi_gian_hien_tai()
        ket_qua_fpt = do_duong("r1-eth1", "100.64.30.2")
        ket_qua_viettel = do_duong(
            "r1-eth2", "100.64.40.2"
        )
        fpt_tot = ket_qua_fpt["reachable"]
        viettel_tot = ket_qua_viettel["reachable"]
        dang_dung = trang_thai["active_wan"]

        if dang_dung == "fpt":
            so_lan_fpt_tot = 0
            bat_dau_phuc_hoi = None
            if fpt_tot:
                so_lan_fpt_mat = 0
                bat_dau_su_co = None
            else:
                if so_lan_fpt_mat == 0:
                    bat_dau_su_co = moc_do
                    trang_thai["incident_started_at"] = luc_kiem_tra
                    print(f"{luc_kiem_tra} | Bắt đầu phát hiện sự cố FPT", flush=True)
                so_lan_fpt_mat += 1
                if so_lan_fpt_mat >= SO_LAN_FPT_MAT:
                    if viettel_tot:
                        doi_duong(trang_thai, "viettel", "FPT mất 3 lần liên tiếp")
                        trang_thai["failover_at"] = luc_kiem_tra
                        trang_thai["failover_duration_seconds"] = round(
                            moc_do - bat_dau_su_co, 3
                        )
                    else:
                        doi_duong(trang_thai, "none", "Cả hai đường đều mất")

        elif dang_dung == "viettel":
            if fpt_tot:
                if so_lan_fpt_tot == 0:
                    bat_dau_phuc_hoi = moc_do
                    trang_thai["fpt_recovered_at"] = luc_kiem_tra
                    print(f"{luc_kiem_tra} | FPT bắt đầu phục hồi", flush=True)
                so_lan_fpt_tot += 1
                if so_lan_fpt_tot >= SO_LAN_FPT_ON_DINH:
                    doi_duong(trang_thai, "fpt", "FPT ổn định 5 lần liên tiếp")
                    trang_thai["failback_at"] = luc_kiem_tra
                    trang_thai["failback_duration_seconds"] = round(
                        moc_do - bat_dau_phuc_hoi, 3
                    )
                    so_lan_fpt_mat = 0
            else:
                so_lan_fpt_tot = 0
                bat_dau_phuc_hoi = None

            if viettel_tot:
                so_lan_viettel_mat = 0
            else:
                so_lan_viettel_mat += 1
                if (
                    so_lan_viettel_mat >= SO_LAN_VIETTEL_MAT
                    and trang_thai["active_wan"] == "viettel"
                ):
                    doi_duong(trang_thai, "none", "Viettel mất khi FPT chưa ổn định")

        else:
            if fpt_tot:
                if so_lan_fpt_tot == 0:
                    bat_dau_phuc_hoi = moc_do
                    trang_thai["fpt_recovered_at"] = luc_kiem_tra
                so_lan_fpt_tot += 1
            else:
                so_lan_fpt_tot = 0
                bat_dau_phuc_hoi = None

            if viettel_tot:
                doi_duong(trang_thai, "viettel", "Viettel đã có kết nối")
                so_lan_viettel_mat = 0
            elif so_lan_fpt_tot >= SO_LAN_FPT_ON_DINH:
                doi_duong(trang_thai, "fpt", "FPT ổn định 5 lần liên tiếp")
                trang_thai["failback_at"] = luc_kiem_tra
                trang_thai["failback_duration_seconds"] = round(
                    moc_do - bat_dau_phuc_hoi, 3
                )

        trang_thai.update(
            {
                "checked_at": luc_kiem_tra,
                "fpt_up": fpt_tot,
                "viettel_up": viettel_tot,
                "ping_rtt_ms": {
                    "fpt": ket_qua_fpt["rtt_ms"],
                    "viettel": ket_qua_viettel["rtt_ms"],
                },
                "packet_loss_percent": {
                    "fpt": ket_qua_fpt["packet_loss_percent"],
                    "viettel": ket_qua_viettel["packet_loss_percent"],
                },
                "ping_error": {
                    "fpt": ket_qua_fpt["error"],
                    "viettel": ket_qua_viettel["error"],
                },
                "fpt_failure_count": so_lan_fpt_mat,
                "fpt_recovery_count": so_lan_fpt_tot,
                "viettel_failure_count": so_lan_viettel_mat,
            }
        )
        ten_active = {
            "fpt": "FPT", "viettel": "Viettel", "none": "không có"
        }[trang_thai["active_wan"]]
        print(
            f"{luc_kiem_tra} | FPT: {'hoạt động' if fpt_tot else 'mất'} | "
            f"Viettel: {'hoạt động' if viettel_tot else 'mất'} | "
            f"Đường đang dùng: {ten_active}",
            flush=True,
        )
        ghi_trang_thai(trang_thai)
        # Giữ khoảng cách giữa hai lần bắt đầu kiểm tra đúng 2 giây.
        thoi_gian_con_lai = CHU_KY_GIAY - (time.monotonic() - moc_do)
        if thoi_gian_con_lai > 0:
            time.sleep(thoi_gian_con_lai)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
