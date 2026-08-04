$ErrorActionPreference = "Stop"

$Script = Join-Path $PSScriptRoot "test_phase_o.ps1"
& $Script
$MaThoat = $LASTEXITCODE

if ($null -eq $MaThoat) { $MaThoat = 1 }
exit $MaThoat
