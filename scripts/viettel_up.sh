#!/usr/bin/env bash

set -uo pipefail

if ! ip -4 -o addr show dev r1-eth2 | grep -q '100.64.20.1/30'; then
    printf '[KHÔNG ĐẠT] Hãy chạy script từ node r1 trong Mininet CLI.\n'
    exit 2
fi

ip link set r1-eth2 up
ip route replace 100.64.40.2/32 via 100.64.20.2 dev r1-eth2
printf '[ĐẠT] Đã khôi phục đường truyền Viettel.\n'
