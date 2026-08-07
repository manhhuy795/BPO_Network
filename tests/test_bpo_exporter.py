import json
import time
from datetime import datetime, timezone

import pytest

from metrics import bpo_exporter


def doc_metrics(file_trang_thai, noi_dung=None):
    if noi_dung is not None:
        file_trang_thai.write_text(noi_dung, encoding="utf-8")
    bpo_exporter.FILE_TRANG_THAI = file_trang_thai
    return {
        dong.rsplit(" ", 1)[0]: float(dong.rsplit(" ", 1)[1])
        for dong in bpo_exporter.tao_metrics().splitlines()
    }


def trang_thai_voi_timestamp(timestamp):
    return json.dumps({
        "checked_at": datetime.fromtimestamp(timestamp, timezone.utc).isoformat()
    })


def test_json_hop_le_va_con_moi_bao_monitor_hoat_dong(tmp_path):
    timestamp = time.time() - 1
    metrics = doc_metrics(tmp_path / "wan_status.json", trang_thai_voi_timestamp(timestamp))

    assert metrics["bpo_exporter_up"] == 1
    assert metrics["bpo_wan_status_read_success"] == 1
    assert metrics["bpo_wan_monitor_up"] == 1
    assert 0 <= metrics["bpo_wan_status_age_seconds"] < 10
    assert metrics["bpo_wan_status_last_update_timestamp_seconds"] == pytest.approx(timestamp)


def test_file_khong_ton_tai_bao_doc_that_bai(tmp_path):
    metrics = doc_metrics(tmp_path / "wan_status.json")

    assert metrics["bpo_exporter_up"] == 1
    assert metrics["bpo_wan_status_read_success"] == 0
    assert metrics["bpo_wan_monitor_up"] == 0
    assert "bpo_wan_status_age_seconds" not in metrics
    assert "bpo_wan_status_last_update_timestamp_seconds" not in metrics


def test_json_sai_dinh_dang_bao_doc_that_bai(tmp_path):
    metrics = doc_metrics(tmp_path / "wan_status.json", "{json sai")

    assert metrics["bpo_wan_status_read_success"] == 0
    assert metrics["bpo_wan_monitor_up"] == 0
    assert "bpo_wan_status_age_seconds" not in metrics


def test_thieu_timestamp_bao_monitor_khong_hoat_dong(tmp_path):
    metrics = doc_metrics(tmp_path / "wan_status.json", "{}")

    assert metrics["bpo_wan_status_read_success"] == 1
    assert metrics["bpo_wan_monitor_up"] == 0
    assert "bpo_wan_status_age_seconds" not in metrics
    assert "bpo_wan_status_last_update_timestamp_seconds" not in metrics


def test_timestamp_qua_cu_bao_monitor_khong_hoat_dong(tmp_path):
    timestamp = time.time() - 11
    metrics = doc_metrics(tmp_path / "wan_status.json", trang_thai_voi_timestamp(timestamp))

    assert metrics["bpo_wan_status_read_success"] == 1
    assert metrics["bpo_wan_monitor_up"] == 0
    assert metrics["bpo_wan_status_age_seconds"] >= 10
    assert metrics["bpo_wan_status_last_update_timestamp_seconds"] == pytest.approx(timestamp)


def test_timestamp_trong_tuong_lai_bao_monitor_khong_hoat_dong(tmp_path):
    timestamp = time.time() + 60
    metrics = doc_metrics(tmp_path / "wan_status.json", trang_thai_voi_timestamp(timestamp))

    assert metrics["bpo_wan_status_read_success"] == 1
    assert metrics["bpo_wan_monitor_up"] == 0
    assert metrics["bpo_wan_status_age_seconds"] == 0
    assert metrics["bpo_wan_status_last_update_timestamp_seconds"] == pytest.approx(timestamp)


def test_xuat_day_du_thong_ke_rtt_va_mat_goi(tmp_path):
    timestamp = time.time() - 1
    trang_thai = {
        "checked_at": datetime.fromtimestamp(timestamp, timezone.utc).isoformat(),
        "ping_rtt_ms": {
            "fpt": {"min": 10.1, "avg": 12.5, "max": 15.8, "mdev": 1.7},
            "viettel": None,
        },
        "packet_loss_percent": {"fpt": 20.0, "viettel": 100.0},
    }
    metrics = doc_metrics(tmp_path / "wan_status.json", json.dumps(trang_thai))

    assert metrics['bpo_ping_rtt_min_ms{provider="fpt"}'] == 10.1
    assert metrics['bpo_ping_rtt_avg_ms{provider="fpt"}'] == 12.5
    assert metrics['bpo_ping_rtt_max_ms{provider="fpt"}'] == 15.8
    assert metrics['bpo_ping_rtt_mdev_ms{provider="fpt"}'] == 1.7
    assert metrics['bpo_packet_loss_percent{provider="fpt"}'] == 20.0
    assert 'bpo_ping_rtt_avg_ms{provider="viettel"}' not in metrics
