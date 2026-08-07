$ErrorActionPreference = "Stop"

$Goc = Split-Path -Parent $PSScriptRoot
$Compose = Join-Path $Goc "docker/docker-compose.yml"
$EnvFile = Join-Path $Goc ".env"
$LogFile = Join-Path $Goc "logs/wan_status_stale_test.log"
$Loi = 0
$CoNamespaceRouter = $false

New-Item -ItemType Directory -Force (Split-Path $LogFile) | Out-Null
Set-Content -Encoding utf8 $LogFile "KIỂM THỬ TRẠNG THÁI WAN STALE - $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"

function Ghi([string]$NoiDung) {
    Write-Host $NoiDung
    Add-Content -Encoding utf8 $LogFile $NoiDung
}

function Bien([string]$Ten) {
    $Dong = Get-Content $EnvFile | Where-Object { $_ -match "^$Ten=" } | Select-Object -First 1
    if (-not $Dong) { throw "Thiếu biến $Ten trong .env." }
    return ($Dong -split "=", 2)[1]
}

if (-not (Test-Path $EnvFile)) {
    Ghi "[KHÔNG ĐẠT] Không tìm thấy file .env, mã thoát 2."
    exit 2
}

$SshUser = Bien "UBUNTU_SSH_USER"
$SshIp = Bien "UBUNTU_VM_IP"
$SshKey = Bien "UBUNTU_SSH_KEY"
$VmRoot = "/home/$SshUser/BPO_Network"
$ThamSoCompose = @("compose", "--env-file", $EnvFile, "-f", $Compose)

function Vm([string]$Lenh) {
    $MucLoiCu = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $KetQua = & ssh -i $SshKey -o IdentitiesOnly=yes -o ConnectTimeout=8 `
            "${SshUser}@${SshIp}" $Lenh 2>&1
        $Ma = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $MucLoiCu
    }
    if ($Ma -ne 0) { throw "SSH Ubuntu lỗi ${Ma}: $($KetQua -join ' ')" }
    return (($KetQua | Out-String).Trim())
}

function Cho([scriptblock]$DieuKien, [int]$Giay = 45) {
    $HetHan = (Get-Date).AddSeconds($Giay)
    while ((Get-Date) -lt $HetHan) {
        try { if (& $DieuKien) { return $true } } catch {}
        Start-Sleep -Seconds 1
    }
    return $false
}

function Metric-Ubuntu([string]$Ten) {
    $NoiDung = (Invoke-WebRequest -UseBasicParsing "http://${SshIp}:9105/metrics" -TimeoutSec 5).Content
    $Mau = '(?m)^' + [regex]::Escape($Ten) + ' ([^\r\n]+)$'
    $Khop = [regex]::Match($NoiDung, $Mau)
    if (-not $Khop.Success) { return $null }
    return [double]$Khop.Groups[1].Value
}

function Metric-Prometheus([string]$TruyVan) {
    $Q = [Uri]::EscapeDataString($TruyVan)
    $TraVe = Invoke-RestMethod "http://localhost:9090/api/v1/query?query=$Q" -TimeoutSec 5
    if (@($TraVe.data.result).Count -eq 0) { return $null }
    return [double]$TraVe.data.result[0].value[1]
}

function Alert-Dang-Ban([string]$Ten) {
    return $null -ne (Metric-Prometheus ('ALERTS{{alertname="{0}",alertstate="firing"}}' -f $Ten))
}

function Alertmanager-Dang-Ban([string]$Ten) {
    $Alerts = @(Invoke-RestMethod "http://localhost:9093/api/v2/alerts?active=true&silenced=false&inhibited=false" -TimeoutSec 5)
    return @($Alerts | Where-Object {
        $_.labels.alertname -eq $Ten -and $_.status.state -eq "active"
    }).Count -gt 0
}

function Khoi-Dong-Monitor {
    $Lenh = @'
if test -f /tmp/bpo_wan_monitor.pid && sudo -n kill -0 $(cat /tmp/bpo_wan_monitor.pid) 2>/dev/null; then exit 0; fi
node_pid=$(pgrep -f '[m]ininet:r1' | head -n1)
test -n "$node_pid" || exit 1
sudo -n mnexec -a $node_pid bash -c 'cd __VM_ROOT__; nohup python3 scripts/wan_monitor.py >/tmp/bpo_wan_monitor.log 2>&1 </dev/null & echo $! >/tmp/bpo_wan_monitor.pid'
'@
    $Lenh = $Lenh.Replace('__VM_ROOT__', $VmRoot).Trim()
    $null = Vm $Lenh
}

function Dung-Monitor {
    $null = Vm 'test -f /tmp/bpo_wan_monitor.pid && sudo -n kill $(cat /tmp/bpo_wan_monitor.pid); sudo -n rm -f /tmp/bpo_wan_monitor.pid'
}

try {
    if (-not (Test-Path $SshKey)) { throw "Không tìm thấy khóa SSH $SshKey." }
    $null = Vm "pgrep -f '[m]ininet:r1' >/dev/null"
    $CoNamespaceRouter = $true

    & docker @ThamSoCompose up -d | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose không khởi động được." }
    & docker @ThamSoCompose restart prometheus | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Không restart được Prometheus để nạp rule." }

    $LenhExporter = @'
cd __VM_ROOT__
pgrep -f '^python3 metrics/bpo_exporter.py$' >/dev/null || nohup python3 metrics/bpo_exporter.py >/tmp/bpo_exporter.log 2>&1 </dev/null &
'@
    $LenhExporter = $LenhExporter.Replace('__VM_ROOT__', $VmRoot).Trim()
    $null = Vm $LenhExporter
    Khoi-Dong-Monitor

    if (-not (Cho {
        (Metric-Ubuntu "bpo_exporter_up") -eq 1 -and
        (Metric-Ubuntu "bpo_wan_status_read_success") -eq 1 -and
        (Metric-Ubuntu "bpo_wan_monitor_up") -eq 1 -and
        (Metric-Prometheus "bpo_wan_monitor_up") -eq 1
    } 45)) { throw "Exporter hoặc monitor chưa healthy trước kiểm thử." }
    Ghi "[ĐẠT] Ban đầu exporter và WAN monitor đều hoạt động."

    Dung-Monitor
    Ghi "[ĐẠT] Đã dừng riêng wan_monitor.py, exporter vẫn chạy."

    if (-not (Cho {
        (Metric-Ubuntu "bpo_exporter_up") -eq 1 -and
        (Metric-Ubuntu "bpo_wan_status_read_success") -eq 1 -and
        (Metric-Ubuntu "bpo_wan_monitor_up") -eq 0
    } 30)) { throw "Sau ngưỡng 10 giây, metric stale không chuyển đúng trạng thái." }
    Ghi "[ĐẠT] Exporter vẫn bằng 1 và WAN monitor chuyển về 0 sau ngưỡng stale."

    if (-not (Cho {
        (Alert-Dang-Ban "WANStatusStale") -and
        (Alertmanager-Dang-Ban "WANStatusStale") -and
        -not (Alert-Dang-Ban "WANMonitorDown") -and
        -not (Alertmanager-Dang-Ban "WANMonitorDown")
    } 45)) { throw "WANStatusStale không firing đúng hoặc bị trùng WANMonitorDown." }
    Ghi "[ĐẠT] WANStatusStale firing và WANMonitorDown không firing trùng."
} catch {
    $Loi++
    Ghi "[KHÔNG ĐẠT] $($_.Exception.Message)"
} finally {
    if ($CoNamespaceRouter) {
        try {
            Khoi-Dong-Monitor
            if (-not (Cho {
                (Metric-Ubuntu "bpo_wan_monitor_up") -eq 1 -and
                (Metric-Prometheus "bpo_wan_monitor_up") -eq 1 -and
                -not (Alert-Dang-Ban "WANStatusStale") -and
                -not (Alertmanager-Dang-Ban "WANStatusStale")
            } 60)) { throw "Monitor hoặc alert không phục hồi đúng." }
            Ghi "[ĐẠT] Đã khởi động lại monitor; metric về 1 và alert resolved."
        } catch {
            $Loi++
            Ghi "[KHÔNG ĐẠT] Phục hồi monitor thất bại: $($_.Exception.Message)"
        }
    }
}

if ($Loi -gt 0) {
    Ghi "[KHÔNG ĐẠT] Kiểm thử WAN stale còn $Loi lỗi, mã thoát 1."
    exit 1
}

Ghi "[ĐẠT] Toàn bộ kiểm thử WAN stale đạt, mã thoát 0."
exit 0
