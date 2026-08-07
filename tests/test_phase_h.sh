#!/usr/bin/env bash

set -uo pipefail

THU_MUC_GOC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE_LOG="$THU_MUC_GOC/logs/phase_h_test.log"
FILE_METRICS="/tmp/bpo_phase_h_metrics.txt"
FILE_EXPORTER_LOG="/tmp/bpo_phase_h_exporter.log"
SO_LOI=0
PID_EXPORTER=""

mkdir -p "$THU_MUC_GOC/logs"
exec > >(tee "$FILE_LOG") 2>&1

don_dep() {
    if [[ -n "$PID_EXPORTER" ]]; then
        kill "$PID_EXPORTER" 2>/dev/null || true
        wait "$PID_EXPORTER" 2>/dev/null || true
    fi
    rm -f "$FILE_METRICS" "$FILE_EXPORTER_LOG"
}
trap don_dep EXIT

bao_cao() {
    if "$@"; then
        printf '[ĐẠT] %s\n' "$MO_TA"
    else
        printf '[KHÔNG ĐẠT] %s\n' "$MO_TA"
        SO_LOI=$((SO_LOI + 1))
    fi
}

cd "$THU_MUC_GOC" || exit 2
printf 'KIỂM THỬ GIAI ĐOẠN H\n'

python3 metrics/bpo_exporter.py >"$FILE_EXPORTER_LOG" 2>&1 &
PID_EXPORTER=$!

SAN_SANG=0
for _ in {1..20}; do
    if python3 - <<'PY' >/dev/null 2>&1
import urllib.request
with urllib.request.urlopen("http://127.0.0.1:9105/health", timeout=1) as phan_hoi:
    raise SystemExit(0 if phan_hoi.status == 200 else 1)
PY
    then
        SAN_SANG=1
        break
    fi
    sleep 0.25
done

MO_TA="Endpoint /health trả HTTP 200"
bao_cao test "$SAN_SANG" -eq 1

NOI_DUNG_HEALTH="$(python3 - <<'PY' 2>/dev/null || true
import urllib.request
print(urllib.request.urlopen("http://127.0.0.1:9105/health", timeout=2).read().decode())
PY
)"
MO_TA="Endpoint /health trả nội dung tiếng Việt"
bao_cao grep -q "đang hoạt động" <<<"$NOI_DUNG_HEALTH"

python3 - <<'PY' >"$FILE_METRICS" 2>/dev/null || true
import urllib.request
print(urllib.request.urlopen("http://127.0.0.1:9105/metrics", timeout=2).read().decode(), end="")
PY
MO_TA="Endpoint /metrics báo exporter hoạt động"
bao_cao grep -qx "bpo_exporter_up 1" "$FILE_METRICS"

MO_TA="Các metric khớp dữ liệu thật trong wan_status.json"
bao_cao python3 - "$THU_MUC_GOC/runtime/wan_status.json" "$FILE_METRICS" <<'PY'
import json
import math
import os
import sys

with open(sys.argv[1], encoding="utf-8") as tep:
    trang_thai = json.load(tep)
with open(sys.argv[2], encoding="utf-8") as tep:
    metrics = set(tep.read().splitlines())

mong_doi = set()
for nha_mang in ("fpt", "viettel"):
    mong_doi.add(f'bpo_link_up{{provider="{nha_mang}"}} {int(trang_thai[f"{nha_mang}_up"])}')
    mong_doi.add(f'bpo_active_link{{provider="{nha_mang}"}} {int(trang_thai["active_wan"] == nha_mang)}')
    rtt = trang_thai["ping_rtt_ms"][nha_mang]
    if isinstance(rtt, dict):
        for khoa in ("min", "avg", "max", "mdev"):
            mong_doi.add(f'bpo_ping_rtt_{khoa}_ms{{provider="{nha_mang}"}} {rtt[khoa]}')
    mat_goi = trang_thai["packet_loss_percent"][nha_mang]
    if isinstance(mat_goi, (int, float)) and math.isfinite(mat_goi):
        mong_doi.add(f'bpo_packet_loss_percent{{provider="{nha_mang}"}} {mat_goi}')
for dich_vu in ("crm", "cfono"):
    file_pid = f"/tmp/bpo_{dich_vu}.pid"
    try:
        with open(file_pid, encoding="utf-8") as tep:
            os.kill(int(tep.read().strip()), 0)
        dang_chay = 1
    except PermissionError:
        dang_chay = 1
    except (OSError, ValueError):
        dang_chay = 0
    mong_doi.add(f'bpo_service_up{{service="{dich_vu}"}} {dang_chay}')
for khoa, ten in (
    ("failover_duration_seconds", "bpo_failover_duration_seconds"),
    ("failback_duration_seconds", "bpo_failback_duration_seconds"),
):
    gia_tri = trang_thai[khoa]
    if isinstance(gia_tri, (int, float)) and not isinstance(gia_tri, bool) and math.isfinite(gia_tri):
        mong_doi.add(f'{ten} {gia_tri}')

thieu = mong_doi - metrics
if thieu:
    print("Thiếu metric: " + ", ".join(sorted(thieu)))
    raise SystemExit(1)
PY

MO_TA="Endpoint không tồn tại trả HTTP 404"
bao_cao python3 - <<'PY'
import urllib.error
import urllib.request
try:
    urllib.request.urlopen("http://127.0.0.1:9105/khong-co", timeout=2)
except urllib.error.HTTPError as loi:
    raise SystemExit(0 if loi.code == 404 else 1)
raise SystemExit(1)
PY

if ((SO_LOI > 0)); then
    printf '[KHÔNG ĐẠT] Giai đoạn H còn %d lỗi, mã thoát 1.\n' "$SO_LOI"
    exit 1
fi

printf '[ĐẠT] Toàn bộ 5/5 kiểm thử Giai đoạn H đã đạt, mã thoát 0.\n'
