#requires -Version 7.2
# Runs every test. The synthetic suite always runs; the suites that work on a COPY of your real Claude data
# run only when the desktop app's data folder exists on this machine (skip them with -SyntheticOnly).
param([switch] $SyntheticOnly)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$pwsh = (Get-Process -Id $PID).Path
$tmp = [IO.Path]::GetTempPath()
$failed = @()

function Run([string]$name, [scriptblock]$body) {
    "=== $name"
    & $body
    if ($LASTEXITCODE -ne 0) { $script:failed += $name; "--- $name FAILED" } else { "--- $name ok" }
    ''
}

Run 'core (synthetic)' { & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'test-core.ps1') -Work (Join-Path $tmp 'sharework-core') }

$hasReal = $false
if (-not $SyntheticOnly) {
    try { Import-Module (Join-Path $repo 'src/ShareWork.psm1') -Force; $root = Get-SwSessionsRoot; $hasReal = @(Get-ChildItem $root -Directory).Count -ge 2 } catch { }
}
if ($hasReal) {
    Run 'scheduled tasks (copy of real data)' { & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'test-scheduled.ps1') -Work (Join-Path $tmp 'sharework-sched') }
    if (Get-Command node -ErrorAction SilentlyContinue) {
        Run 'mirror fidelity (real data, read-only)' { node (Join-Path $PSScriptRoot 'compare-mirror.js') $root }
    }
} else { 'Skipping real-data suites (no Claude desktop data with 2+ accounts here, or -SyntheticOnly).' }

if ($failed) { "FAILED: $($failed -join ', ')"; exit 1 } else { 'ALL SUITES PASSED' }
