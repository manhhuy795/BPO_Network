param(
    [ValidateSet("O-10", "O-11", "O-12", "O-13", "O-14", "O-15", "O-16")]
    [string[]]$Only = @()
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Compose = Join-Path $Root "docker/docker-compose.yml"
$EnvFile = Join-Path $Root ".env"
$CsvFile = Join-Path $Root "logs/phase_10_measurements.csv"
$Webhook = "http://localhost:5678/webhook/bpo-alertmanager"
$Run = "p10-" + [guid]::NewGuid().ToString("N")
$Rows = [Collections.ArrayList]::new()
$Tracked = [Collections.ArrayList]::new()
$Failures = 0
$Ran = 0

function Env([string]$Name) {
    $Line = Get-Content $EnvFile | Where-Object { $_ -match "^$Name=" } | Select-Object -First 1
    if (-not $Line) { throw "Thieu bien $Name trong .env." }
    return ($Line -split '=', 2)[1].Trim()
}

$Database = Env "POSTGRES_DB"
$User = Env "POSTGRES_USER"
$Password = Env "POSTGRES_PASSWORD"
$ComposeArgs = @("compose", "--env-file", $EnvFile, "-f", $Compose)

function Sql([string]$Query) {
    $Old = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Result = & docker exec -e "PGPASSWORD=$Password" bpo-postgres `
            psql -v ON_ERROR_STOP=1 -U $User -d $Database -Atc $Query 2>$null
        if ($LASTEXITCODE -ne 0) { throw "PostgreSQL query failed." }
        return (@($Result) -join "`n").Trim()
    } finally { $ErrorActionPreference = $Old }
}

function Invoke-Docker([string[]]$DockerArgs) {
    $Old = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & docker @DockerArgs *> $null
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $Old }
}

function Wait-Until([scriptblock]$Condition, [int]$Seconds = 60) {
    $Deadline = (Get-Date).AddSeconds($Seconds)
    do {
        try { if (& $Condition) { return $true } } catch {}
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $Deadline)
    return $false
}

function Wait-Healthy([string]$Container, [int]$Seconds = 90) {
    return Wait-Until {
        (docker inspect --format '{{.State.Health.Status}}' $Container 2>$null) -eq "healthy"
    } $Seconds
}

function Wait-Webhook([int]$Seconds = 90) {
    return Wait-Until {
        try {
            Invoke-WebRequest $Webhook -Method Post -ContentType "application/json" `
                -Body '{"alerts":[]}' -TimeoutSec 5 | Out-Null
            return $true
        } catch {
            if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode -ne 404 }
            return $false
        }
    } $Seconds
}

function New-Alert(
    [string]$Name, [string]$Fingerprint, [string]$Status = "firing",
    [string]$StartsAt = "", [string]$EndsAt = "", [string]$Service = "",
    [string]$Severity = "trung_binh"
) {
    if (-not $StartsAt) { $StartsAt = (Get-Date).ToUniversalTime().ToString("o") }
    $Labels = [ordered]@{ alertname = $Name; severity = $Severity; instance = "phase10" }
    if ($Service) { $Labels.service = $Service }
    return [ordered]@{
        status = $Status
        labels = $Labels
        annotations = @{ summary = "Kiem thu Phase 10" }
        startsAt = $StartsAt
        endsAt = $(if ($Status -eq "resolved") { $EndsAt } else { "0001-01-01T00:00:00Z" })
        fingerprint = $Fingerprint
    }
}

function Body([array]$Alerts) {
    $Status = if (@($Alerts | Where-Object { $_.status -eq "firing" }).Count) { "firing" } else { "resolved" }
    return @{ receiver = "phase10"; status = $Status; alerts = $Alerts } | ConvertTo-Json -Depth 12 -Compress
}

function Post([array]$Alerts, [int]$Timeout = 120) {
    return Invoke-RestMethod $Webhook -Method Post -ContentType "application/json" `
        -Body (Body $Alerts) -TimeoutSec $Timeout
}

function Track([array]$Alerts) {
    foreach ($Alert in $Alerts) {
        if ($Alert.status -eq "firing") { [void]$Tracked.Add($Alert) }
    }
}

function Resolve([array]$Alerts) {
    if (-not $Alerts.Count) { return }
    $End = (Get-Date).ToUniversalTime().ToString("o")
    $Resolved = foreach ($Alert in $Alerts) {
        New-Alert $Alert.labels.alertname $Alert.fingerprint "resolved" `
            $Alert.startsAt $End $Alert.labels.service $Alert.labels.severity
    }
    [void](Post @($Resolved))
}

function Resolve-AllPhase10 {
    [void](Sql @"
WITH active AS (
    SELECT f.* FROM raw_alerts f
    WHERE f.fingerprint LIKE 'p10-%' AND f.status='firing'
      AND NOT EXISTS (
          SELECT 1 FROM raw_alerts r
          WHERE r.status='resolved' AND r.fingerprint=f.fingerprint
            AND r.starts_at IS NOT DISTINCT FROM f.starts_at
      )
), processed AS (
    SELECT result.*
    FROM active alert
    CROSS JOIN LATERAL process_bpo_alert(jsonb_build_object(
        'event_key', alert.fingerprint || '|resolved-cleanup|' || alert.id,
        'fingerprint', alert.fingerprint,
        'status', 'resolved',
        'alert_name', alert.alert_name,
        'severity', COALESCE(alert.severity, 'trung_binh'),
        'provider', alert.provider,
        'service', alert.service,
        'vlan', alert.vlan,
        'project_name', alert.project_name,
        'starts_at', alert.starts_at,
        'ends_at', CURRENT_TIMESTAMP,
        'received_at', CURRENT_TIMESTAMP,
        'payload', '{}'::jsonb
    )) result
)
SELECT count(*) FROM processed;
"@)
    return Wait-Until {
        (Sql "SELECT count(*) FROM raw_alerts f WHERE f.fingerprint LIKE 'p10-%' AND f.status='firing' AND NOT EXISTS (SELECT 1 FROM raw_alerts r WHERE r.status='resolved' AND r.fingerprint=f.fingerprint AND r.starts_at IS NOT DISTINCT FROM f.starts_at);") -eq "0"
    } 180
}

function Counts([string]$Prefix) {
    $Value = Sql @"
SELECT count(*) FILTER (WHERE r.status='firing'),
       count(DISTINCT ia.incident_id) FILTER (WHERE r.status='firing'),
       count(DISTINCT x.glpi_ticket_id) FILTER (WHERE r.status='firing')
FROM raw_alerts r
LEFT JOIN incident_alerts ia ON ia.alert_id=r.id
LEFT JOIN incident_integrations x ON x.incident_id=ia.incident_id
WHERE r.fingerprint LIKE '$Prefix%';
"@
    $Part = $Value -split '\|'
    return @{ Received = [int]$Part[0]; Incidents = [int]$Part[1]; Tickets = [int]$Part[2] }
}

function Add-Row(
    [string]$Case, [int]$Sent, [int]$Received, [int]$Duplicates,
    [int]$Incidents, [int]$Tickets, [int]$FailureCount,
    [double]$Seconds, [string]$Result
) {
    [void]$Rows.Add([pscustomobject]@{
        case = $Case
        alerts_sent = $Sent
        alerts_received = $Received
        duplicates = $Duplicates
        incidents = $Incidents
        tickets = $Tickets
        failures = $FailureCount
        processing_time_seconds = [Math]::Round($Seconds, 3)
        result = $Result
    })
}

function Run-Case([string]$Case, [scriptblock]$Action) {
    if ($Only.Count -and $Case -notin $Only) { return }
    $script:Ran++
    try {
        & $Action
        Write-Host "[DAT] $Case"
    } catch {
        $script:Failures++
        Write-Host "[KHONG DAT] $Case - $($_.Exception.Message)"
    }
}

function Ensure-Stack {
    if ((Invoke-Docker ($ComposeArgs + @("up", "-d"))) -ne 0) { throw "Docker Compose khong khoi dong duoc." }
    foreach ($Container in @("bpo-postgres", "bpo-n8n", "bpo-glpi", "bpo-glpi-db", "bpo-prometheus", "bpo-alertmanager", "bpo-blackbox", "bpo-grafana")) {
        if (-not (Wait-Healthy $Container 120)) { throw "$Container khong healthy." }
    }
    if (-not (Wait-Webhook 90)) { throw "Webhook n8n chua dang ky runtime." }
    if (-not (Resolve-AllPhase10)) { throw "Khong don duoc fault Phase 10 cu." }
}

try {
    Ensure-Stack

    Run-Case "O-10" {
        $Prefix = "$Run-o10"
        $Alert = New-Alert "Phase10ConcurrentDuplicate" "$Prefix-one"
        Track @($Alert)
        $Json = Body @($Alert)
        $Watch = [Diagnostics.Stopwatch]::StartNew()
        $Jobs = 1..10 | ForEach-Object {
            Start-Job -ArgumentList $Webhook, $Json -ScriptBlock {
                param($Url, $Payload)
                try {
                    $Response = Invoke-RestMethod $Url -Method Post -ContentType "application/json" -Body $Payload -TimeoutSec 60
                    [pscustomobject]@{ ok = 1; status = $Response.status }
                } catch { [pscustomobject]@{ ok = 0; status = "error" } }
            }
        }
        $null = $Jobs | Wait-Job -Timeout 90
        $Responses = @($Jobs | Receive-Job)
        $Jobs | Remove-Job -Force
        $Watch.Stop()
        if (@($Responses | Where-Object ok -eq 1).Count -ne 10) { throw "Webhook dong thoi co request that bai." }
        if (-not (Wait-Until { (Counts $Prefix).Received -eq 1 } 60)) { throw "Raw alert khong dung 1." }
        $Count = Counts $Prefix
        $Duplicate = @($Responses | Where-Object status -eq "duplicate").Count
        if ($Duplicate -ne 9 -or $Count.Incidents -ne 1) { throw "Dedup dong thoi khong dung." }
        Add-Row "O-10" 10 $Count.Received $Duplicate $Count.Incidents $Count.Tickets 0 $Watch.Elapsed.TotalSeconds "DAT"
        Resolve @($Alert)
    }

    Run-Case "O-11" {
        $Prefix = "$Run-o11"
        $Alert = New-Alert "Phase10PostgresUnavailable" "$Prefix-one"
        Track @($Alert)
        $Marker = Sql "SELECT CURRENT_TIMESTAMP;"
        $Watch = [Diagnostics.Stopwatch]::StartNew()
        if ((Invoke-Docker @("stop", "bpo-postgres")) -ne 0) { throw "Khong dung duoc PostgreSQL." }
        $WasDown = (docker inspect --format '{{.State.Running}}' bpo-postgres 2>$null) -eq "false"
        if (-not $WasDown) { throw "PostgreSQL chua thuc su dung." }
        $Failed = 0
        try { [void](Post @($Alert) 10) } catch { $Failed = 1 }
        if ((Invoke-Docker @("start", "bpo-postgres")) -ne 0 -or -not (Wait-Healthy "bpo-postgres" 90)) { throw "PostgreSQL khong phuc hoi." }
        if (-not (Wait-Healthy "bpo-n8n" 90)) { [void](Invoke-Docker @("restart", "bpo-n8n")); if (-not (Wait-Healthy "bpo-n8n" 90)) { throw "n8n khong phuc hoi." } }
        $ExecutionFailures = [int](Sql "SELECT count(*) FROM n8n.execution_entity execution WHERE to_jsonb(execution)->>'workflowId'='bpoAlertFlow01' AND status='error' AND (to_jsonb(execution)->>'startedAt')::timestamptz>='$Marker'::timestamptz;")
        $Failed = [Math]::Max($Failed, $ExecutionFailures)
        $BeforeRetry = Counts $Prefix
        if ($BeforeRetry.Received -eq 0) {
            $Failed = [Math]::Max($Failed, 1)
            [void](Post @($Alert))
        }
        if (-not (Wait-Until { (Counts $Prefix).Received -eq 1 } 60)) { throw "Alert khong duoc xu ly sau phuc hoi PostgreSQL." }
        $Watch.Stop(); $Count = Counts $Prefix
        if ($Count.Incidents -ne 1) { throw "Recovery PostgreSQL tao sai incident: failures=$Failed, incidents=$($Count.Incidents)." }
        Add-Row "O-11" $(1 + [int]($BeforeRetry.Received -eq 0)) $Count.Received 0 $Count.Incidents $Count.Tickets $Failed $Watch.Elapsed.TotalSeconds "DAT"
        Resolve @($Alert)
    }

    Run-Case "O-12" {
        $Prefix = "$Run-o12"
        $Alert = New-Alert "Phase10GlpiUnavailable" "$Prefix-one"
        Track @($Alert)
        $Workflow = Get-Content -Raw (Join-Path $Root "n8n/workflows/bpo_notification_ticket.json") | ConvertFrom-Json
        $RetryNodes = @($Workflow.nodes | Where-Object retryOnFail)
        if (-not $RetryNodes.Count -or @($RetryNodes | Where-Object { $_.maxTries -lt 1 -or $_.maxTries -gt 3 }).Count) {
            throw "Retry GLPI khong duoc gioi han toi da 3 lan."
        }
        $Marker = Sql "SELECT CURRENT_TIMESTAMP;"
        $Watch = [Diagnostics.Stopwatch]::StartNew()
        if ((Invoke-Docker @("stop", "bpo-glpi")) -ne 0) { throw "Khong dung duoc GLPI." }
        [void](Post @($Alert))
        if (-not (Wait-Until {
            [int](Sql "SELECT count(*) FROM n8n.execution_entity execution WHERE to_jsonb(execution)->>'workflowId'='bpoNotifyTicket01' AND status='error' AND (to_jsonb(execution)->>'startedAt')::timestamptz>='$Marker'::timestamptz;") -gt 0
        } 60)) { throw "Khong ghi nhan execution GLPI that bai sau retry huu han." }
        $FailureCount = [int](Sql "SELECT count(*) FROM n8n.execution_entity execution WHERE to_jsonb(execution)->>'workflowId'='bpoNotifyTicket01' AND status='error' AND (to_jsonb(execution)->>'startedAt')::timestamptz>='$Marker'::timestamptz;")
        $Count = Counts $Prefix
        if ($Count.Received -ne 1 -or $Count.Incidents -ne 1 -or $Count.Tickets -ne 0) { throw "GLPI loi lam sai incident/ticket." }
        [void](Sql "SELECT bpo_mark_glpi(n.id,n.incident_id,NULL,'failed') FROM notification_events n JOIN raw_alerts r ON r.id=n.raw_alert_id WHERE r.fingerprint LIKE '$Prefix%' AND n.glpi_status='pending';")
        if ((Invoke-Docker @("start", "bpo-glpi")) -ne 0 -or -not (Wait-Healthy "bpo-glpi" 120)) { throw "GLPI khong phuc hoi." }
        $Watch.Stop()
        Add-Row "O-12" 1 $Count.Received 0 $Count.Incidents $Count.Tickets $FailureCount $Watch.Elapsed.TotalSeconds "DAT"
        Resolve @($Alert)
    }

    Run-Case "O-13" {
        $Prefix = "$Run-o13"
        $Start = (Get-Date).ToUniversalTime().ToString("o")
        $Alerts = @(1..20 | ForEach-Object { New-Alert "Phase10N8NRestart" "$Prefix-$_" "firing" $Start })
        Track $Alerts
        $Json = Body $Alerts
        $Watch = [Diagnostics.Stopwatch]::StartNew()
        $Job = Start-Job -ArgumentList $Webhook, $Json -ScriptBlock {
            param($Url, $Payload)
            try { Invoke-RestMethod $Url -Method Post -ContentType "application/json" -Body $Payload -TimeoutSec 120 | Out-Null; 0 } catch { 1 }
        }
        Start-Sleep -Milliseconds 200
        [void](Invoke-Docker @("restart", "bpo-n8n"))
        $null = $Job | Wait-Job -Timeout 130
        $FirstFailure = [int](($Job | Receive-Job | Select-Object -Last 1))
        $Job | Remove-Job -Force
        if (-not (Wait-Healthy "bpo-n8n" 120)) { throw "n8n khong healthy sau restart." }
        if (-not (Wait-Webhook 90)) { throw "Webhook n8n chua phuc hoi sau restart." }
        $BeforeRetry = Counts $Prefix
        [void](Post $Alerts 180)
        if (-not (Wait-Until { (Counts $Prefix).Received -eq 20 } 120)) { throw "Mat alert sau n8n restart/resend." }
        if (-not (Wait-Until { (Counts $Prefix).Tickets -eq 1 } 120)) { throw "Notification/GLPI khong phuc hoi sau n8n restart." }
        if (-not (Wait-Until {
            [int](Sql "SELECT count(*) FROM notification_events n JOIN raw_alerts r ON r.id=n.raw_alert_id WHERE r.fingerprint LIKE '$Prefix%' AND (n.email_status='pending' OR n.glpi_status='pending');") -eq 0
        } 60)) { throw "Notification con pending sau khi GLPI da tra ticket." }
        $Watch.Stop(); $Count = Counts $Prefix
        $Pending = [int](Sql "SELECT count(*) FROM notification_events n JOIN raw_alerts r ON r.id=n.raw_alert_id WHERE r.fingerprint LIKE '$Prefix%' AND (n.email_status='pending' OR n.glpi_status='pending');")
        if ($Count.Incidents -ne 1 -or $Pending -ne 0) { throw "n8n restart tao incident trung hoac de notification pending." }
        Add-Row "O-13" ($Alerts.Count * 2) $Count.Received $BeforeRetry.Received $Count.Incidents $Count.Tickets $FirstFailure $Watch.Elapsed.TotalSeconds "DAT"
        Resolve $Alerts
    }

    Run-Case "O-14" {
        $Prefix = "$Run-o14"
        $Start = (Get-Date).ToUniversalTime().ToString("o")
        $End = (Get-Date).ToUniversalTime().AddSeconds(10).ToString("o")
        $Firing = New-Alert "Phase10ResolvedOrdering" "$Prefix-one" "firing" $Start
        $Resolved = New-Alert "Phase10ResolvedOrdering" "$Prefix-one" "resolved" $Start $End
        Track @($Firing)
        $Watch = [Diagnostics.Stopwatch]::StartNew()
        [void](Post @($Resolved)); [void](Post @($Firing)); [void](Post @($Resolved)); [void](Post @($Resolved))
        if (-not (Wait-Until {
            (Sql "SELECT count(DISTINCT i.id) FROM incidents i JOIN incident_alerts ia ON ia.incident_id=i.id JOIN raw_alerts r ON r.id=ia.alert_id WHERE r.fingerprint='$Prefix-one' AND i.status='resolved';") -eq "1"
        } 60)) { throw "Resolved den truoc/bi lap khong dong incident." }
        $Watch.Stop(); $Count = Counts $Prefix
        $RawAll = [int](Sql "SELECT count(*) FROM raw_alerts WHERE fingerprint='$Prefix-one';")
        $Duplicate = 4 - $RawAll
        if ($RawAll -ne 2 -or $Duplicate -ne 2 -or $Count.Incidents -ne 1) { throw "Resolved lap tao du lieu trung hoac sai incident." }
        Add-Row "O-14" 4 $RawAll $Duplicate $Count.Incidents $Count.Tickets 0 $Watch.Elapsed.TotalSeconds "DAT"
    }

    Run-Case "O-15" {
        $Prefix = "$Run-o15"
        $Start = (Get-Date).ToUniversalTime().ToString("o")
        $Alerts = @(
            (New-Alert "CRMDown" "$Prefix-crm" "firing" $Start "" "crm"),
            (New-Alert "CFONODown" "$Prefix-cfono" "firing" $Start "" "cfono")
        )
        Track $Alerts
        $Watch = [Diagnostics.Stopwatch]::StartNew(); [void](Post $Alerts)
        if (-not (Wait-Until { (Counts $Prefix).Received -eq 2 } 60)) { throw "Khong nhan du hai alert doc lap." }
        $Watch.Stop(); $Count = Counts $Prefix
        if ($Count.Incidents -ne 2) { throw "Hai su co doc lap bi gom sai trong correlation window." }
        Add-Row "O-15" 2 $Count.Received 0 $Count.Incidents $Count.Tickets 0 $Watch.Elapsed.TotalSeconds "DAT"
        Resolve $Alerts
    }

    Run-Case "O-16" {
        foreach ($Size in @(10, 50, 100)) {
            $Prefix = "$Run-o16-$Size"
            $Start = (Get-Date).ToUniversalTime().ToString("o")
            $Alerts = @(1..$Size | ForEach-Object { New-Alert "Phase10Storm$Size" "$Prefix-$_" "firing" $Start })
            Track $Alerts
            $Watch = [Diagnostics.Stopwatch]::StartNew(); [void](Post $Alerts 240)
            if (-not (Wait-Until { (Counts $Prefix).Received -eq $Size } 180)) { throw "Storm $Size bi mat alert." }
            $Watch.Stop(); $Count = Counts $Prefix
            if ($Count.Incidents -ne 1) { throw "Storm $Size tao sai so incident." }
            Add-Row "O-16-$Size" $Size $Count.Received 0 $Count.Incidents $Count.Tickets 0 $Watch.Elapsed.TotalSeconds "DAT"
            Resolve $Alerts
        }
    }
} finally {
    [void](Invoke-Docker @("start", "bpo-postgres", "bpo-glpi", "bpo-n8n"))
    if (Wait-Healthy "bpo-postgres" 90 -and Wait-Healthy "bpo-n8n" 90 -and Wait-Webhook 90) {
        try {
            if (-not (Resolve-AllPhase10)) { throw "Con firing alert Phase 10." }
            $OpenTest = [int](Sql "SELECT count(DISTINCT i.id) FROM incidents i JOIN incident_alerts ia ON ia.incident_id=i.id JOIN raw_alerts r ON r.id=ia.alert_id WHERE r.fingerprint LIKE 'p10-%' AND i.status='open';")
            $DuplicateResolved = [int](Sql "SELECT COALESCE(sum(extra),0) FROM (SELECT GREATEST(count(*)-1,0) AS extra FROM notification_events n JOIN raw_alerts r ON r.id=n.raw_alert_id WHERE r.fingerprint LIKE '$Run-%' AND n.event_type='resolved' GROUP BY n.incident_id) measured;")
            if ($OpenTest -ne 0 -or $DuplicateResolved -ne 0) {
                throw "Cleanup sai: open_incidents=$OpenTest, duplicate_resolved_notifications=$DuplicateResolved."
            }
        } catch {
            $script:Failures++
            Write-Host "[KHONG DAT] Cleanup Phase 10 - $($_.Exception.Message)"
        }
    }
    if ($Rows.Count) { $Rows | Export-Csv $CsvFile -NoTypeInformation -Encoding UTF8 }
}

if ($Failures -gt 0) {
    Write-Host "[KHONG DAT] Phase 10: $($Ran-$Failures)/$Ran case dat, ma thoat 1."
    exit 1
}
Write-Host "[DAT] Phase 10: $Ran/$Ran case dat, ma thoat 0."
exit 0
