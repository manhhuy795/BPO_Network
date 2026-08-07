param(
    [string]$BackupRoot = (Join-Path ([IO.Path]::GetTempPath()) "BPO_Network_backups")
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$BackupScript = Join-Path $RepoRoot "scripts/backup/backup.ps1"
$RunId = [DateTime]::UtcNow.ToString("yyyyMMddHHmmssfff")
$Sentinel = "phase6-$RunId"
$PgTestDb = "bpo_restore_test_$RunId"
$GlpiTestDb = "bpo_restore_test_$RunId"
$PgTemp = "/tmp/$RunId-postgres.dump"
$GlpiTemp = "/tmp/$RunId-glpi.sql"
$PgTestCreated = $false
$GlpiTestCreated = $false
$SentinelCreated = $false

function ChayDocker([string[]]$ThamSo) {
    $MucLoiCu = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $KetQua = & docker @ThamSo 2>&1
        $MaThoat = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $MucLoiCu
    }
    if ($MaThoat -ne 0) {
        throw "Docker lỗi: $($KetQua -join ' ')"
    }
    return (($KetQua | Out-String).Trim())
}

function PgEnv([string]$Ten) {
    return (ChayDocker @("exec", "bpo-postgres", "printenv", $Ten)).Trim()
}

function PgSql([string]$Database, [string]$Sql) {
    $User = PgEnv "POSTGRES_USER"
    return ChayDocker @("exec", "bpo-postgres", "psql", "--username=$User", "--dbname=$Database", "-Atq", "-v", "ON_ERROR_STOP=1", "--command=$Sql")
}

function MySqlRoot([string]$Database, [string]$Sql) {
    $RootPassword = (ChayDocker @("exec", "bpo-glpi-db", "printenv", "MYSQL_ROOT_PASSWORD")).Trim()
    return ChayDocker @(
        "exec", "--env", "MYSQL_PWD=$RootPassword", "bpo-glpi-db", "mysql",
        "--batch", "--skip-column-names", "--user=root", $Database, "--execute=$Sql"
    )
}

if (-not (Test-Path $BackupScript)) {
    throw "Chưa có script backup: $BackupScript"
}

$PgDb = PgEnv "POSTGRES_DB"
$PgUser = PgEnv "POSTGRES_USER"
$GlpiDb = (ChayDocker @("exec", "bpo-glpi-db", "printenv", "MYSQL_DATABASE")).Trim()
$BackupDir = $null

try {
    $SqlTao = @"
WITH new_raw AS (
    INSERT INTO raw_alerts (event_key, fingerprint, status, alert_name, severity, received_at, payload)
    VALUES ('$Sentinel', '$Sentinel', 'firing', 'Phase6RestoreTest', 'thap', CURRENT_TIMESTAMP, jsonb_build_object('phase', 6))
    RETURNING id
), new_incident AS (
    INSERT INTO incidents (incident_key, title, severity, status, suspected_cause, first_seen, last_seen, alert_count)
    VALUES ('$Sentinel', 'Bản ghi kiểm thử restore Phase 6', 'thap', 'open', 'Kiểm thử backup/restore', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 1)
    RETURNING id
), new_link AS (
    INSERT INTO incident_alerts (incident_id, alert_id)
    SELECT new_incident.id, new_raw.id FROM new_incident, new_raw
)
INSERT INTO incident_events (incident_id, event_type, description, event_data)
SELECT id, 'opened', 'Tạo để kiểm thử restore Phase 6', jsonb_build_object('sentinel', '$Sentinel')
FROM new_incident;
"@
    PgSql $PgDb $SqlTao | Out-Null
    $SentinelCreated = $true

    & $BackupScript -OutputRoot $BackupRoot
    if ($LASTEXITCODE -ne 0) { throw "Script backup trả mã lỗi $LASTEXITCODE." }
    $BackupDir = Get-ChildItem -LiteralPath $BackupRoot -Directory |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1 -ExpandProperty FullName
    if (-not $BackupDir) { throw "Không tìm thấy thư mục backup vừa tạo." }

    $ManifestPath = Join-Path $BackupDir "manifest.json"
    $ManifestRaw = Get-Content -Raw -Encoding utf8 $ManifestPath
    $Manifest = $ManifestRaw | ConvertFrom-Json
    $EncryptionKey = (ChayDocker @("exec", "bpo-n8n", "printenv", "N8N_ENCRYPTION_KEY")).Trim()
    if ($EncryptionKey -and $ManifestRaw.Contains($EncryptionKey)) {
        throw "Manifest chứa N8N_ENCRYPTION_KEY thật."
    }
    foreach ($TenFile in @($Manifest.postgres_backup, $Manifest.glpi_backup, $Manifest.n8n_backup)) {
        $Tep = Join-Path $BackupDir $TenFile
        if (-not (Test-Path $Tep) -or (Get-Item $Tep).Length -le 0) {
            throw "Backup thiếu hoặc rỗng: $TenFile"
        }
    }

    ChayDocker @("cp", (Join-Path $BackupDir $Manifest.postgres_backup), "bpo-postgres:$PgTemp") | Out-Null
    ChayDocker @("exec", "bpo-postgres", "createdb", "--username=$PgUser", $PgTestDb) | Out-Null
    $PgTestCreated = $true
    ChayDocker @("exec", "bpo-postgres", "pg_restore", "--username=$PgUser", "--dbname=$PgTestDb", "--exit-on-error", "--no-owner", "--no-acl", $PgTemp) | Out-Null

    $BangChinh = [int](PgSql $PgTestDb "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('raw_alerts','incidents','incident_alerts','incident_events','incident_integrations','notification_events');")
    if ($BangChinh -ne 6) { throw "PostgreSQL restore thiếu bảng chính: chỉ có $BangChinh/6 bảng." }
    if ([int](PgSql $PgTestDb "SELECT count(*) FROM incidents WHERE incident_key='$Sentinel';") -ne 1) {
        throw "Không tìm thấy incident kiểm thử sau restore PostgreSQL."
    }
    if ([int](PgSql $PgTestDb "SELECT count(*) FROM n8n.workflow_entity;") -le 0) {
        throw "Không tìm thấy workflow n8n trong PostgreSQL đã restore."
    }

    $Workflow = @(Get-Content -Raw -Encoding utf8 (Join-Path $BackupDir $Manifest.n8n_backup) | ConvertFrom-Json)
    if ($Workflow.Count -le 0) { throw "File export workflow n8n không có workflow." }

    $GlpiTicketsGoc = [int](MySqlRoot $GlpiDb "SELECT count(*) FROM glpi_tickets;")
    $GlpiTicketMau = (MySqlRoot $GlpiDb "SELECT COALESCE(min(id),0) FROM glpi_tickets;").Trim()
    ChayDocker @("cp", (Join-Path $BackupDir $Manifest.glpi_backup), "bpo-glpi-db:$GlpiTemp") | Out-Null
    MySqlRoot "mysql" "CREATE DATABASE $GlpiTestDb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" | Out-Null
    $GlpiTestCreated = $true
    MySqlRoot $GlpiTestDb "source $GlpiTemp" | Out-Null
    $SoBangGlpi = [int](MySqlRoot $GlpiTestDb "SELECT count(*) FROM information_schema.tables WHERE table_schema=DATABASE();")
    if ($SoBangGlpi -le 0) { throw "GLPI restore không tạo bảng." }
    if ([int](MySqlRoot $GlpiTestDb "SELECT count(*) FROM glpi_tickets;") -ne $GlpiTicketsGoc) {
        throw "Số ticket GLPI sau restore không khớp database gốc."
    }
    if ([int]$GlpiTicketMau -gt 0 -and [int](MySqlRoot $GlpiTestDb "SELECT count(*) FROM glpi_tickets WHERE id=$GlpiTicketMau;") -ne 1) {
        throw "Ticket GLPI mẫu #${GlpiTicketMau} không tồn tại sau restore."
    }

    Write-Host "[ĐẠT] Backup không rỗng, manifest không chứa secret."
    Write-Host "[ĐẠT] PostgreSQL restore đủ schema, incident kiểm thử và workflow n8n."
    Write-Host "[ĐẠT] MySQL GLPI restore đủ bảng và $GlpiTicketsGoc ticket."
    Write-Host "[ĐẠT] Restore chỉ diễn ra trong database test riêng."
} finally {
    if ($PgTestCreated) {
        try { ChayDocker @("exec", "bpo-postgres", "dropdb", "--username=$PgUser", "--if-exists", $PgTestDb) | Out-Null } catch { Write-Warning $_ }
    }
    if ($GlpiTestCreated) {
        try { MySqlRoot "mysql" "DROP DATABASE IF EXISTS $GlpiTestDb;" | Out-Null } catch { Write-Warning $_ }
    }
    if ($SentinelCreated) {
        try {
            PgSql $PgDb "DELETE FROM incidents WHERE incident_key='$Sentinel'; DELETE FROM raw_alerts WHERE event_key='$Sentinel';" | Out-Null
        } catch { Write-Warning $_ }
    }
    try { ChayDocker @("exec", "bpo-postgres", "rm", "-f", $PgTemp) | Out-Null } catch { Write-Warning $_ }
    try { ChayDocker @("exec", "bpo-glpi-db", "rm", "-f", $GlpiTemp) | Out-Null } catch { Write-Warning $_ }
}

if ([int](PgSql $PgDb "SELECT count(*) FROM incidents WHERE incident_key='$Sentinel';") -ne 0) {
    throw "Cleanup không xóa incident kiểm thử khỏi database chính."
}
if ([int](PgSql $PgDb "SELECT count(*) FROM pg_database WHERE datname='$PgTestDb';") -ne 0 -or
    [int](MySqlRoot "mysql" "SELECT count(*) FROM information_schema.schemata WHERE schema_name='$GlpiTestDb';") -ne 0) {
    throw "Cleanup chưa xóa hết database test."
}

Write-Host "[ĐẠT] Dữ liệu chính không bị restore đè; database test và sentinel đã cleanup."
Write-Host "[ĐẠT] Giai đoạn 6: backup/restore thực tế hoàn tất, mã thoát 0."
