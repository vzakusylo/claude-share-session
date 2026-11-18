#requires -Version 7.2
<#
.SYNOPSIS
  Shared Claude Code work between several Claude accounts on one Windows user.

.EXAMPLE
  pwsh -File share-work.ps1 status            # accounts, sessions per account, what is not mirrored yet
  pwsh -File share-work.ps1 push              # mirror sidebar sessions from the current account to the others
  pwsh -File share-work.ps1 sync -DryRun      # two-way mirror between all accounts, show only
  pwsh -File share-work.ps1 sync              # two-way mirror (run it while the desktop app is closed, or right before switching)
  pwsh -File share-work.ps1 brief             # briefing for the current folder (what other accounts did here)
  pwsh -File share-work.ps1 handoff -Title "..." -BodyFile note.md   # or pipe the body via stdin
  pwsh -File share-work.ps1 name 5e6f7a8b bob   # name an account
  pwsh -File share-work.ps1 resume            # print `claude --resume` commands for this folder's recent sessions (all accounts)
#>
param(
    [Parameter(Position = 0)] [ValidateSet('status', 'push', 'sync', 'brief', 'handoff', 'name', 'resume', 'log', 'after-turn')] [string] $Command = 'status',
    [Parameter(Position = 1)] [string] $Arg1,
    [Parameter(Position = 2)] [string] $Arg2,
    [switch] $DryRun,
    [string] $Cwd = (Get-Location).Path,
    [string] $Title = 'handoff',
    [string] $BodyFile,
    [string] $To = 'any',
    [string] $CliSessionId = $env:CLAUDE_CODE_SESSION_ID,
    [int] $DelaySeconds = 0
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\ShareWork.psm1') -Force

if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
try { Register-SwCurrentAccount } catch { }

$me = Get-SwCurrentAccount
$all = @(Get-SwAccounts)

function Show-Rows($rows) {
    if (-not $rows) { 'Nothing to do — everything is already mirrored.'; return }
    $rows | Sort-Object To, Action, Title | Format-Table Action, From, To, Title, Cwd -AutoSize | Out-String -Width 220
    '{0} change(s){1}' -f @($rows).Count, $(if ($DryRun) { ' (dry run, nothing written)' } else { '' })
}

switch ($Command) {
    'status' {
        "Current account: $($me.Name) ($($me.Uuid))"
        "Shared folder:   $(Get-SwHome)"
        "Sessions index:  $(Get-SwSessionsRoot)"
        ''
        $all | Format-Table Name, Uuid, PrimaryOrg, Sessions -AutoSize | Out-String -Width 200
        'Scheduled tasks per account:'
        $taskRows = foreach ($a in ($all | Where-Object PrimaryDir)) {
            $reg = Read-SwJsonFile (Get-SwTaskRegistryPath $a)
            foreach ($t in @($reg | Where-Object { $_ } | ForEach-Object { $_['scheduledTasks'] } | Where-Object { $_ })) {
                [pscustomobject]@{ Account = $a.Name; Id = $t['id']; Title = $t['displayName']; Enabled = $t['enabled']; LastRun = $t['lastRunAt'] }
            }
        }
        if ($taskRows) { $taskRows | Format-Table -AutoSize | Out-String -Width 200 } else { '  (none)'; '' }
        $policy = Get-SwTaskWritePolicy
        $pending = foreach ($a in $all) { Sync-SwAll -From $a -To $all -DryRun -Policy $policy }
        if ($pending) {
            'Not mirrored yet (run `sync` or `push`):'
            $pending | Group-Object From, To, Action | Select-Object Count, Name | Format-Table -AutoSize | Out-String
        } else { 'All sidebars and scheduled tasks are in sync.' }
        if ($policy.Note) { $policy.Note }
        elseif ($policy.ActiveUuid) { "(The task registry of the account open in the app — $($me.Name) — is never written; it receives tasks when another account is active.)" }
    }
    'push' {
        $others = @($all | Where-Object Uuid -ne $me.Uuid)
        $policy = Get-SwTaskWritePolicy
        $rows = Invoke-SwWithLock { Sync-SwAll -From $me -To $others -DryRun:$DryRun -Policy $policy }
        Show-Rows $rows
        if ($policy.Note) { $policy.Note }
    }
    'sync' {
        $policy = Get-SwTaskWritePolicy
        $rows = Invoke-SwWithLock {
            foreach ($a in $all) { Sync-SwAll -From $a -To $all -DryRun:$DryRun -Policy $policy }
        }
        Show-Rows $rows
        if ($policy.Note) { $policy.Note }
        if ($rows -and -not $DryRun -and (Get-Process -Name 'claude' -ErrorAction SilentlyContinue | Where-Object MainWindowTitle)) {
            "Note: the desktop app is running. Sessions added to the account that is open right now appear after you switch accounts or restart the app."
        }
    }
    'brief' {
        $b = Get-SwBriefing -Me $me -Cwd $Cwd
        if ($b) { $b } else { "No recent work from other accounts in $(Get-SwProjectKey $Cwd)." }
    }
    'handoff' {
        $body = if ($BodyFile) { Get-Content $BodyFile -Raw } else { [Console]::In.ReadToEnd() }
        if (-not $body -or -not $body.Trim()) { throw 'Empty handoff body. Pass -BodyFile or pipe text on stdin.' }
        $f = New-SwHandoff -Me $me -Cwd $Cwd -Body $body -Title $Title -CliSessionId $CliSessionId -To $To
        "Handoff saved: $f"
        $others = @($all | Where-Object Uuid -ne $me.Uuid)
        $rows = Invoke-SwWithLock { Sync-SwAll -From $me -To $others }
        "Sidebar and scheduled tasks mirrored to other accounts: $(@($rows).Count) change(s)."
    }
    'name' {
        if (-not $Arg1 -or -not $Arg2) { throw 'Usage: share-work.ps1 name <uuid-or-prefix> <name>' }
        $a = @($all | Where-Object { $_.Uuid -like "$Arg1*" })
        $uuid = if ($a.Count -eq 1) { $a[0].Uuid } elseif ($Arg1 -match '^[0-9a-f-]{36}$') { $Arg1 } else { throw "Account '$Arg1' not found or ambiguous." }
        $cfg = Get-SwConfig; $cfg.names[$uuid] = $Arg2; Save-SwConfig $cfg
        "Account $uuid is now '$Arg2'."
    }
    'resume' {
        $proj = Get-SwProjectKey $Cwd
        $rows = foreach ($st in Get-SwStatuses) {
            foreach ($s in @($st['sessions'])) {
                if ($s -and $s['project'] -eq $proj) {
                    [pscustomobject]@{ When = ([datetime]$s['at']).ToLocalTime().ToString('MM-dd HH:mm'); Account = $st['account']; Title = $s['title']; Resume = "claude --resume $($s['cliSessionId'])" }
                }
            }
        }
        if ($rows) { $rows | Sort-Object When -Descending | Select-Object -First 15 | Format-Table -AutoSize | Out-String -Width 200 }
        else { "No recorded sessions for $proj yet (they are recorded at the end of every turn once hooks are installed)." }
    }
    'after-turn' {
        # called in the background by hooks\turn-end.ps1
        try {
            if ($CliSessionId) { Update-SwStatus -Me $me -CliSessionId $CliSessionId -Cwd $(if ($PSBoundParameters.ContainsKey('Cwd')) { $Cwd } else { '' }) }
            if ($env:SHAREWORK_NO_PUSH -ne '1') {
                $others = @($all | Where-Object Uuid -ne $me.Uuid)
                Invoke-SwWithLock { Sync-SwAll -From $me -To $others } | Out-Null
            }
        } catch { Write-SwLog "after-turn error: $($_.Exception.Message)" }
    }
    'log' { Get-Content (Join-Path (Get-SwHome) 'sync.log') -Tail 40 -ErrorAction SilentlyContinue }
}
