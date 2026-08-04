$ErrorActionPreference = "Stop"

$ThuMucGoc = Split-Path -Parent $PSScriptRoot
$FileCompose = Join-Path $ThuMucGoc "docker/docker-compose.yml"
$FileMoiTruong = Join-Path $ThuMucGoc ".env"
if (-not (Test-Path $FileMoiTruong)) {
    $FileMoiTruong = Join-Path $ThuMucGoc ".env.example"
}
$FileLog = Join-Path $ThuMucGoc "logs/phase_i_test.log"
$SoLoi = 0
$ThamSoCompose = @("compose", "--env-file", $FileMoiTruong, "-f", $FileCompose)

New-Item -ItemType Directory -Force (Split-Path -Parent $FileLog) | Out-Null
Set-Content -Encoding utf8 $FileLog "KIỂM THỬ GIAI ĐOẠN I"

function Ghi-KetQua([string]$NoiDung) {
    Write-Host $NoiDung
    Add-Content -Encoding utf8 $FileLog $NoiDung
}

function Chay-Docker([string[]]$ThamSo) {
    $MucLoiCu = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & docker @ThamSo *> $null
        $MaThoat = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $MucLoiCu
    }
    if ($MaThoat -ne 0) {
        throw "Lệnh Docker thất bại với mã $MaThoat."
    }
}

function Cho-Den([scriptblock]$DieuKien, [int]$SoGiay = 60) {
    $KetThuc = (Get-Date).AddSeconds($SoGiay)
    while ((Get-Date) -lt $KetThuc) {
        try {
            if (& $DieuKien) { return $true }
        } catch {
            # Dịch vụ có thể chưa sẵn sàng trong lúc chờ.
        }
        Start-Sleep -Seconds 1
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

function Trang-Thai-Container([string]$Ten, [string]$ThuocTinh) {
    $GiaTri = & docker inspect --format "{{.$ThuocTinh}}" $Ten 2>$null
    if ($LASTEXITCODE -ne 0) { return "" }
    return "$GiaTri".Trim()
}

function Truy-Van-Prometheus([string]$BieuThuc, [Nullable[double]]$ThoiDiem = $null) {
    $MaHoa = [uri]::EscapeDataString($BieuThuc)
    $Url = "http://localhost:9090/api/v1/query?query=$MaHoa"
    if ($null -ne $ThoiDiem) { $Url += "&time=$ThoiDiem" }
    return Invoke-RestMethod -Uri $Url -TimeoutSec 5
}

$DongIp = Get-Content $FileMoiTruong | Where-Object { $_ -match '^UBUNTU_VM_IP=' } | Select-Object -First 1
$IpUbuntu = ($DongIp -split '=', 2)[1].Trim()

try {
    Chay-Docker ($ThamSoCompose + @("up", "-d"))
} catch {
    Ghi-KetQua "[KHÔNG ĐẠT] Không thể khởi động Giai đoạn I - $($_.Exception.Message)"
    exit 2
}

Kiem-Tra "Hai container Prometheus và Blackbox Exporter đã khởi động" {
    (Trang-Thai-Container "bpo-prometheus" "State.Running") -eq "true" -and
    (Trang-Thai-Container "bpo-blackbox" "State.Running") -eq "true"
}

Kiem-Tra "Prometheus ở trạng thái healthy" {
    Cho-Den { (Trang-Thai-Container "bpo-prometheus" "State.Health.Status") -eq "healthy" }
}

Kiem-Tra "Blackbox Exporter ở trạng thái healthy" {
    Cho-Den { (Trang-Thai-Container "bpo-blackbox" "State.Health.Status") -eq "healthy" }
}

Kiem-Tra "Prometheus truy cập được qua cổng 9090" {
    (Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:9090/-/ready" -TimeoutSec 5).StatusCode -eq 200
}

Kiem-Tra "Target Ubuntu exporter UP và Blackbox probe thành công" {
    Cho-Den {
        $MucTieu = Invoke-RestMethod -Uri "http://localhost:9090/api/v1/targets" -TimeoutSec 5
        $ExporterUp = @($MucTieu.data.activeTargets | Where-Object {
            $_.labels.job -eq "bpo_exporter" -and $_.health -eq "up"
        }).Count -eq 1
        $Probe = Truy-Van-Prometheus 'probe_success{job="blackbox_http"}'
        $ExporterUp -and @($Probe.data.result).Count -eq 1 -and $Probe.data.result[0].value[1] -eq "1"
    }
}

Kiem-Tra "Prometheus đã nhận các metric bpo_*" {
    $KetQua = Truy-Van-Prometheus '{__name__=~"bpo_.+"}'
    $TenMetric = @($KetQua.data.result | ForEach-Object { $_.metric.__name__ } | Sort-Object -Unique)
    $TenMetric.Count -gt 0 -and $TenMetric -contains "bpo_exporter_up" -and $TenMetric -contains "bpo_link_up"
}

Kiem-Tra "Dữ liệu Prometheus còn sau khi restart container" {
    $Truoc = Truy-Van-Prometheus "bpo_exporter_up"
    if (@($Truoc.data.result).Count -ne 1) { return $false }
    $MocDuLieu = [double]$Truoc.data.result[0].value[0]
    Chay-Docker ($ThamSoCompose + @("restart", "prometheus"))
    if (-not (Cho-Den {
        (Trang-Thai-Container "bpo-prometheus" "State.Health.Status") -eq "healthy" -and
        (Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:9090/-/ready" -TimeoutSec 3).StatusCode -eq 200
    })) { return $false }
    $Sau = Truy-Van-Prometheus "bpo_exporter_up" $MocDuLieu
    @($Sau.data.result).Count -eq 1
}

Kiem-Tra "Docker không làm gián đoạn endpoint Ubuntu và Dual-WAN" {
    $Health = Invoke-WebRequest -UseBasicParsing -Uri "http://${IpUbuntu}:9105/health" -TimeoutSec 5
    $Metrics = Invoke-WebRequest -UseBasicParsing -Uri "http://${IpUbuntu}:9105/metrics" -TimeoutSec 5
    $Health.StatusCode -eq 200 -and $Metrics.Content -match 'bpo_link_up\{provider="fpt"\}'
}

if ($SoLoi -gt 0) {
    Ghi-KetQua "[KHÔNG ĐẠT] Giai đoạn I còn $SoLoi lỗi, mã thoát 1."
    exit 1
}

Ghi-KetQua "[ĐẠT] Toàn bộ 8/8 kiểm thử Giai đoạn I đã đạt, mã thoát 0."
exit 0
