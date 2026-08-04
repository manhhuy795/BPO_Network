#!/usr/bin/env bash

set -uo pipefail
FILE_PID=/tmp/bpo_cfono.pid

if ! ip -4 -o addr show | grep -q '172.16.100.20/'; then
    printf '[KHÔNG ĐẠT] Hãy chạy script từ nút srv_cfono trong Mininet CLI.\n'
    exit 2
fi

if [[ -f "$FILE_PID" ]] && kill -0 "$(<"$FILE_PID")" 2>/dev/null; then
    printf '[ĐẠT] CFONO đang hoạt động.\n'
    exit 0
fi

rm -f "$FILE_PID"
nohup python3 -c '
from http.server import BaseHTTPRequestHandler, HTTPServer

class BoXuLy(BaseHTTPRequestHandler):
    def do_GET(self):
        noi_dung = "CFONO phía đối tác đang hoạt động".encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(noi_dung)))
        self.end_headers()
        self.wfile.write(noi_dung)

    def log_message(self, _dinh_dang, *_tham_so):
        pass

HTTPServer(("0.0.0.0", 80), BoXuLy).serve_forever()
' </dev/null >/tmp/bpo_cfono_http.log 2>&1 &
printf '%s\n' "$!" >"$FILE_PID"
sleep 0.3

if kill -0 "$(<"$FILE_PID")" 2>/dev/null; then
    printf '[ĐẠT] Đã khởi động CFONO.\n'
    exit 0
fi

printf '[KHÔNG ĐẠT] Không thể khởi động CFONO.\n'
exit 1
