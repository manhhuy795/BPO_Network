$ErrorActionPreference = "Stop"

$Goc = Split-Path -Parent $PSScriptRoot
$LogFile = Join-Path $Goc "logs/pipeline_health_test.log"
$SoLoi = 0
$SoDat = 0

$ThanhPhan = @(
    [pscustomobject]@{ component = "alertmanager"; container = "bpo-alertmanager"; job = "blackbox_http"; alert = "AlertmanagerDown" },
    [pscustomobject]@{ component = "n8n";          container = "bpo-n8n";          job = "blackbox_http"; alert = "N8NDown" },
    [pscustomobject]@{ component = "postgres";     container = "bpo-postgres";     job = "blackbox_tcp";  alert = "PostgreSQLDown" },
    [pscustomobject]@{ component = "glpi";         container = "bpo-glpi";         job = "blackbox_http"; alert = "GLPIDown" },
    [pscustomobject]@{ component = "grafana";      container = "bpo-grafana";      job = "blackbox_http"; alert = "GrafanaDown" }
)

New-Item -ItemType Directory -Force (Split-Path -Parent $LogFile) | Out-Null
Set-Content -Encoding utf8 $LogFile "KIỂM THỬ SỨC KHỎE INCIDENT PIPELINE"

function Ghi([string]$NoiDung) {
    Write-Host $NoiDung
    Add-Content -Encoding utf8 $LogFile $NoiDung
}

function Cho([scriptblock]$DieuKien, [int]$Giay = 45) {
    $HetHan = (Get-Date).AddSeconds($Giay)
    while ((Get-Date) -lt $HetHan) {
        try { if (& $DieuKien) { return $true } } catch {}
        Start-Sleep -Seconds 1
    }
    return $false
}

function GiaTriProm([string]$BieuThuc) {
    $Q = [uri]::EscapeDataString($BieuThuc)
    $KetQua = (Invoke-RestMethod "http://localhost:9090/api/v1/query?query=$Q" -TimeoutSec 5).data.result
    if (@($KetQua).Count -ne 1) { return $null }
    return [double]$KetQua[0].value[1]
}

function TargetUp($Muc) {
    $Targets = (Invoke-RestMethod http://localhost:9090/api/v1/targets -TimeoutSec 5).data.activeTargets
    return @($Targets | Where-Object {
        $_.labels.job -eq $Muc.job -and
        $_.labels.component -eq $Muc.component -and
        $_.health -eq "up"
    }).Count -eq 1
}

function ProbeValue($Muc) {
    return GiaTriProm "probe_success{job=`"$($Muc.job)`",component=`"$($Muc.component)`"}"
}

function AlertFiring($Muc) {
    return (GiaTriProm "ALERTS{alertname=`"$($Muc.alert)`",alertstate=`"firing`"}") -eq 1
}

function ContainerHealthy([string]$Ten) {
    $TrangThai = docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' $Ten 2>$null
    return $LASTEXITCODE -eq 0 -and $TrangThai -eq "running|healthy"
}

function BatContainer([string]$Ten) {
    $null = docker start $Ten 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Không khởi động lại được $Ten." }
    if (-not (Cho { ContainerHealthy $Ten } 180)) { throw "$Ten chưa healthy sau khi khởi động lại." }
}

function PhucHoiToanBo {
    foreach ($Ten in @("bpo-postgres", "bpo-n8n", "bpo-alertmanager", "bpo-glpi", "bpo-grafana")) {
        try {
            $DangChay = (docker inspect --format '{{.State.Status}}' $Ten 2>$null) -eq "running"
            if (-not $DangChay) { $null = docker start $Ten 2>&1 }
        } catch {}
    }
    foreach ($Ten in @("bpo-postgres", "bpo-n8n", "bpo-alertmanager", "bpo-glpi", "bpo-grafana")) {
        $null = Cho { ContainerHealthy $Ten } 180
    }
}

try {
    foreach ($Muc in $ThanhPhan) {
        if (-not (Cho { (TargetUp $Muc) -and (ProbeValue $Muc) -eq 1 } 20)) {
            throw "Chưa có target healthy cho component $($Muc.component)."
        }
    }
    Ghi "[ĐẠT] Năm target pipeline xuất hiện riêng và đều healthy."

    foreach ($Muc in $ThanhPhan) {
        $Dat = $false
        try {
            $null = docker stop $Muc.container 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Không dừng được $($Muc.container)." }

            if (-not (Cho { (ProbeValue $Muc) -eq 0 } 35)) {
                throw "probe_success của $($Muc.component) không chuyển về 0."
            }
            if (-not (Cho { AlertFiring $Muc } 45)) {
                throw "$($Muc.alert) không firing."
            }
            $Dat = $true
        } catch {
            Ghi "[KHÔNG ĐẠT] $($Muc.component) - $($_.Exception.Message)"
        } finally {
            try { BatContainer $Muc.container } catch {
                $Dat = $false
                Ghi "[KHÔNG ĐẠT] Cleanup $($Muc.component) - $($_.Exception.Message)"
            }
        }

        if ($Dat -and (Cho {
            (TargetUp $Muc) -and (ProbeValue $Muc) -eq 1 -and -not (AlertFiring $Muc)
        } 60)) {
            $SoDat++
            Ghi "[ĐẠT] $($Muc.component): probe 0/1 và alert firing/resolved đúng."
        } else {
            $SoLoi++
            if ($Dat) { Ghi "[KHÔNG ĐẠT] $($Muc.component) chưa phục hồi target hoặc alert." }
        }
    }
} catch {
    $SoLoi++
    Ghi "[KHÔNG ĐẠT] Chuẩn bị kiểm thử - $($_.Exception.Message)"
} finally {
    PhucHoiToanBo
}

if ($SoLoi -gt 0 -or $SoDat -ne 5) {
    Ghi "[KHÔNG ĐẠT] Pipeline health đạt $SoDat/5, còn $SoLoi lỗi, mã thoát 1."
    exit 1
}

Ghi "[ĐẠT] Pipeline health đạt 5/5, mã thoát 0."
exit 0
