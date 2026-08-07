$ErrorActionPreference = "Stop"

$Goc = Split-Path -Parent $PSScriptRoot
$EnvFile = Join-Path $Goc ".env"
$LogFile = Join-Path $Goc "logs/service_http_probe_test.log"
$SoLoi = 0

New-Item -ItemType Directory -Force (Split-Path -Parent $LogFile) | Out-Null
Set-Content -Encoding utf8 $LogFile "KIỂM THỬ PROCESS VÀ HTTP CRM/CFONO"

function Ghi([string]$NoiDung) {
    Write-Host $NoiDung
    Add-Content -Encoding utf8 $LogFile $NoiDung
}

function Bien([string]$Ten) {
    $Dong = Get-Content $EnvFile | Where-Object { $_ -match "^$Ten=" } | Select-Object -First 1
    if (-not $Dong) { throw "Thiếu biến $Ten trong .env." }
    return ($Dong -split "=", 2)[1].Trim()
}

$SshIp = Bien "UBUNTU_VM_IP"
$SshUser = Bien "UBUNTU_SSH_USER"
$SshKey = Bien "UBUNTU_SSH_KEY"
$VmRoot = "/home/$SshUser/BPO_Network"

function Vm([string]$Lenh) {
    $Cu = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $KetQua = & ssh -i $SshKey -o IdentitiesOnly=yes -o ConnectTimeout=8 `
            "${SshUser}@${SshIp}" $Lenh 2>&1
        $Ma = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $Cu
    }
    if ($Ma -ne 0) { throw "SSH lỗi ${Ma}: $($KetQua -join ' ')" }
    return (($KetQua | Out-String).Trim())
}

function Node([string]$Ten, [string]$Lenh) {
    $NoiDung = "cd $VmRoot`n$Lenh`n"
    $Base64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($NoiDung))
    $Remote = "pid=`$(pgrep -f '[m]ininet:$Ten' | head -n 1); test -n `"`$pid`" && printf '%s' '$Base64' | base64 -d | sudo -n mnexec -a `$pid bash"
    $null = Vm $Remote
}

function Cho([scriptblock]$DieuKien, [int]$Giay = 50) {
    $HetHan = (Get-Date).AddSeconds($Giay)
    while ((Get-Date) -lt $HetHan) {
        try { if (& $DieuKien) { return $true } } catch {}
        Start-Sleep -Seconds 1
    }
    return $false
}

function GiaTri([string]$BieuThuc) {
    $Q = [uri]::EscapeDataString($BieuThuc)
    $R = Invoke-RestMethod "http://localhost:9090/api/v1/query?query=$Q" -TimeoutSec 5
    if (@($R.data.result).Count -eq 0) { return $null }
    return [double]$R.data.result[0].value[1]
}

function AlertProm([string]$Ten) {
    return (GiaTri "ALERTS{alertname=`"$Ten`",alertstate=`"firing`"}") -eq 1
}

function Alertmanager([string]$Ten) {
    $R = @(Invoke-RestMethod http://localhost:9093/api/v2/alerts -TimeoutSec 5)
    return @($R | Where-Object {
        $_.labels.alertname -eq $Ten -and $_.status.state -eq "active"
    }).Count -gt 0
}

function YeuCau([bool]$DieuKien, [string]$Loi) {
    if (-not $DieuKien) { throw $Loi }
}

function KiemTra([string]$MoTa, [scriptblock]$NoiDung) {
    try {
        & $NoiDung
        Ghi "[ĐẠT] $MoTa"
    } catch {
        $script:SoLoi++
        Ghi "[KHÔNG ĐẠT] $MoTa - $($_.Exception.Message)"
    }
}

function BatDichVu([string]$Ten) {
    Node "srv_$Ten" "bash scripts/start_$Ten.sh"
}

function TatDichVu([string]$Ten) {
    Node "srv_$Ten" "bash scripts/stop_$Ten.sh"
}

function XoaChanMangCrm {
    Node "pc_du_an_1" 'while iptables -D OUTPUT -d 172.16.100.10 -p tcp --dport 80 -m comment --comment bpo_phase3_test -j REJECT 2>/dev/null; do :; done'
}

function PhucHoiTatCa {
    try { Node "srv_crm" 'test ! -f /tmp/bpo_crm.pid || kill -CONT "$(cat /tmp/bpo_crm.pid)" 2>/dev/null || true' } catch {}
    try { Node "srv_cfono" 'test ! -f /tmp/bpo_cfono.pid || kill -CONT "$(cat /tmp/bpo_cfono.pid)" 2>/dev/null || true' } catch {}
    try { XoaChanMangCrm } catch {}
    try { BatDichVu "crm" } catch {}
    try { BatDichVu "cfono" } catch {}
}

function DichVuDaPhucHoi([string]$Ten, [string[]]$AlertProm, [string]$AlertCu) {
    return Cho {
        (GiaTri "bpo_service_process_up{service=`"$Ten`"}") -eq 1 -and
        (GiaTri "probe_success{service=`"$Ten`"}") -eq 1 -and
        @($AlertProm | Where-Object { AlertProm $_ }).Count -eq 0 -and
        -not (Alertmanager $AlertCu)
    } 60
}

try {
    $SanSang = Cho {
        (GiaTri 'bpo_service_process_up{service="crm"}') -eq 1 -and
        (GiaTri 'bpo_service_process_up{service="cfono"}') -eq 1 -and
        (GiaTri 'probe_success{service="crm"}') -eq 1 -and
        (GiaTri 'probe_success{service="cfono"}') -eq 1
    } 20
    if (-not $SanSang) {
        Ghi "[KHÔNG ĐẠT] Chưa có đủ metric process và HTTP riêng cho CRM/CFONO."
        exit 1
    }

    KiemTra "Process và HTTP của CRM/CFONO đều hoạt động" {
        YeuCau $SanSang "Trạng thái nền không hợp lệ."
    }

    KiemTra "Dừng CRM chỉ tạo CRMProcessDown" {
        try {
            TatDichVu "crm"
            YeuCau (Cho {
                (GiaTri 'bpo_service_process_up{service="crm"}') -eq 0 -and
                (AlertProm "CRMProcessDown") -and
                -not (AlertProm "CRMHttpUnavailable") -and
                -not (AlertProm "CFONOProcessDown")
            }) "CRMProcessDown không firing độc lập."
        } finally {
            BatDichVu "crm"
        }
        YeuCau (DichVuDaPhucHoi "crm" @("CRMProcessDown", "CRMHttpUnavailable") "CRMDown") "CRM chưa resolved sau khi khởi động lại."
    }

    KiemTra "Dừng CFONO chỉ tạo CFONOProcessDown" {
        try {
            TatDichVu "cfono"
            YeuCau (Cho {
                (GiaTri 'bpo_service_process_up{service="cfono"}') -eq 0 -and
                (AlertProm "CFONOProcessDown") -and
                -not (AlertProm "CFONOHttpUnavailable") -and
                -not (AlertProm "CRMProcessDown")
            }) "CFONOProcessDown không firing độc lập."
        } finally {
            BatDichVu "cfono"
        }
        YeuCau (DichVuDaPhucHoi "cfono" @("CFONOProcessDown", "CFONOHttpUnavailable") "CFONODown") "CFONO chưa resolved sau khi khởi động lại."
    }

    KiemTra "CRM process sống nhưng HTTP không phản hồi" {
        try {
            Node "srv_crm" 'kill -STOP "$(cat /tmp/bpo_crm.pid)"'
            YeuCau (Cho {
                (GiaTri 'bpo_service_process_up{service="crm"}') -eq 1 -and
                (GiaTri 'probe_success{service="crm"}') -eq 0 -and
                (AlertProm "CRMHttpUnavailable") -and
                -not (AlertProm "CRMProcessDown") -and
                (Alertmanager "CRMDown")
            } 65) "Không tách được lỗi HTTP với process còn sống."
        } finally {
            Node "srv_crm" 'kill -CONT "$(cat /tmp/bpo_crm.pid)" 2>/dev/null || true'
        }
        YeuCau (DichVuDaPhucHoi "crm" @("CRMProcessDown", "CRMHttpUnavailable") "CRMDown") "CRM chưa resolved sau SIGCONT."
    }

    KiemTra "HTTP CRM trả status lỗi bị phát hiện" {
        $Python500 = @'
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(500)
        self.end_headers()
    def log_message(self, *_args):
        pass
HTTPServer(("0.0.0.0", 80), H).serve_forever()
'@
        $MaPython = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Python500))
        try {
            TatDichVu "crm"
            $Lenh500 = 'nohup python3 -c ''import base64;exec(base64.b64decode("{0}"))'' >/tmp/bpo_crm_http.log 2>&1 </dev/null & echo $! >/tmp/bpo_crm.pid; sleep 0.5' -f $MaPython
            Node "srv_crm" $Lenh500
            YeuCau (Cho {
                (GiaTri 'bpo_service_process_up{service="crm"}') -eq 1 -and
                (GiaTri 'probe_success{service="crm"}') -eq 0 -and
                (AlertProm "CRMHttpUnavailable") -and
                -not (AlertProm "CRMProcessDown")
            } 65) "HTTP 500 không tạo CRMHttpUnavailable."
        } finally {
            try { TatDichVu "crm" } catch {}
            BatDichVu "crm"
        }
        YeuCau (DichVuDaPhucHoi "crm" @("CRMProcessDown", "CRMHttpUnavailable") "CRMDown") "CRM chưa resolved sau HTTP 500."
    }

    KiemTra "Chặn đường mạng tới CRM nhưng process vẫn sống" {
        try {
            Node "pc_du_an_1" "iptables -I OUTPUT -d 172.16.100.10 -p tcp --dport 80 -m comment --comment bpo_phase3_test -j REJECT"
            YeuCau (Cho {
                (GiaTri 'bpo_service_process_up{service="crm"}') -eq 1 -and
                (GiaTri 'probe_success{service="crm"}') -eq 0 -and
                (AlertProm "CRMHttpUnavailable") -and
                -not (AlertProm "CRMProcessDown")
            } 65) "Lỗi đường mạng không tạo CRMHttpUnavailable."
        } finally {
            XoaChanMangCrm
        }
        YeuCau (DichVuDaPhucHoi "crm" @("CRMProcessDown", "CRMHttpUnavailable") "CRMDown") "CRM chưa resolved sau khi mở lại đường mạng."
    }

    KiemTra "Khôi phục toàn bộ làm alert chuyển resolved" {
        PhucHoiTatCa
        YeuCau (DichVuDaPhucHoi "crm" @("CRMProcessDown", "CRMHttpUnavailable") "CRMDown") "CRM còn alert."
        YeuCau (DichVuDaPhucHoi "cfono" @("CFONOProcessDown", "CFONOHttpUnavailable") "CFONODown") "CFONO còn alert."
    }
} finally {
    PhucHoiTatCa
}

if ($SoLoi -gt 0) {
    Ghi "[KHÔNG ĐẠT] Kiểm thử HTTP dịch vụ còn $SoLoi lỗi, mã thoát 1."
    exit 1
}

Ghi "[ĐẠT] Toàn bộ 7/7 kiểm thử HTTP dịch vụ đã đạt, mã thoát 0."
exit 0
