param(
    [string]$OutputRoot = (Join-Path ([IO.Path]::GetTempPath()) "BPO_Network_backups")
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$BackupId = "bpo-backup-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
$BackupDir = Join-Path $OutputRoot $BackupId
$PgTemp = "/tmp/$BackupId-postgres.dump"
$GlpiTemp = "/tmp/$BackupId-glpi.sql"
$N8nTemp = "/tmp/$BackupId-n8n-workflows.json"
$PgFile = Join-Path $BackupDir "postgres.dump"
$GlpiFile = Join-Path $BackupDir "glpi.sql"
$N8nFile = Join-Path $BackupDir "n8n_workflows.json"

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

function GiaTriContainer([string]$Container, [string]$Ten) {
    return (ChayDocker @("exec", $Container, "printenv", $Ten)).Trim()
}

foreach ($Container in @("bpo-postgres", "bpo-glpi-db", "bpo-n8n")) {
    if ((ChayDocker @("inspect", "--format={{.State.Running}}", $Container)).Trim() -ne "true") {
        throw "Container $Container chưa chạy."
    }
}

$PgDb = GiaTriContainer "bpo-postgres" "POSTGRES_DB"
$PgUser = GiaTriContainer "bpo-postgres" "POSTGRES_USER"
$GlpiDb = GiaTriContainer "bpo-glpi-db" "MYSQL_DATABASE"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

try {
    ChayDocker @(
        "exec", "bpo-postgres", "pg_dump", "--username=$PgUser", "--dbname=$PgDb",
        "--format=custom", "--no-owner", "--no-acl", "--file=$PgTemp"
    ) | Out-Null

    $LenhDumpGlpi = 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqldump --user=root --single-transaction --quick --routines --events --hex-blob --no-tablespaces "$MYSQL_DATABASE" > "$1"'
    ChayDocker @("exec", "bpo-glpi-db", "sh", "-c", $LenhDumpGlpi, "sh", $GlpiTemp) | Out-Null
    ChayDocker @("exec", "bpo-n8n", "n8n", "export:workflow", "--all", "--pretty", "--output=$N8nTemp") | Out-Null

    ChayDocker @("cp", "bpo-postgres:$PgTemp", $PgFile) | Out-Null
    ChayDocker @("cp", "bpo-glpi-db:$GlpiTemp", $GlpiFile) | Out-Null
    ChayDocker @("cp", "bpo-n8n:$N8nTemp", $N8nFile) | Out-Null

    foreach ($Tep in @($PgFile, $GlpiFile, $N8nFile)) {
        if (-not (Test-Path $Tep) -or (Get-Item $Tep).Length -le 0) {
            throw "Tệp backup thiếu hoặc rỗng: $Tep"
        }
    }

    $GitCommit = ((& git -C $RepoRoot rev-parse HEAD 2>&1) | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Không đọc được Git commit hiện tại." }
    $Manifest = [ordered]@{
        created_at = [DateTime]::UtcNow.ToString("o")
        postgres_backup = (Split-Path -Leaf $PgFile)
        glpi_backup = (Split-Path -Leaf $GlpiFile)
        n8n_backup = (Split-Path -Leaf $N8nFile)
        git_commit = $GitCommit
        postgres_database = $PgDb
        glpi_database = $GlpiDb
        postgres_tables_required = @(
            "raw_alerts", "incidents", "incident_alerts", "incident_events",
            "incident_integrations", "notification_events"
        )
        n8n_restore = [ordered]@{
            workflow_export = "n8n_workflows.json"
            runtime_database_in_postgres_backup = $true
            required_secret = "N8N_ENCRYPTION_KEY"
            secret_stored_in_backup = $false
        }
        configuration_restore = [ordered]@{
            source = "git"
            paths = @(
                "docker/prometheus", "docker/alertmanager",
                "docker/grafana/provisioning", "docker/grafana/dashboards",
                "database", "n8n/workflows"
            )
        }
        sha256 = [ordered]@{
            postgres = (Get-FileHash -Algorithm SHA256 $PgFile).Hash.ToLowerInvariant()
            glpi = (Get-FileHash -Algorithm SHA256 $GlpiFile).Hash.ToLowerInvariant()
            n8n = (Get-FileHash -Algorithm SHA256 $N8nFile).Hash.ToLowerInvariant()
        }
    }
    $Manifest | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 (Join-Path $BackupDir "manifest.json")

    Write-Host "[ĐẠT] Đã backup PostgreSQL, MySQL GLPI và workflow n8n."
    Write-Host "[ĐẠT] Manifest: $(Join-Path $BackupDir 'manifest.json')"
    Write-Output $BackupDir
} finally {
    try { ChayDocker @("exec", "bpo-postgres", "rm", "-f", $PgTemp) | Out-Null } catch { Write-Warning $_ }
    try { ChayDocker @("exec", "bpo-glpi-db", "rm", "-f", $GlpiTemp) | Out-Null } catch { Write-Warning $_ }
    try { ChayDocker @("exec", "bpo-n8n", "rm", "-f", $N8nTemp) | Out-Null } catch { Write-Warning $_ }
}
