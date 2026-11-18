#requires -Version 7.2
<#
.SYNOPSIS
  Installs shared-work hooks and skills into ~/.claude (Windows: %USERPROFILE%\.claude) (shared by every Claude account of this Windows user).
.PARAMETER Names
  Account names as "uuidPrefix=name,uuidPrefix=name", e.g. "1a2b3c4d=alice,5e6f7a8b=bob".
.PARAMETER Uninstall
  Removes the hooks and skills again (shared-work data folder is kept).
#>
param([string] $Names = '', [switch] $Uninstall, [string] $ClaudeDir = (Join-Path $HOME '.claude'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/ShareWork.psm1') -Force

$claudeDir = $ClaudeDir
$settingsPath = Join-Path $claudeDir 'settings.json'
$marker = ((Join-Path $PSScriptRoot 'hooks') | ConvertTo-Json -Compress).Trim('"')   # JSON-escaped hooks folder path
$pwsh = (Get-Command pwsh).Source

# --- settings.json hooks (backup first) --------------------------------------------------------
$settings = if (Test-Path $settingsPath) { Get-Content $settingsPath -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
Copy-Item $settingsPath ("$settingsPath.bak-sharework-{0:yyyyMMdd-HHmmss}" -f (Get-Date)) -ErrorAction SilentlyContinue
if (-not $settings.ContainsKey('hooks')) { $settings['hooks'] = @{} }

function Remove-OurHooks([hashtable]$hooks) {
    foreach ($ev in @($hooks.Keys)) {
        $kept = @($hooks[$ev] | Where-Object { -not (($_ | ConvertTo-Json -Depth 10 -Compress).Contains($marker)) })
        if ($kept.Count) { $hooks[$ev] = $kept } else { $hooks.Remove($ev) }
    }
}
Remove-OurHooks $settings['hooks']

if (-not $Uninstall) {
    function New-HookEntry([string]$script, [string[]]$extra = @(), [int]$timeout = 20) {
        @{ hooks = @(@{
                    type    = 'command'
                    command = $pwsh
                    args    = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'hooks' $script)) + $extra
                    timeout = $timeout
                }) }
    }
    $add = @{
        SessionStart = New-HookEntry 'session-start.ps1' @() 15
        Stop         = New-HookEntry 'turn-end.ps1' @('-Event', 'Stop')
        SessionEnd   = New-HookEntry 'turn-end.ps1' @('-Event', 'SessionEnd')
    }
    foreach ($ev in $add.Keys) {
        $cur = if ($settings['hooks'].ContainsKey($ev)) { @($settings['hooks'][$ev]) } else { @() }
        $settings['hooks'][$ev] = @($cur + $add[$ev])
    }
}
if ($settings['hooks'].Count -eq 0) { $settings.Remove('hooks') }
Write-SwFileAtomic $settingsPath ($settings | ConvertTo-Json -Depth 20)
"settings.json updated ($(if ($Uninstall) {'hooks removed'} else {'SessionStart, Stop, SessionEnd hooks'}))"

# --- skills --------------------------------------------------------------------------------
foreach ($s in 'handoff', 'shared-work') {
    $dst = Join-Path $claudeDir 'skills' $s
    if ($Uninstall) {
        if (Test-Path (Join-Path $dst '.sharework')) { Remove-Item $dst -Recurse -Force; "skill /$s removed" }
        continue
    }
    if ((Test-Path $dst) -and -not (Test-Path (Join-Path $dst '.sharework'))) { Write-Warning "skill folder $dst exists and is not ours — skipped"; continue }
    New-Item -ItemType Directory $dst -Force | Out-Null
    $skill = (Get-Content (Join-Path $PSScriptRoot 'skills' $s 'SKILL.md') -Raw).Replace('{{SHAREWORK_DIR}}\share-work.ps1', (Join-Path $PSScriptRoot 'share-work.ps1'))
    [IO.File]::WriteAllText((Join-Path $dst 'SKILL.md'), $skill, [Text.UTF8Encoding]::new($false))
    Set-Content (Join-Path $dst '.sharework') "installed by $(Join-Path $PSScriptRoot 'install.ps1')"
    "skill /$s installed"
}
if ($Uninstall) { return }

# --- account names -------------------------------------------------------------------------
$cfg = Get-SwConfig
$accts = @(Get-SwAccounts)
foreach ($pair in ($Names -split '[,;]' | Where-Object { $_ -match '=' })) {
    $k, $v = $pair.Split('=', 2) | ForEach-Object Trim
    $a = @($accts | Where-Object { $_.Uuid -like "$k*" })
    if ($a.Count -eq 1) { $cfg.names[$a[0].Uuid] = $v } else { Write-Warning "account '$k' not found" }
}
Save-SwConfig $cfg
''
& (Join-Path $PSScriptRoot 'share-work.ps1') status
