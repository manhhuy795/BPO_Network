$ErrorActionPreference = "Stop"

$ThuMucGoc = Split-Path -Parent $PSScriptRoot
$FileCompose = Join-Path $ThuMucGoc "docker/docker-compose.yml"
$FileMoiTruong = Join-Path $ThuMucGoc ".env"
$FileLog = Join-Path $ThuMucGoc "logs/phase_k_test.log"
$SoLoi = 0
$ThamSoCompose = @("compose", "--env-file", $FileMoiTruong, "-f", $FileCompose)
$KhoaKiemThu = "phase-k-" + [guid]::NewGuid().ToString("N")

New-Item -ItemType Directory -Force (Split-Path -Parent $FileLog) | Out-Null
Set-Content -Encoding utf8 $FileLog "KIỂM THỬ GIAI ĐOẠN K"

function Ghi-KetQua([string]$NoiDung) {
    Write-Host $NoiDung
    Add-Content -Encoding utf8 $FileLog $NoiDung
}

function Lay-Bien([string]$Ten) {
    $Dong = Get-Content $FileMoiTruong | Where-Object { $_ -match "^$Ten=" } | Select-Object -First 1
    if (-not $Dong) { throw "Thiếu biến $Ten trong .env." }
    return ($Dong -split '=', 2)[1].Trim()
}

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

function Trang-Thai-Container([string]$Ten) {
    $GiaTri = & docker inspect --format "{{.State.Health.Status}}" $Ten 2>$null
    if ($LASTEXITCODE -ne 0) { return "" }
    return "$GiaTri".Trim()
}

function Cho-Healthy([string]$Ten, [int]$SoGiay = 90) {
    $KetThuc = (Get-Date).AddSeconds($SoGiay)
    while ((Get-Date) -lt $KetThuc) {
        if ((Trang-Thai-Container $Ten) -eq "healthy") { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Psql([string]$Sql) {
    $MucLoiCu = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $KetQua = & docker exec -e "PGPASSWORD=$MatKhau" bpo-postgres `
            psql -v ON_ERROR_STOP=1 -U $NguoiDung -d $TenDatabase -Atc $Sql 2>$null
        $MaThoat = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $MucLoiCu
    }
    if ($MaThoat -ne 0) { throw "Truy vấn PostgreSQL thất bại với mã $MaThoat." }
    return (@($KetQua) -join "`n").Trim()
}

function Psql-MaThoat([string]$Sql) {
    $MucLoiCu = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & docker exec -e "PGPASSWORD=$MatKhau" bpo-postgres `
            psql -v ON_ERROR_STOP=1 -U $NguoiDung -d $TenDatabase -Atc $Sql *> $null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $MucLoiCu
    }
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

if (-not (Test-Path $FileMoiTruong)) {
    Ghi-KetQua "[KHÔNG ĐẠT] Chưa có file .env, mã thoát 2."
    exit 2
}

$TenDatabase = Lay-Bien "POSTGRES_DB"
$NguoiDung = Lay-Bien "POSTGRES_USER"
$MatKhau = Lay-Bien "POSTGRES_PASSWORD"

try {
    Chay-Docker ($ThamSoCompose + @("up", "-d", "postgres"))
} catch {
    Ghi-KetQua "[KHÔNG ĐẠT] Không thể khởi động PostgreSQL - $($_.Exception.Message)"
    exit 2
}

try {
    Kiem-Tra "PostgreSQL khởi động và healthy" {
        Cho-Healthy "bpo-postgres"
    }

    Kiem-Tra "Đã tạo đủ bốn bảng nghiệp vụ" {
        $Bang = Psql "SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename IN ('raw_alerts','incidents','incident_alerts','incident_events') ORDER BY tablename;"
        @($Bang -split "`n" | Where-Object { $_ }).Count -eq 4
    }

    Kiem-Tra "Volume giữ dữ liệu sau khi restart PostgreSQL" {
        [void](Psql "INSERT INTO raw_alerts (event_key, fingerprint, status, alert_name) VALUES ('$KhoaKiemThu', 'phase-k', 'firing', 'PhaseKPersistence');")
        Chay-Docker ($ThamSoCompose + @("restart", "postgres"))
        if (-not (Cho-Healthy "bpo-postgres")) { return $false }
        $ConDuLieu = (Psql "SELECT COUNT(*) FROM raw_alerts WHERE event_key='$KhoaKiemThu';") -eq "1"
        & docker volume inspect bpo-network-monitoring_postgres_data *> $null
        $CoVolume = $LASTEXITCODE -eq 0
        $ConDuLieu -and $CoVolume
    }

    Kiem-Tra "Ràng buộc event_key chống dữ liệu trùng" {
        $MaTrung = Psql-MaThoat "INSERT INTO raw_alerts (event_key, fingerprint, status, alert_name) VALUES ('$KhoaKiemThu', 'phase-k-lap', 'firing', 'PhaseKDuplicate');"
        $MaTrung -ne 0 -and (Psql "SELECT COUNT(*) FROM raw_alerts WHERE event_key='$KhoaKiemThu';") -eq "1"
    }

    Kiem-Tra "PostgreSQL không ảnh hưởng Prometheus, Blackbox và Alertmanager" {
        (Trang-Thai-Container "bpo-prometheus") -eq "healthy" -and
        (Trang-Thai-Container "bpo-blackbox") -eq "healthy" -and
        (Trang-Thai-Container "bpo-alertmanager") -eq "healthy"
    }
} finally {
    try { [void](Psql "DELETE FROM raw_alerts WHERE event_key='$KhoaKiemThu';") } catch {}
}

if ($SoLoi -gt 0) {
    Ghi-KetQua "[KHÔNG ĐẠT] Giai đoạn K còn $SoLoi lỗi, mã thoát 1."
    exit 1
}

Ghi-KetQua "[ĐẠT] Toàn bộ 5/5 kiểm thử Giai đoạn K đã đạt, mã thoát 0."
exit 0
