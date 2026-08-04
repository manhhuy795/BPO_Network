#!/usr/bin/env bash

set -uo pipefail

THU_MUC_GOC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE_LOG="$THU_MUC_GOC/logs/phase_d_test.log"
cd "$THU_MUC_GOC"
mkdir -p logs

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
    # ponytail: dọn tên interface từ topology cũ; bỏ khi không còn bản cũ.
    for giao_dien in \
        s_core-r1 s_core-dist \
        s_dist-a20 s_dist-a30 s_dist-a40 s_dist-a50 s_dist-a60 \
        s_a20-pc1 s_a30-pc2 s_a40-pc3 s_a50-pc4 \
        s_a60-it s_a60-office \
        s_outside-r1 s_outside-crm s_outside-cfono; do
        ip link delete "$giao_dien" >/dev/null 2>&1 || true
    done
}
trap don_dep EXIT
don_dep

python3 topology/topology_v1.py --kiem-thu-d 2>&1 | tee "$FILE_LOG"
ma_loi=${PIPESTATUS[0]}

if [[ "$ma_loi" -eq 0 ]]; then
    printf '[ĐẠT] Toàn bộ kiểm thử Giai đoạn D đã đạt.\n' | tee -a "$FILE_LOG"
else
    printf '[KHÔNG ĐẠT] Giai đoạn D còn lỗi, mã thoát %s.\n' "$ma_loi" | tee -a "$FILE_LOG"
fi

exit "$ma_loi"
