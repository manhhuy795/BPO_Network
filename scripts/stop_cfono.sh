#!/usr/bin/env bash

set -uo pipefail
FILE_PID=/tmp/bpo_cfono.pid

if ! ip -4 -o addr show | grep -q '172.16.100.20/'; then
    printf '[KHÔNG ĐẠT] Hãy chạy script từ nút srv_cfono trong Mininet CLI.\n'
    exit 2
fi

if [[ ! -f "$FILE_PID" ]] || ! kill -0 "$(<"$FILE_PID")" 2>/dev/null; then
    rm -f "$FILE_PID"
    printf '[ĐẠT] CFONO đã dừng từ trước.\n'
    exit 0
fi

kill "$(<"$FILE_PID")"
for _lan in {1..20}; do
    kill -0 "$(<"$FILE_PID")" 2>/dev/null || break
    sleep 0.1
done

if kill -0 "$(<"$FILE_PID")" 2>/dev/null; then
    printf '[KHÔNG ĐẠT] Không thể dừng CFONO.\n'
    exit 1
fi

rm -f "$FILE_PID"
printf '[ĐẠT] Đã dừng CFONO.\n'
