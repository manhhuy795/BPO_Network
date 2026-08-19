$ErrorActionPreference = "Continue"

$Root = Split-Path -Parent $PSScriptRoot
$Compose = Join-Path $Root "docker/docker-compose.yml"
$EnvFile = Join-Path $Root ".env"
$SqlFile = Join-Path $PSScriptRoot "test_phase_9.sql"
$TestDatabase = "bpo_phase9_" + [guid]::NewGuid().ToString("N")

function Env([string]$Name) {
    $Line = Get-Content $EnvFile | Where-Object { $_ -match "^$Name=" } | Select-Object -First 1
    if (-not $Line) { throw "Thieu bien $Name trong .env." }
    return ($Line -split '=', 2)[1].Trim()
}

$Database = Env "POSTGRES_DB"
$User = Env "POSTGRES_USER"
$Password = Env "POSTGRES_PASSWORD"
$ComposeArgs = @("compose", "--env-file", $EnvFile, "-f", $Compose)

try {
    & docker @($ComposeArgs + @("up", "-d", "postgres")) *> $null
    if ($LASTEXITCODE -ne 0) { throw "Khong khoi dong duoc PostgreSQL." }
    & docker exec -e "PGPASSWORD=$Password" bpo-postgres `
        psql -v ON_ERROR_STOP=1 -U $User -d $Database -c "CREATE DATABASE $TestDatabase;" *> $null
    if ($LASTEXITCODE -ne 0) { throw "Khong tao duoc database test." }
    & docker @($ComposeArgs + @("run", "--rm", "-e", "PGDATABASE=$TestDatabase", "database-init")) *> $null
    if ($LASTEXITCODE -ne 0) { throw "Khong ap dung duoc schema vao database test." }
    & docker cp $SqlFile "bpo-postgres:/tmp/test_phase_9.sql" *> $null
    & docker exec -e "PGPASSWORD=$Password" bpo-postgres `
        psql -v ON_ERROR_STOP=1 -U $User -d $TestDatabase -f /tmp/test_phase_9.sql
    if ($LASTEXITCODE -ne 0) { throw "Occurrence Phase 9 khong dat." }
    Write-Host "[DAT] Phase 9: recurrence, duration, MTTR, duplicate va merge deu dat."
    exit 0
} catch {
    Write-Host "[KHONG DAT] Phase 9 - $($_.Exception.Message)"
    exit 1
} finally {
    & docker exec -e "PGPASSWORD=$Password" bpo-postgres `
        psql -U $User -d $Database -c "DROP DATABASE IF EXISTS $TestDatabase WITH (FORCE);" *> $null
    & docker exec bpo-postgres rm -f /tmp/test_phase_9.sql *> $null
}
