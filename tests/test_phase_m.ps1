$ErrorActionPreference = "Stop"

$Goc = Split-Path -Parent $PSScriptRoot
$Compose = Join-Path $Goc "docker/docker-compose.yml"
$EnvFile = Join-Path $Goc ".env"
$LogFile = Join-Path $Goc "logs/phase_m_test.log"
$Webhook = "http://localhost:5678/webhook/bpo-alertmanager"
$RunId = (Get-Date -Format "yyyyMMddHHmmss") + ([guid]::NewGuid().ToString("N").Substring(0, 6))
$Loi = 0
$DaChay = 0

New-Item -ItemType Directory -Force (Split-Path $LogFile) | Out-Null
Set-Content -Encoding utf8 $LogFile "KIỂM THỬ GIAI ĐOẠN M - $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"

function Ghi([string]$NoiDung) {
    Write-Host $NoiDung
    Add-Content -Encoding utf8 $LogFile $NoiDung
}

function Bien([string]$Ten) {
    $Dong = Get-Content $EnvFile | Where-Object { $_ -match "^$Ten=" } | Select-Object -First 1
    if (-not $Dong) { throw "Thiếu biến $Ten trong .env." }
    return ($Dong -split "=", 2)[1]
}

$PgDb = Bien "POSTGRES_DB"
$PgUser = Bien "POSTGRES_USER"
$PgPassword = Bien "POSTGRES_PASSWORD"
$EmailMode = Bien "EMAIL_MODE"
$GlpiUser = Bien "GLPI_API_USER"
$GlpiPassword = Bien "GLPI_API_PASSWORD"
$WebhookToken = Bien "ALERTMANAGER_WEBHOOK_TOKEN"
$WebhookHeaders = @{ Authorization = "Bearer $WebhookToken" }

function Sql([string]$CauLenh) {
    $env:PGPASSWORD = $PgPassword
    $KetQua = & docker exec --env PGPASSWORD bpo-postgres psql `
        "--username=$PgUser" "--dbname=$PgDb" -Atq -v ON_ERROR_STOP=1 `
        "--field-separator=|" "--command=$CauLenh" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "PostgreSQL lỗi: $($KetQua -join ' ')" }
    return (($KetQua | Out-String).Trim())
}

function Cho([scriptblock]$DieuKien, [int]$Giay = 45) {
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

function TaoAlert([string]$Ten, [string]$MucDo, [string]$Provider, [string]$Fingerprint, [datetime]$BatDau) {
    return [ordered]@{
        status = "firing"
        labels = [ordered]@{ alertname = $Ten; severity = $MucDo; provider = $Provider; environment = "bpo-345" }
        annotations = [ordered]@{ summary = "Kiểm thử Giai đoạn M"; description = "Dữ liệu kiểm thử có mã $RunId" }
        startsAt = $BatDau.ToUniversalTime().ToString("o")
        endsAt = "0001-01-01T00:00:00Z"
        fingerprint = $Fingerprint
    }
}

function Payload($Alert, [string]$TrangThai = "firing") {
    return [ordered]@{ receiver = "n8n_bpo"; status = $TrangThai; alerts = @($Alert) }
}

function Gui($DuLieu) {
    return Invoke-RestMethod -Uri $Webhook -Method Post -Headers $WebhookHeaders -ContentType "application/json; charset=utf-8" `
        -Body ($DuLieu | ConvertTo-Json -Depth 12 -Compress) -TimeoutSec 30
}

function PhucHoi($Alert) {
    $BanSao = $Alert | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $BanSao.status = "resolved"
    $BanSao.endsAt = [DateTime]::UtcNow.ToString("o")
    return Payload $BanSao "resolved"
}

function MoPhienGlpi {
    $Chuoi = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${GlpiUser}:${GlpiPassword}"))
    return Invoke-RestMethod -Uri "http://localhost:8080/apirest.php/initSession" -Headers @{ Authorization = "Basic $Chuoi" }
}

try {
    & docker compose --env-file $EnvFile -f $Compose up -d | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Không khởi động được Docker Compose." }

    KiemTra "PostgreSQL, n8n và GLPI đang healthy" {
        @("bpo-postgres", "bpo-n8n", "bpo-glpi", "bpo-glpi-db") | ForEach-Object {
            if ((docker inspect --format '{{.State.Health.Status}}' $_ 2>$null) -ne "healthy") { return $false }
        }
        return $true
    }
    KiemTra "Hai workflow BPO đang active" {
        (Sql "SELECT count(*) FROM n8n.workflow_entity WHERE id IN ('bpoAlertFlow01','bpoNotifyTicket01') AND active;") -eq "2"
    }

    $Provider = "phase-m-$RunId"
    $BatDau1 = [DateTime]::UtcNow
    $Alert1 = TaoAlert "HighLatency" "medium" $Provider "phase-m-latency-$RunId" $BatDau1
    $Payload1 = Payload $Alert1
    $PhanHoi1 = Gui $Payload1

    KiemTra "Incident mới tạo đúng một phiếu GLPI" {
        $script:BanGhi1 = $null
        $SanSang = Cho {
            $script:BanGhi1 = Sql "SELECT i.id,x.glpi_ticket_id,n.email_status,n.glpi_status FROM incidents i JOIN incident_integrations x ON x.incident_id=i.id JOIN notification_events n ON n.incident_id=i.id WHERE i.incident_key='wan-quality:$Provider' ORDER BY n.id DESC LIMIT 1;"
            $script:BanGhi1 -match '^\d+\|\d+\|(logged|sent)\|created$'
        }
        if ($SanSang) {
            $Cot = $script:BanGhi1 -split '\|'
            $script:IncidentId = [int]$Cot[0]
            $script:TicketId = [int]$Cot[1]
        }
        $SanSang -and $PhanHoi1.status -in @("created", "updated")
    }
    KiemTra "Nội dung email thử nghiệm có WAN thật và không còn placeholder" {
        $NoiDung = Sql "SELECT email_body FROM notification_events WHERE incident_id=$script:IncidentId ORDER BY id LIMIT 1;"
        $NoiDung -notmatch '\{\{WAN_ACTIVE\}\}' -and $NoiDung -match 'Đường WAN đang sử dụng:'
    }

    $ThongBaoTruoc = [int](Sql "SELECT count(*) FROM notification_events WHERE incident_id=$script:IncidentId;")
    $PhieuTruoc = [int](Sql "SELECT count(*) FROM incident_integrations WHERE incident_id=$script:IncidentId;")
    $PhanHoiTrung = Gui $Payload1
    Start-Sleep -Seconds 3
    KiemTra "Payload trùng không gửi lại email" {
        $PhanHoiTrung.status -eq "duplicate" -and [int](Sql "SELECT count(*) FROM notification_events WHERE incident_id=$script:IncidentId;") -eq $ThongBaoTruoc
    }
    KiemTra "Payload trùng không tạo phiếu GLPI mới" {
        [int](Sql "SELECT count(*) FROM incident_integrations WHERE incident_id=$script:IncidentId;") -eq $PhieuTruoc
    }

    $Alert2 = TaoAlert "HighPacketLoss" "high" $Provider "phase-m-loss-$RunId" ([DateTime]::UtcNow.AddSeconds(1))
    $null = Gui (Payload $Alert2)
    KiemTra "Tăng mức độ cập nhật đúng phiếu cũ" {
        Cho {
            $Dong = Sql "SELECT n.event_type,n.glpi_status,x.glpi_ticket_id,i.severity FROM notification_events n JOIN incidents i ON i.id=n.incident_id JOIN incident_integrations x ON x.incident_id=i.id WHERE i.id=$script:IncidentId ORDER BY n.id DESC LIMIT 1;"
            $Dong -eq "severity_increased|updated|$script:TicketId|cao"
        }
    }

    $null = Gui (PhucHoi $Alert1)
    Start-Sleep -Seconds 2
    $null = Gui (PhucHoi $Alert2)
    KiemTra "Phục hồi đóng incident và đúng phiếu GLPI" {
        Cho {
            (Sql "SELECT i.status || '|' || x.glpi_status || '|' || x.glpi_ticket_id FROM incidents i JOIN incident_integrations x ON x.incident_id=i.id WHERE i.id=$script:IncidentId;") -eq "resolved|closed|$script:TicketId"
        }
    }
    KiemTra "Phiếu GLPI có ghi chú và trạng thái đóng qua API" {
        $Phien = MoPhienGlpi
        $Header = @{ "Session-Token" = $Phien.session_token }
        try {
            Cho {
                $Phieu = Invoke-RestMethod -Uri "http://localhost:8080/apirest.php/Ticket/$script:TicketId" -Headers $Header
                $TraVeGhiChu = Invoke-RestMethod -Uri "http://localhost:8080/apirest.php/Ticket/$script:TicketId/ITILFollowup" -Headers $Header
                $SoGhiChu = if ($null -ne $TraVeGhiChu.value) { @($TraVeGhiChu.value).Count } else { @($TraVeGhiChu).Count }
                $Phieu.status -eq 6 -and $SoGhiChu -ge 2
            } 20
        } finally {
            Invoke-RestMethod -Uri "http://localhost:8080/apirest.php/killSession" -Headers $Header | Out-Null
        }
    }
    KiemTra "CRM và CFONO liên kết hai phiếu độc lập" {
        $Dong = Sql "SELECT count(DISTINCT x.glpi_ticket_id) FROM incidents i JOIN incident_integrations x ON x.incident_id=i.id WHERE i.incident_key IN ('service-crm','service-cfono') AND x.glpi_ticket_id IS NOT NULL;"
        $Dong -eq "2"
    }
    KiemTra "Mỗi incident có tối đa một liên kết phiếu" {
        (Sql "SELECT count(*) FROM (SELECT incident_id FROM incident_integrations GROUP BY incident_id HAVING count(*) > 1) x;") -eq "0"
    }
    KiemTra "Email đang ở chế độ được khai báo, không giả nhận đã gửi thật" {
        if ($EmailMode -eq "log") {
            (Sql "SELECT count(*) FROM notification_events WHERE incident_id=$script:IncidentId AND email_status='sent';") -eq "0"
        } else {
            $EmailMode -eq "smtp"
        }
    }

    & docker compose --env-file $EnvFile -f $Compose restart postgres glpi-db glpi | Out-Null
    KiemTra "Dữ liệu và phiếu còn sau khi restart container" {
        $Healthy = Cho {
            (docker inspect --format '{{.State.Health.Status}}' bpo-postgres 2>$null) -eq "healthy" -and
            (docker inspect --format '{{.State.Health.Status}}' bpo-glpi-db 2>$null) -eq "healthy" -and
            (docker inspect --format '{{.State.Health.Status}}' bpo-glpi 2>$null) -eq "healthy"
        } 120
        $Healthy -and (Sql "SELECT glpi_ticket_id FROM incident_integrations WHERE incident_id=$script:IncidentId;") -eq "$script:TicketId"
    }
    KiemTra "Prometheus và Alertmanager không bị ảnh hưởng" {
        (Invoke-WebRequest -UseBasicParsing http://localhost:9090/-/healthy).StatusCode -eq 200 -and
        (Invoke-WebRequest -UseBasicParsing http://localhost:9093/-/healthy).StatusCode -eq 200
    }
} catch {
    $Loi++
    Ghi "[KHÔNG ĐẠT] Lỗi thiết lập: $($_.Exception.Message)"
}

if ($Loi -gt 0 -or $DaChay -ne 14) {
    Ghi "[KHÔNG ĐẠT] Giai đoạn M: đã chạy $DaChay/14 kiểm thử, còn $Loi lỗi, mã thoát 1."
    exit 1
}

Ghi "[ĐẠT] Giai đoạn M: 14/14 kiểm thử đạt, mã thoát 0."
exit 0
