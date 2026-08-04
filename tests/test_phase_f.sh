#!/usr/bin/env bash

set -uo pipefail

THU_MUC_GOC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE_LOG="$THU_MUC_GOC/logs/phase_f_test.log"
cd "$THU_MUC_GOC"
mkdir -p logs runtime

ghi_loi() {
    printf '[KHÔNG ĐẠT] %s\n' "$1" | tee "$FILE_LOG"
    exit 2
}

command -v mn >/dev/null 2>&1 || ghi_loi "Chưa cài Mininet."
command -v ovs-vsctl >/dev/null 2>&1 || ghi_loi "Chưa cài Open vSwitch."
python3 -c 'import mininet' >/dev/null 2>&1 || ghi_loi "Python chưa đọc được thư viện Mininet."

if [[ "$(id -u)" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || ghi_loi "Cần chạy bằng quyền quản trị nhưng chưa có sudo."
    exec sudo -- "$0" "$@"
fi

don_dep() {
    mn -c >/dev/null 2>&1 || true
}
trap don_dep EXIT
don_dep

python3 topology/topology_v2_dual_wan.py --kiem-thu-f 2>&1 | tee "$FILE_LOG"
ma_loi=${PIPESTATUS[0]}

if [[ "$ma_loi" -eq 0 ]]; then
    printf '[ĐẠT] Toàn bộ kiểm thử Giai đoạn F đã đạt.\n' | tee -a "$FILE_LOG"
else
    printf '[KHÔNG ĐẠT] Giai đoạn F còn lỗi, mã thoát %s.\n' "$ma_loi" | tee -a "$FILE_LOG"
fi

exit "$ma_loi"
