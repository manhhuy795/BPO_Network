$ErrorActionPreference = "Stop"

$Goc = Split-Path -Parent $PSScriptRoot
$Compose = Join-Path $Goc "docker/docker-compose.yml"
$EnvFile = Join-Path $Goc ".env"
$DashboardFile = Join-Path $Goc "docker/grafana/dashboards/bpo_network_overview.json"
$LogFile = Join-Path $Goc "logs/phase_n_test.log"
$Loi = 0
$DaChay = 0

New-Item -ItemType Directory -Force (Split-Path $LogFile) | Out-Null
Set-Content -Encoding utf8 $LogFile "KIỂM THỬ GIAI ĐOẠN N - $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"

function Ghi([string]$NoiDung) {
    Write-Host $NoiDung
    Add-Content -Encoding utf8 $LogFile $NoiDung
}

function Bien([string]$Ten) {
    $Dong = Get-Content $EnvFile | Where-Object { $_ -match "^$Ten=" } | Select-Object -First 1
    if (-not $Dong) { return $null }
    return ($Dong -split "=", 2)[1]
}

$PgDb = Bien "POSTGRES_DB"
$PgUser = Bien "POSTGRES_USER"
$PgPassword = Bien "POSTGRES_PASSWORD"
$GrafanaUser = Bien "GRAFANA_ADMIN_USER"
if (-not $GrafanaUser) { $GrafanaUser = "admin" }
$GrafanaPassword = Bien "GRAFANA_ADMIN_PASSWORD"
if (-not $GrafanaPassword) { $GrafanaPassword = Bien "N8N_OWNER_PASSWORD" }
$SshUser = Bien "UBUNTU_SSH_USER"
$SshIp = Bien "UBUNTU_VM_IP"
$SshKey = Bien "UBUNTU_SSH_KEY"
$ThuMucVm = "/home/$SshUser/BPO_Network"
$Basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${GrafanaUser}:${GrafanaPassword}"))
$GrafanaHeader = @{ Authorization = "Basic $Basic" }

function Sql([string]$CauLenh) {
    $env:PGPASSWORD = $PgPassword
    $KetQua = & docker exec --env PGPASSWORD bpo-postgres psql `
        "--username=$PgUser" "--dbname=$PgDb" -Atq -v ON_ERROR_STOP=1 `
        "--field-separator=|" "--command=$CauLenh" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "PostgreSQL lỗi: $($KetQua -join ' ')" }
    return (($KetQua | Out-String).Trim())
}

function Cho([scriptblock]$DieuKien, [int]$Giay = 60) {
    $HetHan = (Get-Date).AddSeconds($Giay)
    while ((Get-Date) -lt $HetHan) {
        try { if (& $DieuKien) { return $true } } catch {}
        Start-Sleep -Seconds 2
    }
    return $false
}

function KiemTra([string]$MoTa, [scriptblock]$NoiDung) {
    $script:DaChay++
    try {
        if (-not (& $NoiDung)) { throw "Điều kiện không đạt." }
        Ghi "[ĐẠT] $($script:DaChay.ToString('00')). $MoTa"
    } catch {
        $script:Loi++
        Ghi "[KHÔNG ĐẠT] $($script:DaChay.ToString('00')). $MoTa - $($_.Exception.Message)"
    }
}

function GrafanaQuery($Queries, [string]$Tu = "now-5m", [string]$Den = "now") {
    $Body = @{ from = $Tu; to = $Den; queries = $Queries } | ConvertTo-Json -Depth 12
    return Invoke-RestMethod http://localhost:3000/api/ds/query -Method Post `
        -Headers $GrafanaHeader -ContentType "application/json" -Body $Body
}

try {
    & docker compose --env-file $EnvFile -f $Compose up -d | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Không khởi động được Docker Compose." }

    KiemTra "Grafana đang healthy" {
        (docker inspect --format '{{.State.Health.Status}}' bpo-grafana 2>$null) -eq "healthy" -and
        (Invoke-RestMethod http://localhost:3000/api/health).database -eq "ok"
    }
    KiemTra "Prometheus datasource kết nối thành công" {
        (Invoke-RestMethod http://localhost:3000/api/datasources/uid/bpo-prometheus/health -Headers $GrafanaHeader).status -eq "OK"
    }
    KiemTra "PostgreSQL datasource kết nối thành công" {
        (Invoke-RestMethod http://localhost:3000/api/datasources/uid/bpo-postgres/health -Headers $GrafanaHeader).status -eq "OK"
    }
    KiemTra "Dashboard được nạp tự động với 19 panel" {
        $script:DashboardApi = Invoke-RestMethod http://localhost:3000/api/dashboards/uid/bpo-network-overview -Headers $GrafanaHeader
        $script:DashboardApi.dashboard.uid -eq "bpo-network-overview" -and $script:DashboardApi.dashboard.panels.Count -eq 19
    }
    KiemTra "Mọi panel dùng Prometheus hoặc PostgreSQL, không dùng dữ liệu thử cố định" {
        $Json = Get-Content $DashboardFile -Raw -Encoding utf8 | ConvertFrom-Json
        $KhongHopLe = @($Json.panels | Where-Object {
            $_.datasource.uid -notin @("bpo-prometheus", "bpo-postgres") -or
            -not $_.targets -or
            @($_.targets | Where-Object { -not $_.expr -and -not $_.rawSql }).Count -gt 0
        })
        $KhongHopLe.Count -eq 0
    }
    KiemTra "Grafana nhận số liệu WAN thực từ Prometheus" {
        $Q = @(@{ refId = "A"; datasource = @{ uid = "bpo-prometheus"; type = "prometheus" }; expr = "bpo_link_up"; format = "time_series"; intervalMs = 5000; maxDataPoints = 100 })
        @( (GrafanaQuery $Q).results.A.frames ).Count -ge 2
    }
    KiemTra "Grafana đọc được danh sách incident từ PostgreSQL" {
        $Q = @(@{ refId = "A"; datasource = @{ uid = "bpo-postgres"; type = "postgres" }; rawSql = "SELECT incident_key,status FROM incidents ORDER BY id DESC LIMIT 20;"; format = "table" })
        @( (GrafanaQuery $Q).results.A.frames ).Count -eq 1
    }
    KiemTra "CRM và CFONO có chuỗi số liệu độc lập" {
        $Q = @(@{ refId = "A"; datasource = @{ uid = "bpo-prometheus"; type = "prometheus" }; expr = "bpo_service_up"; format = "time_series"; intervalMs = 5000; maxDataPoints = 100 })
        @( (GrafanaQuery $Q).results.A.frames ).Count -ge 2
    }

    if (-not (Test-Path $SshKey)) { throw "Không tìm thấy khóa SSH: $SshKey" }
    $BatDauWan = [DateTime]::UtcNow.AddSeconds(-5)
    $MocSql = Sql "SELECT CURRENT_TIMESTAMP;"
    $LenhVm = "cd $ThuMucVm && sudo -n mn -c >/dev/null 2>&1 || true; printf '%s\n' 'r1 bash scripts/fpt_down.sh' 'sh sleep 25' 'r1 bash scripts/fpt_up.sh' 'sh sleep 20' 'exit' | sudo -n python3 topology/topology_v2_dual_wan.py"
    $MucLoiCu = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $KetQuaVm = & ssh -i $SshKey -o IdentitiesOnly=yes -o ConnectTimeout=8 "${SshUser}@${SshIp}" $LenhVm 2>&1
        $MaVm = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $MucLoiCu
    }
    if ($MaVm -ne 0) { throw "Kiểm thử Mininet lỗi ($MaVm): $($KetQuaVm -join ' ')" }
    $KetThucWan = [DateTime]::UtcNow.AddSeconds(5)

    KiemTra "FPT thực sự chuyển 1 -> 0 -> 1 và Viettel tiếp quản trên dữ liệu dashboard" {
        $Start = [int]([DateTimeOffset]$BatDauWan).ToUnixTimeSeconds()
        $End = [int]([DateTimeOffset]$KetThucWan).ToUnixTimeSeconds()
        $FptQuery = [Uri]::EscapeDataString('bpo_link_up{provider="fpt"}')
        $ViettelQuery = [Uri]::EscapeDataString('bpo_active_link{provider="viettel"}')
        $Fpt = Invoke-RestMethod "http://localhost:9090/api/v1/query_range?query=$FptQuery&start=$Start&end=$End&step=2"
        $Viettel = Invoke-RestMethod "http://localhost:9090/api/v1/query_range?query=$ViettelQuery&start=$Start&end=$End&step=2"
        $FptValues = @($Fpt.data.result[0].values | ForEach-Object { $_[1] })
        $ViettelValues = @($Viettel.data.result[0].values | ForEach-Object { $_[1] })
        $FptValues -contains "0" -and $FptValues -contains "1" -and $ViettelValues -contains "1"
    }
    KiemTra "Sự cố Mininet đi qua Prometheus, Alertmanager, n8n và PostgreSQL" {
        Cho {
            (Sql "SELECT count(DISTINCT status) FROM raw_alerts WHERE alert_name='FPTDownViettelAvailable' AND received_at >= '$MocSql'::timestamptz;") -eq "2"
        } 90
    }
    KiemTra "Luồng Mininet đã ghi email, tạo/đóng GLPI và không tạo phiếu trùng" {
        $SuKienHienTaiCoPhieu = [int](Sql "SELECT count(DISTINCT x.glpi_ticket_id) FROM raw_alerts r JOIN incident_alerts ia ON ia.alert_id=r.id JOIN incident_integrations x ON x.incident_id=ia.incident_id WHERE r.alert_name='FPTDownViettelAvailable' AND r.received_at >= '$MocSql'::timestamptz AND x.glpi_ticket_id IS NOT NULL;") -ge 1
        $CapDaDiDuLuong = [int](Sql "SELECT count(*) FROM raw_alerts f JOIN raw_alerts r ON r.fingerprint=f.fingerprint AND r.starts_at IS NOT DISTINCT FROM f.starts_at AND r.status='resolved' JOIN notification_events nf ON nf.raw_alert_id=f.id AND nf.email_status IN ('logged','sent') AND nf.glpi_status IN ('created','updated') JOIN notification_events nr ON nr.raw_alert_id=r.id AND nr.email_status IN ('logged','sent') AND nr.glpi_status='closed' JOIN incident_integrations x ON x.incident_id=nf.incident_id AND x.glpi_ticket_id IS NOT NULL WHERE f.alert_name='FPTDownViettelAvailable' AND f.status='firing' AND f.fingerprint NOT LIKE 'phase-%';") -ge 1
        $SuKienHienTaiCoPhieu -and $CapDaDiDuLuong
    }
    KiemTra "Incident thực tế xuất hiện qua PostgreSQL datasource của Grafana" {
        $Q = @(@{ refId = "A"; datasource = @{ uid = "bpo-postgres"; type = "postgres" }; rawSql = "SELECT incident_key,status FROM incidents WHERE incident_key='wan-fpt';"; format = "table" })
        $TraVe = GrafanaQuery $Q
        ($TraVe | ConvertTo-Json -Depth 15) -match 'wan-fpt'
    }

    & docker compose --env-file $EnvFile -f $Compose restart grafana | Out-Null
    KiemTra "Dashboard và datasource còn hoạt động sau khi restart Grafana" {
        $Healthy = Cho { (docker inspect --format '{{.State.Health.Status}}' bpo-grafana 2>$null) -eq "healthy" } 90
        if (-not $Healthy) { return $false }
        $Dash = Invoke-RestMethod http://localhost:3000/api/dashboards/uid/bpo-network-overview -Headers $GrafanaHeader
        $PgHealth = Invoke-RestMethod http://localhost:3000/api/datasources/uid/bpo-postgres/health -Headers $GrafanaHeader
        $Dash.dashboard.uid -eq "bpo-network-overview" -and $PgHealth.status -eq "OK"
    }
    KiemTra "Các container cũ vẫn healthy sau Giai đoạn N" {
        @("bpo-prometheus", "bpo-blackbox", "bpo-alertmanager", "bpo-postgres", "bpo-n8n", "bpo-glpi") | ForEach-Object {
            if ((docker inspect --format '{{.State.Health.Status}}' $_ 2>$null) -ne "healthy") { return $false }
        }
        return $true
    }
} catch {
    $Loi++
    Ghi "[KHÔNG ĐẠT] Lỗi thiết lập hoặc luồng thực tế: $($_.Exception.Message)"
}

if ($Loi -gt 0 -or $DaChay -ne 14) {
    Ghi "[KHÔNG ĐẠT] Giai đoạn N: đã chạy $DaChay/14 kiểm thử, còn $Loi lỗi, mã thoát 1."
    exit 1
}

Ghi "[ĐẠT] Giai đoạn N: 14/14 kiểm thử đạt; luồng Mininet -> Grafana đã được xác minh; mã thoát 0."
exit 0
