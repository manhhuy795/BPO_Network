param(
    [ValidateSet("O-01", "O-02", "O-03", "O-04", "O-05", "O-06", "O-07", "O-08", "O-09")]
    [string[]]$Only = @()
)

$ErrorActionPreference = "Stop"

$Goc = Split-Path -Parent $PSScriptRoot
$Compose = Join-Path $Goc "docker/docker-compose.yml"
$EnvFile = Join-Path $Goc ".env"
$LogFile = Join-Path $Goc "logs/phase_o_test.log"
$CsvFile = Join-Path $Goc $(if ($Only.Count) { "logs/phase_o_smoke_measurements.csv" } else { "logs/phase_o_measurements.csv" })
$Webhook = "http://localhost:5678/webhook/bpo-alertmanager"
$Loi = 0
$DaChay = 0
$CacDo = @()

New-Item -ItemType Directory -Force (Split-Path $LogFile) | Out-Null
Set-Content -Encoding utf8 $LogFile "KIỂM THỬ TÍCH HỢP GIAI ĐOẠN O - $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"

function Ghi([string]$NoiDung) {
    Write-Host $NoiDung
    Add-Content -Encoding utf8 $LogFile $NoiDung
}

function Bien([string]$Ten, [bool]$BatBuoc = $true) {
    $Dong = Get-Content $EnvFile | Where-Object { $_ -match "^$Ten=" } | Select-Object -First 1
    if (-not $Dong) {
        if ($BatBuoc) { throw "Thiếu biến $Ten trong .env." }
        return $null
    }
    return ($Dong -split "=", 2)[1]
}

$PgDb = Bien "POSTGRES_DB"
$PgUser = Bien "POSTGRES_USER"
$PgPassword = Bien "POSTGRES_PASSWORD"
$SshUser = Bien "UBUNTU_SSH_USER"
$SshIp = Bien "UBUNTU_VM_IP"
$SshKey = Bien "UBUNTU_SSH_KEY"
$VmRoot = "/home/$SshUser/BPO_Network"
$GrafanaUser = Bien "GRAFANA_ADMIN_USER" $false
if (-not $GrafanaUser) { $GrafanaUser = "admin" }
$GrafanaPassword = Bien "GRAFANA_ADMIN_PASSWORD" $false
if (-not $GrafanaPassword) { $GrafanaPassword = Bien "N8N_OWNER_PASSWORD" }
$GlpiUser = Bien "GLPI_API_USER"
$GlpiPassword = Bien "GLPI_API_PASSWORD"
$Basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${GrafanaUser}:${GrafanaPassword}"))
$GrafanaHeader = @{ Authorization = "Basic $Basic" }

function LucNay { return [DateTime]::UtcNow.ToString("o") }

function TinhKhoangGiay($BatDau, $KetThuc) {
    if (-not $BatDau -or -not $KetThuc) { return "N/A" }
    try {
        $SoGiay = ([DateTimeOffset]::Parse([string]$KetThuc) - [DateTimeOffset]::Parse([string]$BatDau)).TotalSeconds
        if ($SoGiay -lt 0) { return "N/A" }
        return [Math]::Round($SoGiay, 3)
    } catch {
        return "N/A"
    }
}

function Sql([string]$CauLenh) {
    $env:PGPASSWORD = $PgPassword
    $KetQua = & docker exec --env PGPASSWORD bpo-postgres psql `
        "--username=$PgUser" "--dbname=$PgDb" -Atq -v ON_ERROR_STOP=1 `
        "--field-separator=|" "--command=$CauLenh" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "PostgreSQL lỗi: $($KetQua -join ' ')" }
    return (($KetQua | Out-String).Trim())
}

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

function Cho([scriptblock]$DieuKien, [int]$Giay = 60, [int]$Nghi = 2) {
    $HetHan = (Get-Date).AddSeconds($Giay)
    while ((Get-Date) -lt $HetHan) {
        try { if (& $DieuKien) { return $true } } catch {}
        Start-Sleep -Seconds $Nghi
    }
    return $false
}

function GiaTriProm([string]$TruyVan) {
    $Q = [Uri]::EscapeDataString($TruyVan)
    $TraVe = Invoke-RestMethod "http://localhost:9090/api/v1/query?query=$Q" -TimeoutSec 10
    if (@($TraVe.data.result).Count -eq 0) { return $null }
    return [double]$TraVe.data.result[0].value[1]
}

function AlertPromDangBan([string]$Ten) {
    return $null -ne (GiaTriProm "ALERTS{alertname=`"$Ten`",alertstate=`"firing`"}")
}

function AlertmanagerDangBan([string]$Ten) {
    $Alerts = @(Invoke-RestMethod http://localhost:9093/api/v2/alerts -TimeoutSec 10)
    return @($Alerts | Where-Object {
        $_.labels.alertname -eq $Ten -and $_.status.state -eq "active"
    }).Count -gt 0
}

function GrafanaProm([string]$TruyVan) {
    $Queries = @(@{
        refId = "A"
        datasource = @{ uid = "bpo-prometheus"; type = "prometheus" }
        expr = $TruyVan
        format = "time_series"
        instant = $true
        range = $false
        intervalMs = 5000
        maxDataPoints = 100
    })
    $Body = @{ from = "now-2m"; to = "now"; queries = $Queries } | ConvertTo-Json -Depth 12
    $TraVe = Invoke-RestMethod http://localhost:3000/api/ds/query -Method Post `
        -Headers $GrafanaHeader -ContentType "application/json" -Body $Body -TimeoutSec 15
    $Khung = @($TraVe.results.A.frames)
    if ($Khung.Count -eq 0) { return $null }
    $GiaTri = @($Khung[0].data.values[1])
    if ($GiaTri.Count -eq 0) { return $null }
    return [double]$GiaTri[-1]
}

function GuiMininet([string]$Lenh) {
    $Ma = [guid]::NewGuid().ToString("N")
    $Marker = "/tmp/bpo_o_ack_$Ma"
    $NoiDung = "$Lenh`nsh touch $Marker`n"
    $Base64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($NoiDung))
    $null = Vm "sudo -n rm -f $Marker; printf '%s' '$Base64' | base64 -d >> /tmp/bpo_phase_o_commands"
    if (-not (Cho { (Vm "test -f $Marker && echo OK") -eq "OK" } 20 1)) {
        throw "Mininet không hoàn tất lệnh: $Lenh"
    }
    $null = Vm "sudo -n rm -f $Marker"
}

function MininetProbe([string]$Lenh) {
    $Ma = [guid]::NewGuid().ToString("N")
    $File = "/tmp/bpo_o_probe_$Ma"
    $LenhDayDu = "$Lenh >$File 2>&1; printf '__RC=%s\n' `$? >>$File"
    GuiMininet $LenhDayDu
    $KetQua = Vm "cat $File; sudo -n rm -f $File"
    return $KetQua
}

function KhoiDongExporter {
    $Lenh = "cd $VmRoot && if ! pgrep -f '^python3 metrics/bpo_exporter.py$' >/dev/null; then nohup python3 metrics/bpo_exporter.py >/tmp/bpo_exporter.log 2>&1 </dev/null & fi"
    $null = Vm $Lenh
    if (-not (Cho {
        (Invoke-WebRequest -UseBasicParsing "http://${SshIp}:9105/health" -TimeoutSec 5).StatusCode -eq 200
    } 30 1)) { throw "Exporter Ubuntu không khởi động lại được." }
}

function KhoiDongTopology {
    $DangChay = $false
    try { $DangChay = (Vm "test -f /tmp/bpo_phase_o_topology.pid && kill -0 `$(cat /tmp/bpo_phase_o_topology.pid) 2>/dev/null && echo OK") -eq "OK" } catch {}
    if (-not $DangChay) {
        $Lenh = "cd $VmRoot; sudo -n mn -c >/tmp/bpo_phase_o_mn_cleanup.log 2>&1 || exit `$?; rm -f /tmp/bpo_phase_o_commands /tmp/bpo_phase_o_topology.pid; : >/tmp/bpo_phase_o_commands; nohup setsid bash -c 'cd $VmRoot && stdbuf -oL tail -n 0 -F /tmp/bpo_phase_o_commands | sudo -n python3 topology/topology_v2_dual_wan.py' >/tmp/bpo_phase_o_topology.log 2>&1 </dev/null & echo `$! >/tmp/bpo_phase_o_topology.pid"
        $null = Vm $Lenh
    }
    if (-not (Cho {
        try {
            $TrangThai = (Invoke-WebRequest -UseBasicParsing "http://${SshIp}:9105/metrics" -TimeoutSec 5).Content
            return $TrangThai -match 'bpo_service_process_up\{service="crm"\} 1' -and
                $TrangThai -match 'bpo_service_process_up\{service="cfono"\} 1'
        } catch { return $false }
    } 60 2)) { throw "Topology chưa khởi động đủ CRM và CFONO." }
}

function KhongCoAlertActive {
    try {
        $Alerts = @(Invoke-RestMethod http://localhost:9093/api/v2/alerts -TimeoutSec 10)
        return @($Alerts | Where-Object { $_.status.state -eq "active" }).Count -eq 0
    } catch { return $false }
}

function PhucHoiNen {
    KhoiDongExporter
    KhoiDongTopology
    GuiMininet "r1 tc qdisc del dev r1-eth1 root 2>/dev/null || true"
    GuiMininet "r1 tc qdisc del dev r1-eth2 root 2>/dev/null || true"
    GuiMininet "r1 bash scripts/viettel_up.sh"
    GuiMininet "r1 bash scripts/fpt_up.sh"
    GuiMininet "srv_crm bash scripts/start_crm.sh"
    GuiMininet "srv_cfono bash scripts/start_cfono.sh"

    $SanSang = Cho {
        (GiaTriProm 'bpo_link_up{provider="fpt"}') -eq 1 -and
        (GiaTriProm 'bpo_link_up{provider="viettel"}') -eq 1 -and
        (GiaTriProm 'bpo_active_link{provider="fpt"}') -eq 1 -and
        (GiaTriProm 'bpo_service_process_up{service="crm"}') -eq 1 -and
        (GiaTriProm 'bpo_service_process_up{service="cfono"}') -eq 1 -and
        (GiaTriProm 'probe_success{service="crm"}') -eq 1 -and
        (GiaTriProm 'probe_success{service="cfono"}') -eq 1
    } 90 2
    if (-not $SanSang) { throw "Không khôi phục được metric nền." }

    $HttpCrm = MininetProbe "pc_du_an_1 curl -fsS --max-time 3 http://172.16.100.10"
    $HttpCfono = MininetProbe "pc_du_an_1 curl -fsS --max-time 3 http://172.16.100.20"
    if ($HttpCrm -notmatch '__RC=0' -or $HttpCfono -notmatch '__RC=0') {
        throw "CRM hoặc CFONO chưa truy cập được từ máy dự án."
    }
    if (-not (Cho { (KhongCoAlertActive) -and (Sql "SELECT count(*) FROM incidents WHERE status='open';") -eq "0" } 120 2)) {
        throw "Còn cảnh báo hoặc incident mở sau phục hồi nền."
    }
}

function TaoDongDo([string]$Ma, [string]$Ten) {
    return [ordered]@{
        ma_kiem_thu = $Ma
        ten_tinh_huong = $Ten
        thoi_gian_bat_dau = LucNay
        thoi_gian_phat_hien = ""
        thoi_gian_tao_canh_bao = ""
        thoi_gian_tao_incident = ""
        thoi_gian_tao_phieu = ""
        thoi_gian_phuc_hoi = ""
        raw_alert_received_at = ""
        incident_resolved_at = ""
        time_to_detect_seconds = "N/A"
        time_to_incident_seconds = "N/A"
        time_to_ticket_seconds = "N/A"
        time_to_correlate_seconds = "N/A"
        time_to_resolve_seconds = "N/A"
        so_canh_bao_goc = 0
        so_incident = 0
        so_phieu_glpi = 0
        so_alert_accepted = 0
        so_alert_duplicate = 0
        so_incident_created = 0
        so_incident_updated = 0
        so_ticket_created = 0
        so_ticket_updated = 0
        so_ticket_reused = 0
        so_ticket_failed = 0
        so_incident_trung_tranh = 0
        so_ticket_trung_tranh = 0
        ket_qua = "KHÔNG ĐẠT"
        ghi_chu = ""
    }
}

function DienMocDatabase($Dong, [string]$MocSql) {
    $SqlMoc = @"
SELECT
  COALESCE((min(r.received_at) FILTER (WHERE r.status='firing'))::text,''),
  COALESCE((min(e.created_at) FILTER (WHERE e.event_type IN ('opened','reopened','updated')))::text,''),
  COALESCE((min(n.glpi_completed_at) FILTER (WHERE n.glpi_status IN ('created','updated')))::text,''),
  COALESCE((max(e.created_at) FILTER (WHERE e.event_type='alert_resolved'))::text,''),
  count(DISTINCT r.id),
  count(DISTINCT ia.incident_id),
  count(DISTINCT x.glpi_ticket_id),
  count(DISTINCT e.id) FILTER (WHERE e.event_type='opened'),
  count(DISTINCT e.id) FILTER (WHERE e.event_type IN ('reopened','updated')),
  count(DISTINCT n.id) FILTER (WHERE n.glpi_status='created'),
  count(DISTINCT n.id) FILTER (WHERE n.glpi_status='updated'),
  count(DISTINCT n.id) FILTER (WHERE n.glpi_status='updated'),
  count(DISTINCT n.id) FILTER (WHERE n.glpi_status='failed')
FROM raw_alerts r
LEFT JOIN incident_alerts ia ON ia.alert_id=r.id
LEFT JOIN incident_events e ON e.event_data->>'raw_alert_id'=r.id::text
LEFT JOIN notification_events n ON n.raw_alert_id=r.id
LEFT JOIN incident_integrations x ON x.incident_id=ia.incident_id
WHERE r.received_at >= '$MocSql'::timestamptz;
"@
    $Cot = (Sql $SqlMoc) -split '\|'
    if ($Cot.Count -ge 13) {
        $Dong.raw_alert_received_at = $Cot[0]
        if (-not $Dong.thoi_gian_tao_incident) { $Dong.thoi_gian_tao_incident = $Cot[1] }
        if (-not $Dong.thoi_gian_tao_phieu) { $Dong.thoi_gian_tao_phieu = $Cot[2] }
        $Dong.incident_resolved_at = $Cot[3]
        $Dong.so_canh_bao_goc = [int]$Cot[4]
        $Dong.so_incident = [int]$Cot[5]
        $Dong.so_phieu_glpi = [int]$Cot[6]
        $Dong.so_alert_accepted = [int]$Cot[4]
        $Dong.so_incident_created = [int]$Cot[7]
        $Dong.so_incident_updated = [int]$Cot[8]
        $Dong.so_ticket_created = [int]$Cot[9]
        $Dong.so_ticket_updated = [int]$Cot[10]
        $Dong.so_ticket_reused = [int]$Cot[11]
        $Dong.so_ticket_failed = [int]$Cot[12]
        $Dong.time_to_detect_seconds = TinhKhoangGiay $Dong.thoi_gian_bat_dau $Dong.thoi_gian_phat_hien
        $Dong.time_to_incident_seconds = TinhKhoangGiay $Dong.thoi_gian_bat_dau $Dong.thoi_gian_tao_incident
        $Dong.time_to_ticket_seconds = TinhKhoangGiay $Dong.thoi_gian_bat_dau $Dong.thoi_gian_tao_phieu
        $Dong.time_to_correlate_seconds = TinhKhoangGiay $Dong.raw_alert_received_at $Dong.thoi_gian_tao_incident
        $Dong.time_to_resolve_seconds = TinhKhoangGiay $Dong.thoi_gian_bat_dau $Dong.incident_resolved_at
    }
}

function LuuCsv {
    $CacDo | ForEach-Object { [pscustomobject]$_ } | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding UTF8
}

function ChayTinhHuong([string]$Ma, [string]$Ten, [scriptblock]$NoiDung) {
    if ($Only.Count -and $Ma -notin $Only) { return }
    $script:DaChay++
    $Dong = TaoDongDo $Ma $Ten
    $NguCanh = [ordered]@{ MocSql = ""; BoQuaMocDatabase = $false }
    $Dat = $false
    try {
        PhucHoiNen
        $NguCanh.MocSql = Sql "SELECT CURRENT_TIMESTAMP;"
        $Dong.thoi_gian_bat_dau = LucNay
        & $NoiDung $Dong $NguCanh
        $Dat = $true
    } catch {
        $Dong.ghi_chu = $_.Exception.Message
    } finally {
        try {
            PhucHoiNen
            if (-not $Dong.thoi_gian_phuc_hoi) { $Dong.thoi_gian_phuc_hoi = LucNay }
        } catch {
            $Dat = $false
            $Dong.ghi_chu = (($Dong.ghi_chu + "; lỗi phục hồi: " + $_.Exception.Message).Trim(';', ' '))
        }
        if ($NguCanh.MocSql -and -not $NguCanh.BoQuaMocDatabase) {
            try { DienMocDatabase $Dong $NguCanh.MocSql } catch {
                $Dat = $false
                $Dong.ghi_chu = (($Dong.ghi_chu + "; lỗi đo DB: " + $_.Exception.Message).Trim(';', ' '))
            }
        }
    }
    if ($Dat -and $Ma -eq "O-01" -and (
        $null -eq $Dong.time_to_incident_seconds -or $Dong.time_to_incident_seconds -eq "N/A" -or
        $null -eq $Dong.time_to_ticket_seconds -or $Dong.time_to_ticket_seconds -eq "N/A"
    )) {
        $Dat = $false
        $Dong.ghi_chu = "Time to Incident hoặc Time to Ticket chưa được tính từ timestamp thật."
    }
    if ($Dat -and $Ma -eq "O-07" -and (
        $Dong.so_alert_duplicate -ne 2 -or
        $Dong.so_incident_trung_tranh -ne 2 -or
        $Dong.so_ticket_trung_tranh -ne 2 -or
        $Dong.time_to_incident_seconds -ne "N/A" -or
        $Dong.time_to_ticket_seconds -ne "N/A"
    )) {
        $Dat = $false
        $Dong.ghi_chu = "Số duplicate chưa lấy từ response/DB thật hoặc timestamp thiếu chưa trả N/A."
    }
    if ($Dat) {
        $Dong.ket_qua = "ĐẠT"
        if (-not $Dong.ghi_chu) { $Dong.ghi_chu = "Có bằng chứng từ metric, API và PostgreSQL." }
        Ghi "[ĐẠT] $Ma - $Ten"
    } else {
        $script:Loi++
        Ghi "[KHÔNG ĐẠT] $Ma - $Ten - $($Dong.ghi_chu)"
    }
    $script:CacDo += $Dong
    LuuCsv
}

function MoPhienGlpi {
    $Chuoi = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${GlpiUser}:${GlpiPassword}"))
    return Invoke-RestMethod http://localhost:8080/apirest.php/initSession -Headers @{ Authorization = "Basic $Chuoi" }
}

function KiemTraTrangThaiBanDau {
    & docker compose --env-file $EnvFile -f $Compose up -d | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose không khởi động được." }
    $Containers = @(
        "bpo-prometheus", "bpo-blackbox", "bpo-alertmanager", "bpo-postgres",
        "bpo-n8n", "bpo-glpi-db", "bpo-glpi", "bpo-grafana"
    )
    if (-not (Cho {
        foreach ($Container in $Containers) {
            if ((docker inspect --format '{{.State.Health.Status}}' $Container 2>$null) -ne "healthy") { return $false }
        }
        return $true
    } 120 2)) { throw "Có container chưa healthy." }
    if (-not (Test-Path $SshKey)) { throw "Không tìm thấy khóa SSH $SshKey." }
    if ((Vm "echo OK") -ne "OK") { throw "Windows chưa SSH được tới Ubuntu." }
    KhoiDongTopology
    KhoiDongExporter
    if ((Invoke-WebRequest -UseBasicParsing "http://${SshIp}:9105/health" -TimeoutSec 8).StatusCode -ne 200) { throw "Exporter /health lỗi." }
    $Metrics = (Invoke-WebRequest -UseBasicParsing "http://${SshIp}:9105/metrics" -TimeoutSec 8).Content
    if ($Metrics -notmatch 'bpo_exporter_up 1') { throw "Exporter /metrics thiếu bpo_exporter_up." }
    $Targets = (Invoke-RestMethod http://localhost:9090/api/v1/targets).data.activeTargets
    $Target = $Targets | Where-Object { $_.labels.job -eq "bpo_exporter" }
    if (-not $Target -or $Target.health -ne "up") { throw "Prometheus target bpo_exporter chưa UP." }
    if ((Sql "SELECT count(*) FROM n8n.workflow_entity WHERE id IN ('bpoAlertFlow01','bpoNotifyTicket01') AND active;") -ne "2") {
        throw "Hai workflow n8n chưa active."
    }
    try {
        $null = Invoke-RestMethod $Webhook -Method Post -ContentType "application/json" `
            -Body '{"receiver":"phase-o-precheck","status":"resolved","alerts":[]}' -TimeoutSec 15
    } catch {
        $MaHttp = $null
        if ($_.Exception.Response) { $MaHttp = [int]$_.Exception.Response.StatusCode }
        if ($MaHttp -eq 404) { throw "Workflow active trong DB nhưng webhook n8n chưa đăng ký runtime." }
    }
    @(
        "http://localhost:9093/-/healthy", "http://localhost:5678/healthz",
        "http://localhost:8080", "http://localhost:3000/api/health"
    ) | ForEach-Object {
        if ((Invoke-WebRequest -UseBasicParsing $_ -TimeoutSec 10).StatusCode -ne 200) { throw "Endpoint $_ chưa sẵn sàng." }
    }
    $Dash = Invoke-RestMethod http://localhost:3000/api/dashboards/uid/bpo-network-overview -Headers $GrafanaHeader
    if ($Dash.dashboard.panels.Count -ne 19) { throw "Dashboard Grafana không đủ 19 panel." }
    PhucHoiNen
    Ghi "[ĐẠT] Trạng thái ban đầu: topology chạy; hai WAN, CRM/CFONO và toàn bộ chuỗi giám sát sẵn sàng."
}

try {
    KiemTraTrangThaiBanDau
} catch {
    Ghi "[KHÔNG ĐẠT] Trạng thái ban đầu chưa đạt: $($_.Exception.Message)"
    Ghi "[KHÔNG ĐẠT] Dừng trước khi gây sự cố, mã thoát 2."
    exit 2
}
$MocToanBo = Sql "SELECT CURRENT_TIMESTAMP;"

ChayTinhHuong "O-01" "FPT mất, Viettel còn hoạt động" {
    param($Dong, $Ctx)
    GuiMininet "r1 bash scripts/fpt_down.sh"
    if (-not (Cho {
        (GiaTriProm 'bpo_link_up{provider="fpt"}') -eq 0 -and
        (GiaTriProm 'bpo_active_link{provider="viettel"}') -eq 1
    } 35 1)) { throw "Prometheus không ghi nhận failover sang Viettel." }
    $Dong.thoi_gian_phat_hien = LucNay

    $Crm = MininetProbe "pc_du_an_1 curl -fsS --max-time 3 http://172.16.100.10"
    $Cfono = MininetProbe "pc_du_an_1 curl -fsS --max-time 3 http://172.16.100.20"
    if ($Crm -notmatch '__RC=0' -or $Cfono -notmatch '__RC=0') {
        throw "CRM hoặc CFONO không duy trì được qua Viettel."
    }
    if (-not (Cho {
        (AlertPromDangBan "FPTDownViettelAvailable") -and
        (AlertmanagerDangBan "FPTDownViettelAvailable")
    } 50 2)) { throw "Không xuất hiện cảnh báo FPTDownViettelAvailable." }
    $Dong.thoi_gian_tao_canh_bao = LucNay

    $SqlXacMinh = "SELECT count(*) FROM raw_alerts r JOIN incident_alerts ia ON ia.alert_id=r.id JOIN incidents i ON i.id=ia.incident_id WHERE r.received_at >= '$($Ctx.MocSql)'::timestamptz AND r.alert_name='FPTDownViettelAvailable' AND r.status='firing' AND i.incident_key='wan-fpt';"
    if (-not (Cho { (Sql $SqlXacMinh) -eq "1" } 60 2)) {
        throw "n8n chưa tạo đúng incident wan-fpt."
    }
    $SqlThongBao = "SELECT count(*) FROM raw_alerts r JOIN notification_events n ON n.raw_alert_id=r.id WHERE r.received_at >= '$($Ctx.MocSql)'::timestamptz AND r.alert_name='FPTDownViettelAvailable' AND r.status='firing' AND n.email_status IN ('logged','sent') AND n.glpi_status IN ('created','updated');"
    if (-not (Cho { (Sql $SqlThongBao) -eq "1" } 60 2)) {
        throw "Email thử nghiệm hoặc GLPI chưa xử lý đúng một cảnh báo FPT."
    }
    $SaiNguCanh = Sql "SELECT count(*) FROM incidents WHERE status='open' AND incident_key IN ('wan-total','service-crm','service-cfono');"
    if ($SaiNguCanh -ne "0") { throw "Đã tạo sai incident WAN tổng hoặc dịch vụ." }
    $SoPhieu = Sql "SELECT count(DISTINCT x.glpi_ticket_id) FROM raw_alerts r JOIN incident_alerts ia ON ia.alert_id=r.id JOIN incident_integrations x ON x.incident_id=ia.incident_id WHERE r.received_at >= '$($Ctx.MocSql)'::timestamptz AND r.alert_name='FPTDownViettelAvailable' AND x.glpi_ticket_id IS NOT NULL;"
    if ($SoPhieu -ne "1") { throw "Sự cố FPT không liên kết đúng một phiếu GLPI." }
    if ((GrafanaProm 'bpo_active_link{provider="viettel"}') -ne 1) {
        throw "Grafana datasource chưa phản ánh Viettel là đường active."
    }
    $TrangThai = (Vm "cat $VmRoot/runtime/wan_status.json") | ConvertFrom-Json
    $Dong.ghi_chu = "Failover thực tế $($TrangThai.failover_duration_seconds) giây; một email firing và một phiếu GLPI."
}

ChayTinhHuong "O-02" "Cả FPT và Viettel cùng mất" {
    param($Dong, $Ctx)
    GuiMininet "r1 bash scripts/fpt_down.sh"
    GuiMininet "r1 bash scripts/viettel_down.sh"
    if (-not (Cho {
        (GiaTriProm 'bpo_link_up{provider="fpt"}') -eq 0 -and
        (GiaTriProm 'bpo_link_up{provider="viettel"}') -eq 0
    } 35 1)) { throw "Prometheus chưa ghi nhận cả hai WAN mất." }
    $Dong.thoi_gian_phat_hien = LucNay

    $Crm = MininetProbe "pc_du_an_1 curl -fsS --max-time 3 http://172.16.100.10"
    $Cfono = MininetProbe "pc_du_an_1 curl -fsS --max-time 3 http://172.16.100.20"
    $Gateway = MininetProbe "pc_du_an_1 ping -c 1 -W 1 10.10.20.1"
    if ($Crm -match '__RC=0' -or $Cfono -match '__RC=0' -or $Gateway -notmatch '__RC=0') {
        throw "Trạng thái truy cập dịch vụ hoặc gateway VLAN không đúng khi hai WAN mất."
    }
    if (-not (Cho {
        (AlertPromDangBan "BothWANDown") -and (AlertmanagerDangBan "BothWANDown")
    } 50 2)) { throw "Không xuất hiện BothWANDown." }
    $Dong.thoi_gian_tao_canh_bao = LucNay
    if (AlertPromDangBan "FPTDownViettelAvailable") {
        throw "FPTDownViettelAvailable vẫn firing khi cả hai WAN mất."
    }
    if (-not (Cho {
        (Sql "SELECT count(*) FROM raw_alerts r JOIN incident_alerts ia ON ia.alert_id=r.id JOIN incidents i ON i.id=ia.incident_id WHERE r.received_at >= '$($Ctx.MocSql)'::timestamptz AND r.alert_name='BothWANDown' AND r.status='firing' AND i.incident_key='wan-total' AND i.status='open' AND i.severity='cao';") -eq "1"
    } 60 2)) { throw "n8n chưa tạo incident wan-total mức cao." }
    if ((GrafanaProm 'bpo_link_up{provider="fpt"}') -ne 0 -or
        (GrafanaProm 'bpo_link_up{provider="viettel"}') -ne 0) {
        throw "Grafana datasource chưa phản ánh cả hai WAN mất."
    }

    # Tắt tiến trình dịch vụ thật trong khi wan-total đang mở để kiểm chứng gom triệu chứng.
    GuiMininet "srv_crm bash scripts/stop_crm.sh"
    GuiMininet "srv_cfono bash scripts/stop_cfono.sh"
    if (-not (Cho {
        (Sql "SELECT count(DISTINCT r.alert_name) FROM raw_alerts r JOIN incident_alerts ia ON ia.alert_id=r.id JOIN incidents i ON i.id=ia.incident_id WHERE r.received_at >= '$($Ctx.MocSql)'::timestamptz AND r.status='firing' AND r.alert_name IN ('CRMDown','CFONODown') AND i.incident_key='wan-total';") -eq "2"
    } 65 2)) { throw "CRMDown/CFONODown chưa được gom vào wan-total." }
    if ((Sql "SELECT count(*) FROM incidents WHERE status='open' AND incident_key IN ('service-crm','service-cfono');") -ne "0") {
        throw "Đã mở incident dịch vụ riêng trong khi wan-total đang mở."
    }
    $SoPhieu = Sql "SELECT count(DISTINCT x.glpi_ticket_id) FROM raw_alerts r JOIN incident_alerts ia ON ia.alert_id=r.id JOIN incident_integrations x ON x.incident_id=ia.incident_id WHERE r.received_at >= '$($Ctx.MocSql)'::timestamptz AND x.glpi_ticket_id IS NOT NULL;"
    if ($SoPhieu -ne "1") { throw "Các triệu chứng WAN tổng tạo nhiều hơn một phiếu GLPI." }

    GuiMininet "srv_crm bash scripts/start_crm.sh"
    GuiMininet "srv_cfono bash scripts/start_cfono.sh"
    GuiMininet "r1 bash scripts/viettel_up.sh"
    GuiMininet "r1 bash scripts/fpt_up.sh"
    if (-not (Cho {
        (Sql "SELECT status FROM incidents WHERE incident_key='wan-total';") -eq "resolved" -and
        (Sql "SELECT glpi_status FROM incident_integrations x JOIN incidents i ON i.id=x.incident_id WHERE i.incident_key='wan-total';") -eq "closed"
    } 120 2)) { throw "wan-total hoặc phiếu GLPI chưa đóng sau phục hồi." }
    $Dong.thoi_gian_phuc_hoi = LucNay
    $Dong.ghi_chu = "BothWANDown là cảnh báo chính; CRM/CFONO được gây dừng thật để kiểm chứng gom triệu chứng vào một phiếu."
}

ChayTinhHuong "O-03" "FPT phục hồi và failback ổn định" {
    param($Dong, $Ctx)
    GuiMininet "r1 bash scripts/fpt_down.sh"
    if (-not (Cho {
        (GiaTriProm 'bpo_active_link{provider="viettel"}') -eq 1 -and
        (Sql "SELECT status FROM incidents WHERE incident_key='wan-fpt';") -eq "open"
    } 70 2)) { throw "Không tạo được trạng thái FPT mất để kiểm thử phục hồi." }
    $TicketCu = Sql "SELECT glpi_ticket_id FROM incident_integrations x JOIN incidents i ON i.id=x.incident_id WHERE i.incident_key='wan-fpt';"
    $Ctx.MocSql = Sql "SELECT CURRENT_TIMESTAMP;"
    $Dong.thoi_gian_bat_dau = LucNay
    GuiMininet "r1 bash scripts/fpt_up.sh"
    if (-not (Cho { (GiaTriProm 'bpo_active_link{provider="fpt"}') -eq 1 } 40 1)) {
        throw "Không failback về FPT."
    }
    $Dong.thoi_gian_phat_hien = LucNay
    $TrangThai = (Vm "cat $VmRoot/runtime/wan_status.json") | ConvertFrom-Json
    if ([double]$TrangThai.failback_duration_seconds -lt 7) {
        throw "Failback xảy ra trước đủ chu kỳ ổn định cấu hình."
    }
    if (-not (Cho {
        (Sql "SELECT status FROM incidents WHERE incident_key='wan-fpt';") -eq "resolved" -and
        (Sql "SELECT glpi_status FROM incident_integrations x JOIN incidents i ON i.id=x.incident_id WHERE i.incident_key='wan-fpt';") -eq "closed"
    } 90 2)) { throw "Incident hoặc GLPI FPT chưa đóng khi resolved." }
    $Dong.thoi_gian_tao_canh_bao = Sql "SELECT min(received_at) FROM raw_alerts WHERE received_at >= '$($Ctx.MocSql)'::timestamptz AND alert_name='FPTDownViettelAvailable' AND status='resolved';"
    $TicketMoi = Sql "SELECT glpi_ticket_id FROM incident_integrations x JOIN incidents i ON i.id=x.incident_id WHERE i.incident_key='wan-fpt';"
    if (-not $TicketCu -or $TicketCu -ne $TicketMoi) { throw "Phục hồi tạo hoặc liên kết sai phiếu GLPI." }
    if ((Sql "SELECT count(*) FROM incident_integrations x JOIN incidents i ON i.id=x.incident_id WHERE i.incident_key='wan-fpt';") -ne "1") {
        throw "Có nhiều liên kết GLPI cho wan-fpt."
    }
    if ((GrafanaProm 'bpo_active_link{provider="fpt"}') -ne 1) {
        throw "Grafana chưa phản ánh FPT đã active trở lại."
    }
    $Dong.thoi_gian_phuc_hoi = LucNay
    $Dong.ghi_chu = "Failback $($TrangThai.failback_duration_seconds) giây, dùng lại và đóng phiếu GLPI #$TicketMoi."
}

function ThuDichVuDocLap($Dong, $Ctx, [string]$DichVu, [string]$PromAlertName, [string]$AlertName, [string]$DichVuConLai, [string]$IncidentKey, [string]$Node) {
    GuiMininet "$Node bash scripts/stop_$DichVu.sh"
    if (-not (Cho {
        (GiaTriProm "bpo_service_process_up{service=`"$DichVu`"}") -eq 0 -and
        (GiaTriProm "bpo_service_process_up{service=`"$DichVuConLai`"}") -eq 1 -and
        (GiaTriProm 'bpo_link_up{provider="fpt"}') -eq 1 -and
        (GiaTriProm 'bpo_link_up{provider="viettel"}') -eq 1
    } 30 1)) { throw "Metric $DichVu không chuyển xuống độc lập." }
    $Dong.thoi_gian_phat_hien = LucNay
    if (-not (Cho { (AlertPromDangBan $PromAlertName) -and (AlertmanagerDangBan $AlertName) } 50 2)) {
        throw "Không xuất hiện $PromAlertName hoặc cảnh báo tương thích $AlertName."
    }
    $Dong.thoi_gian_tao_canh_bao = LucNay
    if (-not (Cho {
        (Sql "SELECT count(*) FROM raw_alerts r JOIN incident_alerts ia ON ia.alert_id=r.id JOIN incidents i ON i.id=ia.incident_id WHERE r.received_at >= '$($Ctx.MocSql)'::timestamptz AND r.alert_name='$AlertName' AND r.status='firing' AND i.incident_key='$IncidentKey';") -eq "1"
    } 60 2)) { throw "Không tạo đúng incident $IncidentKey." }
    if ((Sql "SELECT count(*) FROM incidents WHERE status='open' AND (incident_key LIKE 'wan-%' OR incident_key='service-$DichVuConLai');") -ne "0") {
        throw "Sự cố độc lập làm mở sai incident WAN hoặc dịch vụ còn lại."
    }
    if (-not (Cho {
        (Sql "SELECT count(DISTINCT x.glpi_ticket_id) FROM raw_alerts r JOIN incident_alerts ia ON ia.alert_id=r.id JOIN incident_integrations x ON x.incident_id=ia.incident_id WHERE r.received_at >= '$($Ctx.MocSql)'::timestamptz AND r.alert_name='$AlertName' AND x.glpi_ticket_id IS NOT NULL;") -eq "1"
    } 60 2)) { throw "Incident $IncidentKey chưa có đúng một phiếu GLPI." }

    GuiMininet "$Node bash scripts/start_$DichVu.sh"
    if (-not (Cho {
        (Sql "SELECT status FROM incidents WHERE incident_key='$IncidentKey';") -eq "resolved" -and
        (Sql "SELECT glpi_status FROM incident_integrations x JOIN incidents i ON i.id=x.incident_id WHERE i.incident_key='$IncidentKey';") -eq "closed"
    } 90 2)) { throw "Incident $IncidentKey hoặc phiếu chưa đóng khi dịch vụ phục hồi." }
    $Dong.thoi_gian_phuc_hoi = LucNay
    $Ticket = Sql "SELECT glpi_ticket_id FROM incident_integrations x JOIN incidents i ON i.id=x.incident_id WHERE i.incident_key='$IncidentKey';"
    $Dong.ghi_chu = "$AlertName độc lập, dịch vụ còn lại không ảnh hưởng, phiếu GLPI #$Ticket đã đóng."
}

ChayTinhHuong "O-04" "CRM mất độc lập" {
    param($Dong, $Ctx)
    ThuDichVuDocLap $Dong $Ctx "crm" "CRMProcessDown" "CRMDown" "cfono" "service-crm" "srv_crm"
}

ChayTinhHuong "O-05" "CFONO mất độc lập" {
    param($Dong, $Ctx)
    ThuDichVuDocLap $Dong $Ctx "cfono" "CFONOProcessDown" "CFONODown" "crm" "service-cfono" "srv_cfono"
}

ChayTinhHuong "O-06" "Exporter Ubuntu dừng" {
    param($Dong, $Ctx)
    $null = Vm "pkill -f '^python3 metrics/bpo_exporter.py$'"
    if (-not (Cho {
        $Targets = (Invoke-RestMethod http://localhost:9090/api/v1/targets -TimeoutSec 10).data.activeTargets
        $Target = $Targets | Where-Object { $_.labels.job -eq "bpo_exporter" }
        $Target.health -eq "down"
    } 35 1)) { throw "Prometheus target không chuyển DOWN khi exporter dừng." }
    $Dong.thoi_gian_phat_hien = LucNay
    if (-not (Cho { (AlertPromDangBan "BPOExporterDown") -and (AlertmanagerDangBan "BPOExporterDown") } 50 2)) {
        throw "Không xuất hiện BPOExporterDown."
    }
    $Dong.thoi_gian_tao_canh_bao = LucNay
    if (-not (Cho {
        (Sql "SELECT count(*) FROM raw_alerts r JOIN incident_alerts ia ON ia.alert_id=r.id JOIN incidents i ON i.id=ia.incident_id WHERE r.received_at >= '$($Ctx.MocSql)'::timestamptz AND r.alert_name='BPOExporterDown' AND r.status='firing' AND i.incident_key='monitoring-exporter';") -eq "1"
    } 60 2)) { throw "n8n chưa tạo monitoring-exporter." }
    if ((Sql "SELECT count(*) FROM incidents WHERE status='open' AND incident_key IN ('wan-fpt','wan-total');") -ne "0") {
        throw "Exporter dừng bị kết luận sai là mất Internet."
    }
    KhoiDongExporter
    if (-not (Cho {
        $Targets = (Invoke-RestMethod http://localhost:9090/api/v1/targets -TimeoutSec 10).data.activeTargets
        $Target = $Targets | Where-Object { $_.labels.job -eq "bpo_exporter" }
        $Target.health -eq "up" -and
        (Sql "SELECT status FROM incidents WHERE incident_key='monitoring-exporter';") -eq "resolved"
    } 90 2)) { throw "Exporter hoặc incident chưa phục hồi."
    }
    if (-not (Cho {
        (Sql "SELECT glpi_status FROM incident_integrations x JOIN incidents i ON i.id=x.incident_id WHERE i.incident_key='monitoring-exporter';") -eq "closed"
    } 60 2)) {
        throw "Phiếu GLPI exporter chưa đóng."
    }
    $Dong.thoi_gian_phuc_hoi = LucNay
    $Dong.ghi_chu = "Target DOWN/UP đúng; không tạo incident WAN; monitoring-exporter và GLPI đã đóng."
}

ChayTinhHuong "O-07" "Cảnh báo trùng" {
    param($Dong, $Ctx)
    # O-07 không tạo raw alert mới; số liệu lấy từ response và chênh lệch DB riêng bên dưới.
    $Ctx.BoQuaMocDatabase = $true
    $PayloadJson = Sql "SELECT jsonb_build_object('receiver','n8n_bpo','status',payload->>'status','alerts',jsonb_build_array(payload->'alert'))::text FROM raw_alerts WHERE status='firing' AND alert_name IN ('CRMDown','CFONODown') AND fingerprint NOT LIKE 'phase-%' ORDER BY id DESC LIMIT 1;"
    if (-not $PayloadJson) { throw "Không tìm thấy payload cảnh báo thật để phát lại." }
    $RawTruoc = [int](Sql "SELECT count(*) FROM raw_alerts;")
    $IncidentTruoc = [int](Sql "SELECT count(*) FROM incidents;")
    $AlertCountTruoc = [int](Sql "SELECT COALESCE(sum(alert_count),0) FROM incidents;")
    $ThongBaoTruoc = [int](Sql "SELECT count(*) FROM notification_events;")
    $PhieuTruoc = [int](Sql "SELECT count(*) FROM incident_integrations;")
    $TraVe1 = Invoke-RestMethod $Webhook -Method Post -ContentType "application/json; charset=utf-8" -Body $PayloadJson -TimeoutSec 30
    $TraVe2 = Invoke-RestMethod $Webhook -Method Post -ContentType "application/json; charset=utf-8" -Body $PayloadJson -TimeoutSec 30
    Start-Sleep -Seconds 5
    $SoDuplicate = @($TraVe1, $TraVe2 | Where-Object { $_.status -eq "duplicate" }).Count
    $RawSau = [int](Sql "SELECT count(*) FROM raw_alerts;")
    $IncidentSau = [int](Sql "SELECT count(*) FROM incidents;")
    $AlertCountSau = [int](Sql "SELECT COALESCE(sum(alert_count),0) FROM incidents;")
    $ThongBaoSau = [int](Sql "SELECT count(*) FROM notification_events;")
    $PhieuSau = [int](Sql "SELECT count(*) FROM incident_integrations;")
    if ($SoDuplicate -ne 2) { throw "n8n không trả đủ hai trạng thái duplicate." }
    if ($RawSau -ne $RawTruoc -or $IncidentSau -ne $IncidentTruoc -or $AlertCountSau -ne $AlertCountTruoc -or
        $ThongBaoSau -ne $ThongBaoTruoc -or $PhieuSau -ne $PhieuTruoc) {
        throw "Payload trùng làm thay đổi raw alert, alert_count, email hoặc phiếu."
    }
    $Dong.thoi_gian_phat_hien = LucNay
    $Dong.so_alert_duplicate = $SoDuplicate
    $Dong.so_incident_trung_tranh = $SoDuplicate
    $Dong.so_ticket_trung_tranh = $SoDuplicate
    $Dong.ghi_chu = "Response duplicate=$SoDuplicate; chênh lệch DB raw=$($RawSau-$RawTruoc), incident=$($IncidentSau-$IncidentTruoc), alert_count=$($AlertCountSau-$AlertCountTruoc), notification=$($ThongBaoSau-$ThongBaoTruoc), ticket=$($PhieuSau-$PhieuTruoc)."
}

ChayTinhHuong "O-08" "Chất lượng đường truyền FPT suy giảm" {
    param($Dong, $Ctx)
    GuiMininet "r1 tc qdisc replace dev r1-eth1 root netem delay 180ms loss 40%"
    if (-not (Cho {
        $Tre = GiaTriProm 'bpo_ping_rtt_avg_ms{provider="fpt"}'
        $Mat = GiaTriProm 'bpo_packet_loss_percent{provider="fpt"}'
        $Link = GiaTriProm 'bpo_link_up{provider="fpt"}'
        $null -ne $Tre -and $null -ne $Mat -and $Tre -gt 100 -and $Mat -gt 20 -and $Link -eq 1
    } 80 2)) { throw "Metric thật chưa đồng thời thể hiện độ trễ và mất gói cao khi link vẫn UP." }
    $Dong.thoi_gian_phat_hien = LucNay
    if (-not (Cho {
        (AlertPromDangBan "HighLatency") -and (AlertPromDangBan "HighPacketLoss") -and
        (AlertmanagerDangBan "HighLatency") -and (AlertmanagerDangBan "HighPacketLoss")
    } 150 2)) { throw "HighLatency và HighPacketLoss không cùng firing cho FPT." }
    $Dong.thoi_gian_tao_canh_bao = LucNay
    if (-not (Cho {
        (Sql "SELECT count(DISTINCT r.alert_name) FROM raw_alerts r JOIN incident_alerts ia ON ia.alert_id=r.id JOIN incidents i ON i.id=ia.incident_id WHERE r.received_at >= '$($Ctx.MocSql)'::timestamptz AND r.status='firing' AND r.alert_name IN ('HighLatency','HighPacketLoss') AND r.provider='fpt' AND i.incident_key='wan-quality:fpt';") -eq "2"
    } 70 2)) { throw "Hai cảnh báo chất lượng chưa gom vào wan-quality:fpt." }
    if ((Sql "SELECT count(*) FROM incidents WHERE status='open' AND (incident_key='wan-total' OR incident_key='wan-quality:viettel');") -ne "0") {
        throw "Suy giảm FPT bị gom sai sang WAN tổng hoặc Viettel."
    }
    if ((Sql "SELECT count(DISTINCT x.glpi_ticket_id) FROM raw_alerts r JOIN incident_alerts ia ON ia.alert_id=r.id JOIN incident_integrations x ON x.incident_id=ia.incident_id WHERE r.received_at >= '$($Ctx.MocSql)'::timestamptz AND r.alert_name IN ('HighLatency','HighPacketLoss') AND x.glpi_ticket_id IS NOT NULL;") -ne "1") {
        throw "Hai cảnh báo chất lượng tạo sai số phiếu GLPI."
    }
    if (-not (Cho {
        (GrafanaProm 'bpo_ping_rtt_avg_ms{provider="fpt"}') -gt 100 -and
        (GrafanaProm 'bpo_packet_loss_percent{provider="fpt"}') -gt 20
    } 30 2)) { throw "Grafana datasource chưa đọc được hai metric suy giảm thực tế." }
    GuiMininet "r1 tc qdisc del dev r1-eth1 root"
    if (-not (Cho {
        (Sql "SELECT count(DISTINCT r.alert_name) FROM raw_alerts r JOIN incident_alerts ia ON ia.alert_id=r.id JOIN incidents i ON i.id=ia.incident_id WHERE r.received_at >= '$($Ctx.MocSql)'::timestamptz AND r.status='resolved' AND r.alert_name IN ('HighLatency','HighPacketLoss') AND i.incident_key='wan-quality:fpt';") -eq "2" -and
        (Sql "SELECT status FROM incidents WHERE incident_key='wan-quality:fpt';") -eq "resolved"
    } 100 2)) { throw "Incident chất lượng chưa resolved sau khi bỏ netem." }
    $Dong.thoi_gian_phuc_hoi = LucNay
    $Dong.ghi_chu = "Netem thật: delay 180 ms, loss 40%; hai cảnh báo cùng provider gom một incident và một phiếu."
}

ChayTinhHuong "O-09" "Khởi động lại hệ thống Docker, giữ volume" {
    param($Dong, $Ctx)
    $RawTruoc = [int](Sql "SELECT count(*) FROM raw_alerts;")
    $TicketId = Sql "SELECT glpi_ticket_id FROM incident_integrations WHERE glpi_ticket_id IS NOT NULL ORDER BY updated_at DESC LIMIT 1;"
    $Services = @("postgres", "n8n", "alertmanager", "blackbox", "glpi-db", "glpi", "prometheus", "grafana")
    & docker compose --env-file $EnvFile -f $Compose restart $Services | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose restart lỗi." }
    $Containers = @("bpo-postgres", "bpo-n8n", "bpo-alertmanager", "bpo-blackbox", "bpo-glpi-db", "bpo-glpi", "bpo-prometheus", "bpo-grafana")
    if (-not (Cho {
        foreach ($Container in $Containers) {
            if ((docker inspect --format '{{.State.Health.Status}}' $Container 2>$null) -ne "healthy") { return $false }
        }
        return $true
    } 180 3)) { throw "Container chưa healthy sau restart." }
    $Dong.thoi_gian_phat_hien = LucNay
    if ([int](Sql "SELECT count(*) FROM raw_alerts;") -lt $RawTruoc) { throw "Dữ liệu PostgreSQL bị mất." }
    if ((Sql "SELECT count(*) FROM n8n.workflow_entity WHERE id IN ('bpoAlertFlow01','bpoNotifyTicket01') AND active;") -ne "2") {
        throw "Workflow n8n mất hoặc không active."
    }
    $Dash = Invoke-RestMethod http://localhost:3000/api/dashboards/uid/bpo-network-overview -Headers $GrafanaHeader
    if ($Dash.dashboard.panels.Count -ne 19) { throw "Dashboard Grafana không còn nguyên vẹn." }
    $Targets = (Invoke-RestMethod http://localhost:9090/api/v1/targets).data.activeTargets
    $Target = $Targets | Where-Object { $_.labels.job -eq "bpo_exporter" }
    if ($Target.health -ne "up") { throw "Prometheus chưa tiếp tục thu thập exporter." }
    if ([int](Sql "SELECT count(*) FROM raw_alerts WHERE received_at >= '$($Ctx.MocSql)'::timestamptz;") -ne 0) {
        throw "Restart sinh raw alert không cần thiết."
    }
    if ($TicketId) {
        $Phien = MoPhienGlpi
        $Header = @{ "Session-Token" = $Phien.session_token }
        try {
            $Phieu = Invoke-RestMethod "http://localhost:8080/apirest.php/Ticket/$TicketId" -Headers $Header
            if ([string]$Phieu.id -ne [string]$TicketId) { throw "GLPI không còn phiếu #$TicketId." }
        } finally {
            Invoke-RestMethod http://localhost:8080/apirest.php/killSession -Headers $Header | Out-Null
        }
    }
    $Dong.thoi_gian_phuc_hoi = LucNay
    $Dong.ghi_chu = "Restart không dùng down -v; PostgreSQL, workflow, GLPI, Prometheus và dashboard còn nguyên."
}

try {
    $TongHop = Sql "SELECT count(*) FILTER (WHERE r.status='firing'), count(DISTINCT ia.incident_id) FILTER (WHERE r.status='firing'), count(DISTINCT x.glpi_ticket_id) FILTER (WHERE r.status='firing') FROM raw_alerts r LEFT JOIN incident_alerts ia ON ia.alert_id=r.id LEFT JOIN incident_integrations x ON x.incident_id=ia.incident_id WHERE r.received_at >= '$MocToanBo'::timestamptz;"
    $CotTong = $TongHop -split '\|'
    $CanhBaoBan = [int]$CotTong[0]
    $Incident = [int]$CotTong[1]
    $Phieu = [int]$CotTong[2]
    $DaGom = [Math]::Max(0, $CanhBaoBan - $Incident)
    $IncidentTrungTranh = [int](($CacDo.so_incident_trung_tranh | Measure-Object -Sum).Sum)
    $TicketTrungTranh = [int](($CacDo.so_ticket_trung_tranh | Measure-Object -Sum).Sum)
    $ThoiGianPhatHien = @($CacDo.time_to_detect_seconds | Where-Object { $_ -ne "N/A" } | ForEach-Object { [double]$_ })
    $ThoiGianIncident = @($CacDo.time_to_incident_seconds | Where-Object { $_ -ne "N/A" } | ForEach-Object { [double]$_ })
    $ThoiGianTicket = @($CacDo.time_to_ticket_seconds | Where-Object { $_ -ne "N/A" } | ForEach-Object { [double]$_ })
    $TbPhatHien = if ($ThoiGianPhatHien.Count) { [Math]::Round(($ThoiGianPhatHien | Measure-Object -Average).Average, 3) } else { "không có" }
    $TbIncident = if ($ThoiGianIncident.Count) { [Math]::Round(($ThoiGianIncident | Measure-Object -Average).Average, 3) } else { "không có" }
    $TbTicket = if ($ThoiGianTicket.Count) { [Math]::Round(($ThoiGianTicket | Measure-Object -Average).Average, 3) } else { "không có" }
    $Wan = (Vm "cat $VmRoot/runtime/wan_status.json") | ConvertFrom-Json
    Ghi "TỔNG HỢP: phát hiện trung bình ${TbPhatHien}s; incident trung bình ${TbIncident}s; ticket trung bình ${TbTicket}s."
    Ghi "TỔNG HỢP: internal_failover_decision_time=$($Wan.failover_duration_seconds)s; internal_failback_decision_time=$($Wan.failback_duration_seconds)s; cảnh báo gom=$DaGom; incident trùng tránh=$IncidentTrungTranh; phiếu trùng tránh=$TicketTrungTranh."
} catch {
    $Loi++
    Ghi "[KHÔNG ĐẠT] Không tổng hợp được số liệu: $($_.Exception.Message)"
}

$SoTinhHuong = if ($Only.Count) { $Only.Count } else { 9 }
$TyLe = if ($DaChay -gt 0) { [Math]::Round((($DaChay - $Loi) * 100.0 / $DaChay), 2) } else { 0 }
Ghi "TỶ LỆ KIỂM THỬ ĐẠT: $($DaChay - $Loi)/$DaChay ($TyLe%)."

if ($Loi -gt 0 -or $DaChay -ne $SoTinhHuong) {
    Ghi "[KHÔNG ĐẠT] Giai đoạn O: đã chạy $DaChay/$SoTinhHuong tình huống, còn $Loi lỗi, mã thoát 1."
    exit 1
}

Ghi "[ĐẠT] Giai đoạn O: $SoTinhHuong/$SoTinhHuong tình huống đạt, mã thoát 0."
exit 0
