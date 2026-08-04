#!/usr/bin/env bash

set -uo pipefail

if ! ip -4 -o addr show dev r1-eth1 | grep -q '100.64.10.1/30'; then
    printf '[KHÔNG ĐẠT] Hãy chạy script từ node r1 trong Mininet CLI.\n'
    exit 2
fi

ip link set r1-eth1 up
ip route replace 100.64.30.2/32 via 100.64.10.2 dev r1-eth1
printf '[ĐẠT] Đã khôi phục đường truyền FPT.\n'
