#!/usr/bin/env bash

set -uo pipefail

THU_MUC_GOC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE_TRANG_THAI="$THU_MUC_GOC/runtime/wan_status.json"

if [[ ! -f "$FILE_TRANG_THAI" ]]; then
    printf '[KHÔNG ĐẠT] Chưa có trạng thái WAN. Hãy khởi động topology v2.\n'
    exit 2
fi

python3 - "$FILE_TRANG_THAI" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as tep:
    trang_thai = json.load(tep)

ten_duong = {"fpt": "FPT", "viettel": "Viettel", "none": "không có"}
print(f"Thời gian kiểm tra: {trang_thai['checked_at']}")
print(f"FPT: {'hoạt động' if trang_thai['fpt_up'] else 'mất'}")
print(f"Viettel: {'hoạt động' if trang_thai['viettel_up'] else 'mất'}")
print(f"Đường truyền đang sử dụng: {ten_duong[trang_thai['active_wan']]}")
print(f"Thời gian chuyển dự phòng: {trang_thai['failover_duration_seconds']}")
print(f"Thời gian chuyển về FPT: {trang_thai['failback_duration_seconds']}")
PY
