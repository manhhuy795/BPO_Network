$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Compose = Join-Path $Root "docker/docker-compose.yml"
$EnvFile = Join-Path $Root ".env"
$EnvExample = Join-Path $Root ".env.example"
$Alertmanager = Join-Path $Root "docker/alertmanager/alertmanager.yml"
$Workflow = Join-Path $Root "n8n/workflows/bpo_alert_correlation.json"
$Readme = Join-Path $Root "README.md"
$Ci = Join-Path $Root ".github/workflows/ci.yml"
$Webhook = "http://localhost:5678/webhook/bpo-alertmanager"
$Passed = 0
$Failed = 0

function Env([string]$Name) {
    $Line = Get-Content $EnvFile | Where-Object { $_ -match "^$Name=" } | Select-Object -First 1
    if (-not $Line) { return "" }
    return ($Line -split '=', 2)[1].Trim()
}

function Check([string]$Description, [scriptblock]$Action) {
    try {
        if (-not (& $Action)) { throw "Điều kiện kiểm tra không đạt." }
        $script:Passed++
        Write-Host "[ĐẠT] $Description"
    } catch {
        $script:Failed++
        Write-Host "[KHÔNG ĐẠT] $Description - $($_.Exception.Message)"
    }
}

Check "Secret runtime không được Git theo dõi" {
    @((git ls-files -- .env)).Count -eq 0 -and
        [bool](git check-ignore .env 2>$null)
}

Check "Compose không còn fallback tài khoản hoặc mật khẩu" {
    $Text = Get-Content -Raw $Compose
    @(@('GRAFANA_ADMIN_USER:-', 'GRAFANA_ADMIN_PASSWORD:-', 'GRAFANA_DB_USER:-', 'GRAFANA_DB_PASSWORD:-') |
        Where-Object { $Text.Contains($_) }).Count -eq 0
}

Check "Các cổng giao diện chỉ bind vào loopback Windows" {
    $Text = Get-Content -Raw $Compose
    @(@('9090:9090', '9115:9115', '9093:9093', '5678:5678', '8080:80', '3000:3000') |
        Where-Object { $Text -notmatch [regex]::Escape("127.0.0.1:$_") }).Count -eq 0
}

Check "Token webhook được khai báo bằng biến môi trường" {
    $Example = Get-Content -Raw $EnvExample
    $Token = Env "ALERTMANAGER_WEBHOOK_TOKEN"
    $Example -match '(?m)^ALERTMANAGER_WEBHOOK_TOKEN=' -and
        $Token -match '^[A-Za-z0-9_-]{32,}$'
}

Check "Alertmanager gửi Bearer token từ template runtime" {
    $Text = Get-Content -Raw $Alertmanager
    $Text -match 'authorization:' -and
        $Text -match 'type:\s*Bearer' -and
        $Text -match '__BPO_ALERTMANAGER_WEBHOOK_TOKEN__'
}

Check "Workflow n8n xác thực Authorization trước payload" {
    $Text = Get-Content -Raw -Encoding UTF8 $Workflow
    $Text -match 'ALERTMANAGER_WEBHOOK_TOKEN' -and
        $Text -match 'authorization' -and
        $Text -match 'unauthorized'
}

Check "CI kiểm tra Python, Compose, Prometheus, YAML/JSON và secret" {
    if (-not (Test-Path $Ci)) { return $false }
    $Text = Get-Content -Raw $Ci
    @(@('pytest', 'docker compose', 'promtool', 'pyyaml', 'json', 'gitleaks') |
        Where-Object { $Text -notmatch [regex]::Escape($_) }).Count -eq 0 -and
        $Text -notmatch 'test_phase_o.ps1|VMware|Mininet'
}

Check "README công bố đúng phạm vi hệ thống lab" {
    $Text = Get-Content -Raw -Encoding UTF8 $Readme
    $Text -match [regex]::Escape('Lab system, not production-ready.') -and
        $Text -match [regex]::Escape('Rule-based topology correlation.') -and
        $Text -match [regex]::Escape('Suspected root cause.') -and
        $Text -notmatch '(?im)\bAI\b'
}

Check "Webhook từ chối request thiếu token" {
    try {
        Invoke-WebRequest -UseBasicParsing $Webhook -Method Post -ContentType 'application/json' `
            -Body '{"alerts":[]}' -TimeoutSec 10 | Out-Null
        return $false
    } catch {
        return $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401
    }
}

Check "Webhook chấp nhận token rồi mới kiểm tra payload" {
    $Token = Env "ALERTMANAGER_WEBHOOK_TOKEN"
    if (-not $Token) { return $false }
    try {
        Invoke-WebRequest -UseBasicParsing $Webhook -Method Post -Headers @{ Authorization = "Bearer $Token" } `
            -ContentType 'application/json' -Body '{"alerts":[]}' -TimeoutSec 10 | Out-Null
        return $false
    } catch {
        return $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 400
    }
}

if ($Failed) {
    Write-Host "[KHÔNG ĐẠT] Phase 11: $Passed/10 kiểm tra đạt, mã thoát 1."
    exit 1
}

Write-Host "[ĐẠT] Phase 11: 10/10 kiểm tra đạt, mã thoát 0."
exit 0
