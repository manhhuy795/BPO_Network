import pytest

from scripts import wan_monitor


def ket_qua_ping(mat_goi, rtt="10.1/12.5/15.8/1.7"):
    dong_rtt = "" if rtt is None else f"rtt min/avg/max/mdev = {rtt} ms\n"
    return (
        "PING 100.64.30.2 (100.64.30.2) 56(84) bytes of data.\n"
        "64 bytes from 100.64.30.2: icmp_seq=1 ttl=63 time=8.000 ms\n\n"
        "--- 100.64.30.2 ping statistics ---\n"
        f"100 packets transmitted, {100 - mat_goi} received, {mat_goi}% packet loss\n"
        f"{dong_rtt}"
    )


def test_ping_thanh_cong_voi_khong_phan_tram_mat_goi():
    ket_qua = wan_monitor.phan_tich_ping(ket_qua_ping(0))

    assert ket_qua == {
        "reachable": True,
        "packet_loss_percent": 0.0,
        "rtt_ms": {"min": 10.1, "avg": 12.5, "max": 15.8, "mdev": 1.7},
    }


def test_ping_mat_goi_mot_phan_van_con_ket_noi():
    ket_qua = wan_monitor.phan_tich_ping(ket_qua_ping(20))

    assert ket_qua["reachable"] is True
    assert ket_qua["packet_loss_percent"] == 20.0
    assert ket_qua["rtt_ms"]["avg"] == 12.5


def test_ping_mat_100_phan_tram_khong_co_rtt():
    ket_qua = wan_monitor.phan_tich_ping(ket_qua_ping(100, None))

    assert ket_qua == {
        "reachable": False,
        "packet_loss_percent": 100.0,
        "rtt_ms": None,
    }


def test_output_thieu_dong_rtt_bao_loi():
    with pytest.raises(ValueError, match="RTT"):
        wan_monitor.phan_tich_ping(ket_qua_ping(0, None))


def test_output_sai_dinh_dang_bao_loi():
    with pytest.raises(ValueError, match="packet loss"):
        wan_monitor.phan_tich_ping("output ping không hợp lệ")


def test_parser_giu_chinh_xac_rtt_so_thap_phan():
    ket_qua = wan_monitor.phan_tich_ping(
        ket_qua_ping(0, "0.123/1.234/2.345/0.456")
    )

    assert ket_qua["rtt_ms"] == {
        "min": 0.123,
        "avg": 1.234,
        "max": 2.345,
        "mdev": 0.456,
    }


def test_parser_khong_lay_time_cua_packet_dau_tien():
    ket_qua = wan_monitor.phan_tich_ping(ket_qua_ping(0, "10/15/20/2"))

    assert ket_qua["rtt_ms"]["avg"] == 15.0
    assert ket_qua["rtt_ms"]["avg"] != 8.0


def test_parser_chap_nhan_hau_to_pipe_cua_ping_linux():
    output = ket_qua_ping(0, "180.064/180.148/180.373/0.073").replace(
        " ms\n", " ms, pipe 17\n"
    )

    assert wan_monitor.phan_tich_ping(output)["rtt_ms"]["avg"] == 180.148


@pytest.mark.parametrize(
    ("mat_goi", "reachable"),
    [(0, True), (20, True), (80, True), (99, True), (100, False)],
)
def test_failover_chi_coi_wan_down_khi_mat_100_phan_tram(mat_goi, reachable):
    rtt = None if mat_goi == 100 else "1/2/3/0.5"

    assert wan_monitor.phan_tich_ping(ket_qua_ping(mat_goi, rtt))["reachable"] is reachable
