$ErrorActionPreference = "Stop"

$ThuMucGoc = Split-Path -Parent $PSScriptRoot
$FileCompose = Join-Path $ThuMucGoc "docker/docker-compose.yml"
$FileMoiTruong = Join-Path $ThuMucGoc ".env"
$FileLog = Join-Path $ThuMucGoc "logs/phase_l_test.log"
$ThuMucPayload = Join-Path $ThuMucGoc "n8n/payloads"
$Webhook = "http://localhost:5678/webhook/bpo-alertmanager"
$SoLoi = 0
$SoKiemThu = 0
$RunId = (Get-Date -Format "yyyyMMddHHmmss") + "-" + ([guid]::NewGuid().ToString("N").Substring(0, 8))
$MocThoiGian = [DateTime]::UtcNow.AddSeconds(5)
$ThamSoCompose = @("compose", "--env-file", $FileMoiTruong, "-f", $FileCompose)

New-Item -ItemType Directory -Force (Split-Path -Parent $FileLog) | Out-Null
Set-Content -Encoding utf8 $FileLog "KIỂM THỬ GIAI ĐOẠN L - $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"

function Ghi-KetQua([string]$NoiDung) {
    Write-Host $NoiDung
    for ($LanThu = 0; $LanThu -lt 5; $LanThu++) {
        try {
            [IO.File]::AppendAllText($FileLog, "$NoiDung`r`n", [Text.UTF8Encoding]::new($true))
            return
        } catch {
            if ($LanThu -eq 4) { throw }
            Start-Sleep -Milliseconds 200
        }
    }
}

function Lay-Bien([string]$Ten) {
    $Dong = Get-Content -LiteralPath $FileMoiTruong | Where-Object { $_ -match "^$Ten=" } | Select-Object -First 1
    if (-not $Dong) { throw "Thiếu biến $Ten trong .env." }
    return ($Dong -split '=', 2)[1].Trim()
}

$PostgresDb = Lay-Bien "POSTGRES_DB"
$PostgresUser = Lay-Bien "POSTGRES_USER"
$PostgresPassword = Lay-Bien "POSTGRES_PASSWORD"
$WebhookToken = Lay-Bien "ALERTMANAGER_WEBHOOK_TOKEN"
$WebhookHeaders = @{ Authorization = "Bearer $WebhookToken" }
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

function Chay-Sql([string]$CauLenh) {
    $MucLoiCu = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $KetQua = & docker exec -e "PGPASSWORD=$PostgresPassword" bpo-postgres `
            psql -U $PostgresUser -d $PostgresDb -Atq -v ON_ERROR_STOP=1 -c $CauLenh 2>&1
        $MaThoat = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $MucLoiCu
    }
    if ($MaThoat -ne 0) { throw "Truy vấn PostgreSQL thất bại: $($KetQua -join ' ')" }
    return (($KetQua | Out-String).Trim())
}

function Cho-Den([scriptblock]$DieuKien, [int]$SoGiay = 90) {
    $KetThuc = (Get-Date).AddSeconds($SoGiay)
    while ((Get-Date) -lt $KetThuc) {
        try { if (& $DieuKien) { return $true } } catch {}
        Start-Sleep -Seconds 2
    }
    return $false
}

function Kiem-Tra([string]$MoTa, [scriptblock]$NoiDung) {
    $script:SoKiemThu++
    try {
        if (-not (& $NoiDung)) { throw "Điều kiện kiểm tra không đạt." }
        Ghi-KetQua "[ĐẠT] $($script:SoKiemThu.ToString('00')). $MoTa"
    } catch {
        $script:SoLoi++
        Ghi-KetQua "[KHÔNG ĐẠT] $($script:SoKiemThu.ToString('00')). $MoTa - $($_.Exception.Message)"
    }
}

function Tao-Payload([string]$TenFile, [int]$DoLechGiay, [string]$Provider = "") {
    $Payload = Get-Content -LiteralPath (Join-Path $ThuMucPayload $TenFile) -Raw -Encoding utf8 | ConvertFrom-Json
    $ChiSo = 0
    foreach ($Alert in $Payload.alerts) {
        $Alert.fingerprint = "$($Alert.fingerprint)-$RunId-$DoLechGiay"
        $Alert.startsAt = $MocThoiGian.AddSeconds($DoLechGiay + $ChiSo).ToString("o")
        if ($Alert.status -eq "firing") { $Alert.endsAt = "0001-01-01T00:00:00Z" }
        if ($Provider) { $Alert.labels | Add-Member -NotePropertyName provider -NotePropertyValue $Provider -Force }
        $ChiSo += 5
    }
    return $Payload
}

function Tao-Payload-PhucHoi($Payload, [int]$DoLechKetThuc = 300) {
    $BanSao = $Payload | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $BanSao.status = "resolved"
    foreach ($Alert in $BanSao.alerts) {
        $Alert.status = "resolved"
        $Alert.endsAt = $MocThoiGian.AddSeconds($DoLechKetThuc).ToString("o")
    }
    return $BanSao
}

function Gui-Webhook($Payload) {
    $Json = $Payload | ConvertTo-Json -Depth 30 -Compress
    $PhanHoi = Invoke-WebRequest -UseBasicParsing -Uri $Webhook -Method Post `
        -Headers $WebhookHeaders `
        -ContentType "application/json; charset=utf-8" -Body $Json -TimeoutSec 30
    return [pscustomobject]@{
        StatusCode = [int]$PhanHoi.StatusCode
        Body = ($PhanHoi.Content | ConvertFrom-Json)
    }
}

function Gui-Webhook-Sai($Payload) {
    try {
        $null = Gui-Webhook $Payload
        return 200
    } catch {
        return [int]$_.Exception.Response.StatusCode
    }
}

function So-BanGhi([string]$DieuKien) {
    return [int](Chay-Sql "SELECT count(*) FROM raw_alerts WHERE $DieuKien;")
}

function Dong-CanhBao-Thu-Cu {
    $DuLieuCu = Chay-Sql @"
SELECT (f.payload->'alert')::text
FROM raw_alerts f
WHERE f.status='firing'
  AND f.fingerprint LIKE 'phase-l-test-%'
  AND NOT EXISTS (
      SELECT 1 FROM raw_alerts r
      WHERE r.status='resolved'
        AND r.fingerprint=f.fingerprint
        AND r.starts_at IS NOT DISTINCT FROM f.starts_at
  );
"@
    $CacAlertJson = @($DuLieuCu -split "`r?`n")
    foreach ($Json in $CacAlertJson) {
        if (-not $Json) { continue }
        $Alert = $Json | ConvertFrom-Json
        $Alert.status = "resolved"
        $Alert.endsAt = [DateTime]::UtcNow.ToString("o")
        $Payload = [pscustomobject]@{
            du_lieu_thu_nghi = $true
            receiver = "n8n_bpo"
            status = "resolved"
            alerts = @($Alert)
        }
        $null = Gui-Webhook $Payload
    }
}

function Khoi-Dong-Exporter {
    Chay-Native "ssh" @(
        "-i", $SshKey, "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=8",
        "$SshUser@$IpUbuntu",
        "cd $ThuMucVm; curl -fsS http://127.0.0.1:9105/health >/dev/null 2>&1 || setsid -f python3 metrics/bpo_exporter.py >/tmp/bpo_exporter.log 2>&1 </dev/null"
    )
}

function Dung-Exporter {
    Chay-Native "ssh" @(
        "-i", $SshKey, "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=8",
        "$SshUser@$IpUbuntu", "pkill -f '[m]etrics/bpo_exporter.py' || true"
    )
}

try {
    Chay-Native "docker" ($ThamSoCompose + @("up", "-d"))
    if (-not (Cho-Den { (docker inspect --format '{{.State.Health.Status}}' bpo-n8n 2>$null) -eq "healthy" } 120)) {
        throw "n8n không healthy sau khi khởi động."
    }
    Dong-CanhBao-Thu-Cu

    Kiem-Tra "PostgreSQL đang healthy" {
        (docker inspect --format '{{.State.Health.Status}}' bpo-postgres 2>$null) -eq "healthy"
    }
    Kiem-Tra "n8n đang healthy" {
        (docker inspect --format '{{.State.Health.Status}}' bpo-n8n 2>$null) -eq "healthy"
    }
    Kiem-Tra "Alertmanager đang healthy" {
        (docker inspect --format '{{.State.Health.Status}}' bpo-alertmanager 2>$null) -eq "healthy"
    }
    Kiem-Tra "Workflow BPO đã được kích hoạt" {
        (Chay-Sql "SELECT count(*) FROM n8n.workflow_entity WHERE id = 'bpoAlertFlow01' AND active;") -eq "1"
    }

    $script:FptPayload = Tao-Payload "fpt_down.json" 0
    Kiem-Tra "Webhook chính thức trả HTTP 200 với payload hợp lệ" {
        $script:FptResponse = Gui-Webhook $script:FptPayload
        $script:FptResponse.StatusCode -eq 200 -and $script:FptResponse.Body.status -in @("created", "updated")
    }
    Kiem-Tra "Payload không hợp lệ trả HTTP 400" {
        $PayloadSai = Get-Content -LiteralPath (Join-Path $ThuMucPayload "invalid_payload.json") -Raw -Encoding utf8 | ConvertFrom-Json
        (Gui-Webhook-Sai $PayloadSai) -eq 400
    }
    $FptFingerprint = $FptPayload.alerts[0].fingerprint
    Kiem-Tra "Một cảnh báo firing tạo đúng một raw_alert" {
        (So-BanGhi "fingerprint = '$FptFingerprint' AND status = 'firing'") -eq 1
    }
    $AlertCountTruocTrung = [int](Chay-Sql "SELECT alert_count FROM incidents WHERE incident_key = 'wan-fpt';")
    Kiem-Tra "Gửi lại cùng payload không tạo raw_alert trùng" {
        $script:DuplicateResponse = Gui-Webhook $FptPayload
        (So-BanGhi "fingerprint = '$FptFingerprint' AND status = 'firing'") -eq 1 -and $script:DuplicateResponse.Body.status -eq "duplicate"
    }
    Kiem-Tra "Cảnh báo trùng không làm tăng alert_count" {
        [int](Chay-Sql "SELECT alert_count FROM incidents WHERE incident_key = 'wan-fpt';") -eq $AlertCountTruocTrung
    }
    Kiem-Tra "FPT mất tạo incident wan-fpt mức trung bình" {
        (Chay-Sql "SELECT count(*) FROM incidents WHERE incident_key='wan-fpt' AND status='open' AND severity='trung_binh';") -eq "1"
    }

    $script:CrmPayload = Tao-Payload "crm_down.json" 20
    $script:CfonoPayload = Tao-Payload "cfono_down.json" 30
    Kiem-Tra "CRM mất riêng tạo service-crm" {
        $null = Gui-Webhook $script:CrmPayload
        (Chay-Sql "SELECT count(*) FROM incidents WHERE incident_key='service-crm' AND status='open';") -eq "1"
    }
    Kiem-Tra "CFONO mất riêng tạo service-cfono" {
        $null = Gui-Webhook $script:CfonoPayload
        (Chay-Sql "SELECT count(*) FROM incidents WHERE incident_key='service-cfono' AND status='open';") -eq "1"
    }
    Kiem-Tra "CRM và CFONO không bị gom chung khi WAN bình thường" {
        (Chay-Sql "SELECT count(DISTINCT incident_key) FROM incidents WHERE incident_key IN ('service-crm','service-cfono') AND status='open';") -eq "2"
    }

    $script:QualityFpt = Tao-Payload "wan_quality.json" 40 "fpt"
    $null = Gui-Webhook $script:QualityFpt
    Kiem-Tra "HighLatency và HighPacketLoss của FPT được gom vào wan-quality:fpt" {
        (Chay-Sql "SELECT alert_count FROM incidents WHERE incident_key='wan-quality:fpt' AND status='open';") -ge "2"
    }
    $script:QualityViettel = Tao-Payload "wan_quality.json" 50 "viettel"
    $null = Gui-Webhook $script:QualityViettel
    Kiem-Tra "Cảnh báo chất lượng FPT và Viettel không bị gom chung" {
        (Chay-Sql "SELECT count(DISTINCT incident_key) FROM incidents WHERE incident_key IN ('wan-quality:fpt','wan-quality:viettel') AND status='open';") -eq "2"
    }

    $script:BothPayload = Tao-Payload "both_wan_down.json" 60
    Kiem-Tra "Cả hai WAN mất tạo incident wan-total mức cao" {
        $null = Gui-Webhook $script:BothPayload
        (Chay-Sql "SELECT count(*) FROM incidents WHERE incident_key='wan-total' AND status='open' AND severity='cao';") -eq "1"
    }
    $script:CrmTrongWan = Tao-Payload "crm_down.json" 70
    $script:CfonoTrongWan = Tao-Payload "cfono_down.json" 80
    $null = Gui-Webhook $script:CrmTrongWan
    $null = Gui-Webhook $script:CfonoTrongWan
    Kiem-Tra "CRM/CFONO khi wan-total mở được gắn vào sự cố WAN tổng" {
        $CrmFp = $script:CrmTrongWan.alerts[0].fingerprint
        $CfonoFp = $script:CfonoTrongWan.alerts[0].fingerprint
        (Chay-Sql "SELECT count(DISTINCT a.fingerprint) FROM incidents i JOIN incident_alerts ia ON ia.incident_id=i.id JOIN raw_alerts a ON a.id=ia.alert_id WHERE i.incident_key='wan-total' AND a.fingerprint IN ('$CrmFp','$CfonoFp');") -eq "2"
    }

    $script:ExporterPayload = Tao-Payload "exporter_down.json" 90
    Kiem-Tra "BPOExporterDown tạo monitoring-exporter" {
        $null = Gui-Webhook $script:ExporterPayload
        (Chay-Sql "SELECT count(*) FROM incidents WHERE incident_key='monitoring-exporter' AND status='open' AND severity='cao';") -eq "1"
    }
    $null = Gui-Webhook (Tao-Payload-PhucHoi $ExporterPayload 190)

    Kiem-Tra "Cảnh báo resolved không tạo incident mới" {
        $Truoc = [int](Chay-Sql "SELECT count(*) FROM incidents;")
        $Orphan = Tao-Payload "resolved_alert.json" 100
        $Orphan.status = "resolved"
        foreach ($Alert in $Orphan.alerts) { $Alert.status = "resolved"; $Alert.endsAt = $MocThoiGian.AddSeconds(200).ToString("o") }
        $PhanHoi = Gui-Webhook $Orphan
        $Sau = [int](Chay-Sql "SELECT count(*) FROM incidents;")
        $PhanHoi.Body.status -eq "resolved" -and $Sau -eq $Truoc
    }

    Kiem-Tra "Incident chỉ đóng khi không còn cảnh báo firing liên quan" {
        $null = Gui-Webhook (Tao-Payload-PhucHoi $FptPayload 210)
        $VanMo = (Chay-Sql "SELECT status FROM incidents WHERE incident_key='wan-total';") -eq "open"
        foreach ($Payload in @($CrmPayload, $CfonoPayload, $QualityFpt, $QualityViettel, $BothPayload, $CrmTrongWan, $CfonoTrongWan)) {
            $null = Gui-Webhook (Tao-Payload-PhucHoi $Payload 220)
        }
        $ConHoatDong = [int](Chay-Sql @"
SELECT count(*)
FROM raw_alerts f
JOIN incident_alerts ia ON ia.alert_id=f.id
JOIN incidents i ON i.id=ia.incident_id
WHERE i.incident_key='wan-total' AND f.status='firing'
  AND NOT EXISTS (
      SELECT 1 FROM raw_alerts r
      WHERE r.status='resolved' AND r.fingerprint=f.fingerprint
        AND r.starts_at IS NOT DISTINCT FROM f.starts_at
  );
"@)
        $TrangThai = Chay-Sql "SELECT status FROM incidents WHERE incident_key='wan-total';"
        $DongDungLuc = ($ConHoatDong -eq 0 -and $TrangThai -eq "resolved") -or ($ConHoatDong -gt 0 -and $TrangThai -eq "open")
        $VanMo -and $DongDungLuc
    }

    $RawIdGiuLai = Chay-Sql "SELECT id FROM raw_alerts WHERE fingerprint='$FptFingerprint' AND status='firing';"
    Kiem-Tra "Dữ liệu vẫn tồn tại sau khi restart PostgreSQL" {
        Chay-Native "docker" ($ThamSoCompose + @("restart", "postgres"))
        $DaHealthy = Cho-Den { (docker inspect --format '{{.State.Health.Status}}' bpo-postgres 2>$null) -eq "healthy" } 90
        $DaHealthy -and (Chay-Sql "SELECT count(*) FROM raw_alerts WHERE id=$RawIdGiuLai;") -eq "1"
    }
    Kiem-Tra "Prometheus và Alertmanager vẫn hoạt động sau khi thêm n8n" {
        (Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:9090/-/healthy" -TimeoutSec 10).StatusCode -eq 200 -and
        (Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:9093/-/healthy" -TimeoutSec 10).StatusCode -eq 200
    }
    Kiem-Tra "Không có liên kết mồ côi trong incident_alerts" {
        (Chay-Sql "SELECT count(*) FROM incident_alerts ia LEFT JOIN incidents i ON i.id=ia.incident_id LEFT JOIN raw_alerts a ON a.id=ia.alert_id WHERE i.id IS NULL OR a.id IS NULL;") -eq "0"
    }
    Kiem-Tra "Không có hai incident mở cùng incident_key" {
        (Chay-Sql "SELECT count(*) FROM (SELECT incident_key FROM incidents WHERE status='open' GROUP BY incident_key HAVING count(*)>1) duplicate_open;") -eq "0"
    }

    if (-not (Test-Path -LiteralPath $SshKey)) { throw "Không tìm thấy khóa SSH để kiểm chứng sự cố thực tế: $SshKey" }
    $MocThucTe = Chay-Sql "SELECT CURRENT_TIMESTAMP;"
    Dung-Exporter
    $DaQuaPrometheus = Cho-Den {
        $CanhBao = Invoke-RestMethod -Uri "http://localhost:9090/api/v1/alerts" -TimeoutSec 5
        @($CanhBao.data.alerts | Where-Object { $_.labels.alertname -eq "BPOExporterDown" -and $_.state -eq "firing" }).Count -gt 0
    } 90
    $DaQuaAlertmanager = Cho-Den {
        $CanhBao = Invoke-RestMethod -Uri "http://localhost:9093/api/v2/alerts?active=true&silenced=false&inhibited=false" -TimeoutSec 5
        @($CanhBao | Where-Object { $_.labels.alertname -eq "BPOExporterDown" }).Count -gt 0
    } 30
    $DaVaoPostgres = Cho-Den {
        [int](Chay-Sql "SELECT count(*) FROM raw_alerts WHERE alert_name='BPOExporterDown' AND status='firing' AND received_at >= '$MocThucTe'::timestamptz;") -gt 0
    } 60
    Khoi-Dong-Exporter
    $DaPhucHoiThucTe = Cho-Den {
        [int](Chay-Sql "SELECT count(*) FROM raw_alerts WHERE alert_name='BPOExporterDown' AND status='resolved' AND received_at >= '$MocThucTe'::timestamptz;") -gt 0
    } 120
    if ($DaQuaPrometheus -and $DaQuaAlertmanager -and $DaVaoPostgres -and $DaPhucHoiThucTe) {
        Ghi-KetQua "[ĐẠT] KIỂM CHỨNG THỰC TẾ: dừng exporter đã đi qua Prometheus -> Alertmanager -> n8n -> PostgreSQL và có resolved."
    } else {
        $SoLoi++
        Ghi-KetQua "[KHÔNG ĐẠT] KIỂM CHỨNG THỰC TẾ: Prometheus=$DaQuaPrometheus, Alertmanager=$DaQuaAlertmanager, PostgreSQL=$DaVaoPostgres, phục hồi=$DaPhucHoiThucTe."
    }
} catch {
    $SoLoi++
    Ghi-KetQua "[KHÔNG ĐẠT] Lỗi thiết lập hoặc luồng kiểm thử: $($_.Exception.Message)"
} finally {
    try { Khoi-Dong-Exporter } catch {}
}

if ($SoLoi -gt 0 -or $SoKiemThu -ne 24) {
    Ghi-KetQua "[KHÔNG ĐẠT] Giai đoạn L: $SoKiemThu/24 kiểm thử đã chạy, còn $SoLoi lỗi, mã thoát 1."
    exit 1
}

Ghi-KetQua "[ĐẠT] Toàn bộ 24/24 kiểm thử và luồng sự cố thực tế đã đạt, mã thoát 0."
exit 0

