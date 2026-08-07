#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""Xuất trạng thái BPO theo định dạng Prometheus."""

import json
import math
import os
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


DIA_CHI = "0.0.0.0"
CONG = 9105
FILE_TRANG_THAI = Path(__file__).resolve().parent.parent / "runtime/wan_status.json"
FILE_PID_DICH_VU = {"crm": Path("/tmp/bpo_crm.pid"), "cfono": Path("/tmp/bpo_cfono.pid")}
# wan_monitor chạy mỗi 2 giây; thiếu 5 chu kỳ liên tiếp thì trạng thái đã stale.
NGUONG_STALE_GIAY = 10


def la_so(gia_tri):
    return (
        isinstance(gia_tri, (int, float))
        and not isinstance(gia_tri, bool)
        and math.isfinite(gia_tri)
    )


def dong_metric(ten, gia_tri, nhan=None):
    chuoi_nhan = ""
    if nhan:
        chuoi_nhan = "{" + ",".join(
            f'{khoa}="{gia_tri_nhan}"' for khoa, gia_tri_nhan in nhan.items()
        ) + "}"
    return f"{ten}{chuoi_nhan} {gia_tri}"


def dich_vu_dang_chay(file_pid):
    """Dùng đúng PID runtime do script start/stop dịch vụ quản lý."""
    try:
        os.kill(int(file_pid.read_text(encoding="utf-8").strip()), 0)
        return True
    except PermissionError:
        return True
    except (OSError, ValueError):
        return False


def lay_timestamp_cap_nhat(trang_thai):
    """Đổi checked_at ISO 8601 hiện có thành Unix timestamp."""
    if not isinstance(trang_thai, dict) or not isinstance(trang_thai.get("checked_at"), str):
        return None
    try:
        thoi_diem = datetime.fromisoformat(trang_thai["checked_at"])
        if thoi_diem.tzinfo is None:
            return None
        return thoi_diem.timestamp()
    except ValueError:
        return None


def tao_metrics():
    """Chỉ xuất metric có dữ liệu thật trong file trạng thái."""
    cac_dong = [dong_metric("bpo_exporter_up", 1)]
    try:
        trang_thai = json.loads(FILE_TRANG_THAI.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as loi:
        print(f"[CẢNH BÁO] Không đọc được trạng thái WAN: {loi}", flush=True)
        cac_dong.extend([
            dong_metric("bpo_wan_status_read_success", 0),
            dong_metric("bpo_wan_monitor_up", 0),
        ])
        return "\n".join(cac_dong) + "\n"

    cac_dong.append(dong_metric("bpo_wan_status_read_success", 1))
    timestamp_cap_nhat = lay_timestamp_cap_nhat(trang_thai)
    if timestamp_cap_nhat is None:
        cac_dong.append(dong_metric("bpo_wan_monitor_up", 0))
    else:
        tuoi_thuc = time.time() - timestamp_cap_nhat
        cac_dong.extend([
            dong_metric("bpo_wan_status_age_seconds", round(max(0, tuoi_thuc), 3)),
            dong_metric(
                "bpo_wan_status_last_update_timestamp_seconds", timestamp_cap_nhat
            ),
            dong_metric(
                "bpo_wan_monitor_up",
                int(0 <= tuoi_thuc <= NGUONG_STALE_GIAY),
            ),
        ])

    if not isinstance(trang_thai, dict):
        trang_thai = {}

    for nha_mang in ("fpt", "viettel"):
        trang_thai_link = trang_thai.get(f"{nha_mang}_up")
        if isinstance(trang_thai_link, bool):
            cac_dong.append(dong_metric(
                "bpo_link_up", int(trang_thai_link), {"provider": nha_mang}
            ))

    duong_dang_dung = trang_thai.get("active_wan")
    if duong_dang_dung in ("fpt", "viettel", "none"):
        for nha_mang in ("fpt", "viettel"):
            cac_dong.append(dong_metric(
                "bpo_active_link", int(duong_dang_dung == nha_mang),
                {"provider": nha_mang},
            ))

    for khoa, ten_metric in (
        ("failover_duration_seconds", "bpo_failover_duration_seconds"),
        ("failback_duration_seconds", "bpo_failback_duration_seconds"),
    ):
        if la_so(trang_thai.get(khoa)):
            cac_dong.append(dong_metric(ten_metric, trang_thai[khoa]))

    for khoa, ten_metric in (
        ("latency_ms", "bpo_latency_ms"),
        ("packet_loss_percent", "bpo_packet_loss_percent"),
    ):
        du_lieu = trang_thai.get(khoa)
        if isinstance(du_lieu, dict):
            for nha_mang in ("fpt", "viettel"):
                if la_so(du_lieu.get(nha_mang)):
                    cac_dong.append(dong_metric(
                        ten_metric, du_lieu[nha_mang], {"provider": nha_mang}
                    ))

    for ten, file_pid in FILE_PID_DICH_VU.items():
        cac_dong.append(dong_metric(
            "bpo_service_up", int(dich_vu_dang_chay(file_pid)), {"service": ten}
        ))

    return "\n".join(cac_dong) + "\n"


class BoXuLy(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            self.tra_ve(200, tao_metrics(), "text/plain; version=0.0.4; charset=utf-8")
        elif self.path == "/health":
            self.tra_ve(200, "Bộ xuất số liệu BPO đang hoạt động\n")
        else:
            self.tra_ve(404, "Không tìm thấy endpoint\n")

    def tra_ve(self, ma, noi_dung, loai="text/plain; charset=utf-8"):
        du_lieu = noi_dung.encode("utf-8")
        self.send_response(ma)
        self.send_header("Content-Type", loai)
        self.send_header("Content-Length", str(len(du_lieu)))
        self.end_headers()
        self.wfile.write(du_lieu)

    def log_message(self, _dinh_dang, *_tham_so):
        return


def main():
    may_chu = ThreadingHTTPServer((DIA_CHI, CONG), BoXuLy)
    print(f"Bộ xuất số liệu đang lắng nghe tại {DIA_CHI}:{CONG}", flush=True)
    try:
        may_chu.serve_forever()
    except KeyboardInterrupt:
        print("Dừng bộ xuất số liệu.", flush=True)
    finally:
        may_chu.server_close()


if __name__ == "__main__":
    main()
