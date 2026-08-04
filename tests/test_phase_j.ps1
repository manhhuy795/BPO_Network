$ErrorActionPreference = "Stop"

$ThuMucGoc = Split-Path -Parent $PSScriptRoot
$FileCompose = Join-Path $ThuMucGoc "docker/docker-compose.yml"
$FileMoiTruong = Join-Path $ThuMucGoc ".env"
if (-not (Test-Path $FileMoiTruong)) {
    $FileMoiTruong = Join-Path $ThuMucGoc ".env.example"
}
$FileLog = Join-Path $ThuMucGoc "logs/phase_j_test.log"
$SoLoi = 0
$ThamSoCompose = @("compose", "--env-file", $FileMoiTruong, "-f", $FileCompose)

New-Item -ItemType Directory -Force (Split-Path -Parent $FileLog) | Out-Null
Set-Content -Encoding utf8 $FileLog "KIỂM THỬ GIAI ĐOẠN J"

function Ghi-KetQua([string]$NoiDung) {
    Write-Host $NoiDung
    Add-Content -Encoding utf8 $FileLog $NoiDung
}

function Lay-Bien([string]$Ten) {
    $Dong = Get-Content $FileMoiTruong | Where-Object { $_ -match "^$Ten=" } | Select-Object -First 1
    if (-not $Dong) { throw "Thiếu biến $Ten trong .env.example." }
    return ($Dong -split '=', 2)[1].Trim()
}

$IpUbuntu = Lay-Bien "UBUNTU_VM_IP"
$SshUser = Lay-Bien "UBUNTU_SSH_USER"
$SshKey = Lay-Bien "UBUNTU_SSH_KEY"
$ThuMucVm = "/home/$SshUser/BPO_Network"

function Chay-Native([string]$Lenh, [string[]]$ThamSo) {
    $MucLoiCu = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $Lenh @ThamSo *> $null
        $MaThoat = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $MucLoiCu
    }
    if ($MaThoat -ne 0) { throw "Lệnh $Lenh thất bại với mã $MaThoat." }
}

function Chay-Docker([string[]]$ThamSo) {
    Chay-Native "docker" $ThamSo
}

function Chay-Ssh([string]$Lenh) {
    Chay-Native "ssh" @(
        "-i", $SshKey, "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=8",
        "$SshUser@$IpUbuntu", $Lenh
    )
}

function Chay-Tren-Node([string]$Node, [string]$Script) {
    $Lenh = "cd $ThuMucVm; pid=`$(pgrep -f '[m]ininet:$Node' | head -n 1); test -n `"`$pid`" && sudo mnexec -a `$pid bash scripts/$Script"
    Chay-Ssh $Lenh
}

function Khoi-Dong-Exporter {
    Chay-Ssh "cd $ThuMucVm; curl -fsS http://127.0.0.1:9105/health >/dev/null 2>&1 || setsid -f python3 metrics/bpo_exporter.py >/tmp/bpo_exporter.log 2>&1 </dev/null"
}

function Cho-Den([scriptblock]$DieuKien, [int]$SoGiay = 75) {
    $KetThuc = (Get-Date).AddSeconds($SoGiay)
    while ((Get-Date) -lt $KetThuc) {
        try {
            if (& $DieuKien) { return $true }
        } catch {
            # Cảnh báo có thể đang pending hoặc dịch vụ đang đổi trạng thái.
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Kiem-Tra([string]$MoTa, [scriptblock]$NoiDung) {
    try {
        if (-not (& $NoiDung)) { throw "Điều kiện kiểm tra không đạt." }
        Ghi-KetQua "[ĐẠT] $MoTa"
    } catch {
        $script:SoLoi++
        Ghi-KetQua "[KHÔNG ĐẠT] $MoTa - $($_.Exception.Message)"
    }
}

function Lay-Alert-Prometheus([string]$Ten) {
    $DuLieu = Invoke-RestMethod -Uri "http://localhost:9090/api/v1/alerts" -TimeoutSec 5
    return @($DuLieu.data.alerts | Where-Object {
        $_.labels.alertname -eq $Ten -and $_.state -eq "firing"
    })
}

function Lay-Alert-Alertmanager([string]$Ten) {
    $DuLieu = Invoke-RestMethod -Uri "http://localhost:9093/api/v2/alerts?active=true&silenced=false&inhibited=false" -TimeoutSec 5
    return @($DuLieu | Where-Object { $_.labels.alertname -eq $Ten })
}

function Cho-Alert([string]$Ten, [bool]$CoAlert) {
    Cho-Den {
        $CoPrometheus = @(Lay-Alert-Prometheus $Ten).Count -gt 0
        $CoAlertmanager = @(Lay-Alert-Alertmanager $Ten).Count -gt 0
        if ($CoAlert) { $CoPrometheus -and $CoAlertmanager }
        else { -not $CoPrometheus -and -not $CoAlertmanager }
    }
}

if (-not (Test-Path $SshKey)) {
    Ghi-KetQua "[KHÔNG ĐẠT] Không tìm thấy khóa SSH: $SshKey"
    exit 2
}

try {
    Chay-Docker ($ThamSoCompose + @("up", "-d"))
    Chay-Ssh "pgrep -f '[m]ininet:r1' >/dev/null && test -f /tmp/bpo_wan_monitor.pid"
} catch {
    Ghi-KetQua "[KHÔNG ĐẠT] Cần chạy topology Dual-WAN trước khi kiểm thử J - $($_.Exception.Message)"
    exit 2
}

try {
    Kiem-Tra "Prometheus tải đủ 7 luật cảnh báo BPO" {
        $DuLieu = Invoke-RestMethod -Uri "http://localhost:9090/api/v1/rules" -TimeoutSec 5
        $Ten = @($DuLieu.data.groups.rules | ForEach-Object { $_.name })
        @("BPOExporterDown", "FPTDownViettelAvailable", "BothWANDown", "CRMDown", "CFONODown", "HighPacketLoss", "HighLatency" |
            Where-Object { $_ -notin $Ten }).Count -eq 0
    }

    Kiem-Tra "Alertmanager healthy và được Prometheus kết nối" {
        $Healthy = (Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:9093/-/healthy" -TimeoutSec 5).StatusCode -eq 200
        $KetNoi = Invoke-RestMethod -Uri "http://localhost:9090/api/v1/alertmanagers" -TimeoutSec 5
        $Healthy -and @($KetNoi.data.activeAlertmanagers).Count -eq 1
    }

    Kiem-Tra "Dừng exporter tạo BPOExporterDown mức cao" {
        Chay-Ssh "pkill -f '[m]etrics/bpo_exporter.py' || true"
        $DaCanhBao = Cho-Alert "BPOExporterDown" $true
        $MucDoDung = @(Lay-Alert-Prometheus "BPOExporterDown")[0].labels.severity -eq "cao"
        $DaCanhBao -and $MucDoDung
    }

    Kiem-Tra "Khởi động lại exporter làm BPOExporterDown được giải quyết" {
        Khoi-Dong-Exporter
        Cho-Alert "BPOExporterDown" $false
    }

    Kiem-Tra "Ngắt FPT tạo FPTDownViettelAvailable mức trung bình" {
        Chay-Tren-Node "r1" "fpt_down.sh"
        $DaCanhBao = Cho-Alert "FPTDownViettelAvailable" $true
        $MucDoDung = @(Lay-Alert-Prometheus "FPTDownViettelAvailable")[0].labels.severity -eq "trung_binh"
        $DaCanhBao -and $MucDoDung
    }

    Kiem-Tra "Ngắt cả hai WAN tạo BothWANDown mức cao làm cảnh báo chính" {
        Chay-Tren-Node "r1" "viettel_down.sh"
        $CaHai = Cho-Alert "BothWANDown" $true
        $MucDoDung = @(Lay-Alert-Prometheus "BothWANDown")[0].labels.severity -eq "cao"
        $KhongConCanhBaoFptDon = Cho-Alert "FPTDownViettelAvailable" $false
        Chay-Tren-Node "r1" "fpt_up.sh"
        Chay-Tren-Node "r1" "viettel_up.sh"
        $DaPhucHoi = Cho-Alert "BothWANDown" $false
        $CaHai -and $MucDoDung -and $KhongConCanhBaoFptDon -and $DaPhucHoi
    }

    Kiem-Tra "Dừng CRM chỉ tạo CRMDown, không tạo CFONODown" {
        Chay-Tren-Node "srv_crm" "stop_crm.sh"
        $CrmCanhBao = Cho-Alert "CRMDown" $true
        $CfonoKhongCanhBao = Cho-Alert "CFONODown" $false
        Chay-Tren-Node "srv_crm" "start_crm.sh"
        $CrmPhucHoi = Cho-Alert "CRMDown" $false
        $CrmCanhBao -and $CfonoKhongCanhBao -and $CrmPhucHoi
    }

    Kiem-Tra "Khôi phục thành phần làm toàn bộ cảnh báo thử nghiệm được giải quyết" {
        Khoi-Dong-Exporter
        Chay-Tren-Node "r1" "fpt_up.sh"
        Chay-Tren-Node "r1" "viettel_up.sh"
        Chay-Tren-Node "srv_crm" "start_crm.sh"
        Chay-Tren-Node "srv_cfono" "start_cfono.sh"
        Cho-Den {
            @("BPOExporterDown", "FPTDownViettelAvailable", "BothWANDown", "CRMDown", "CFONODown" |
                Where-Object { @(Lay-Alert-Prometheus $_).Count -gt 0 -or @(Lay-Alert-Alertmanager $_).Count -gt 0 }).Count -eq 0
        }
    }
} finally {
    try { Khoi-Dong-Exporter } catch {}
    try { Chay-Tren-Node "r1" "fpt_up.sh" } catch {}
    try { Chay-Tren-Node "r1" "viettel_up.sh" } catch {}
    try { Chay-Tren-Node "srv_crm" "start_crm.sh" } catch {}
    try { Chay-Tren-Node "srv_cfono" "start_cfono.sh" } catch {}
}

if ($SoLoi -gt 0) {
    Ghi-KetQua "[KHÔNG ĐẠT] Giai đoạn J còn $SoLoi lỗi, mã thoát 1."
    exit 1
}

Ghi-KetQua "[ĐẠT] Toàn bộ 8/8 kiểm thử Giai đoạn J đã đạt, mã thoát 0."
exit 0
