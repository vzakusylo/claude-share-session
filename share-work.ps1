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
    [Parameter(Position = 0)] [ValidateSet('status', 'push', 'sync', 'brief', 'handoff', 'name', 'resume', 'log', 'after-turn', 'switch', 'usage')] [string] $Command = 'status',
    [Parameter(Position = 1)] [string] $Arg1,
    [Parameter(Position = 2)] [string] $Arg2,
    [Parameter(Position = 3)] [string] $Arg3,
    [switch] $DryRun,
    [string] $Cwd = (Get-Location).Path,
    [string] $Title = 'handoff',
    [string] $BodyFile,
    [string] $To = 'any',
    [string] $CliSessionId = $env:CLAUDE_CODE_SESSION_ID,
    [int] $DelaySeconds = 0,
    [string] $Account,
    [string] $FiveHourReset,
    [string] $WeeklyReset,
    [switch] $Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/ShareWork.psm1') -Force

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
        $pending = @(foreach ($a in $all) { Sync-SwAll -From $a -To $all -DryRun -Policy $policy })
        $missingPlugins = @($pending | Where-Object Action -eq 'plugin-missing')
        $pending = @($pending | Where-Object Action -ne 'plugin-missing')
        'Environment:'
        $envRows = foreach ($a in ($all | Where-Object PrimaryDir)) {
            $pd = Read-SwJsonFile (Join-Path (Split-Path (Get-SwSessionsRoot) -Parent) 'ccd-session-presets.json')
            $pc = if ($pd -and $pd['byAccount'] -and $pd['byAccount'][$a.Uuid]) { @($pd['byAccount'][$a.Uuid]['presets']).Count } else { 0 }
            $pl = Get-SwPluginIds $a
            [pscustomobject]@{ Account = $a.Name; Presets = $pc; Plugins = $(if ($null -eq $pl) { '?' } else { @($pl).Count }) }
        }
        $envRows | Format-Table -AutoSize | Out-String -Width 200
        $tomb = @($pending | Where-Object { $_.Action -in 'tombstone', 'session-removed' })
        "Pending session deletions: $(@($tomb | Where-Object Action -eq 'tombstone').Count)"
        foreach ($m in $missingPlugins) { "  plugin '$($m.Title)' is installed in $($m.From) but not in $($m.To)" }
        ''
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
        $rows = Invoke-SwWithLock { Sync-SwEverything -Accounts $all -DryRun:$DryRun -Policy $policy -Reason 'sync' }
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
            if ($CliSessionId) { try { Add-SwTokenUsage -Account $me -CliSessionId $CliSessionId | Out-Null } catch { Write-SwLog "token usage error: $($_.Exception.Message)" } }
            if ($env:SHAREWORK_NO_PUSH -ne '1') {
                $others = @($all | Where-Object Uuid -ne $me.Uuid)
                $rows = @(Invoke-SwWithLock { Sync-SwAll -From $me -To $others })
                foreach ($r in $rows) { Write-SwDebug ("after-turn:   {0,-16} {1} -> {2}  '{3}'" -f $r.Action, $r.From, $r.To, $r.Title) }
                Write-SwDebug ("after-turn: {0} -> others, {1} change(s)" -f $me.Name, $rows.Count)
            }
        } catch { Write-SwLog "after-turn error: $($_.Exception.Message)" }
    }
    'switch' {
        # started in the background by hooks/session-start.ps1 on the first session after an account switch
        try {
            $rows = @(Invoke-SwWithLock { Sync-SwEverything -Accounts $all -Policy (Get-SwTaskWritePolicy) -Reason "switch to $($me.Name)" })
            Write-SwLog ("switch sync for {0}: {1} change(s)" -f $me.Name, $rows.Count)
        } catch { Write-SwLog "switch error: $($_.Exception.Message)"; Write-SwDebug "switch error: $($_.Exception.Message)" }
    }
    'usage' {
        # share-work usage                      table + forecast + recommendation
        # share-work usage paste [-Account x]    paste the Usage page text (stdin or clipboard)
        # share-work usage set 23 75 -FiveHourReset "8:10 PM" -WeeklyReset "Tue 11:00 PM" [-Account x]
        # share-work usage fetch                 like claude-swap: API, for the account logged in to the CLI
        $who = if ($Account) {
            $m = @($all | Where-Object { $_.Name -eq $Account -or $_.Uuid -like "$Account*" })
            if ($m.Count -ne 1) { throw "Account '$Account' not found or ambiguous." }; $m[0]
        } else { $me }
        switch ($Arg1) {
            'paste' {
                $text = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { Get-Clipboard -Raw }
                $u = ConvertFrom-SwUsageText -Text ([string]$text)
                if (-not $u.Count) { throw 'No usage found in the text. Copy the whole "Plan usage limits" block (5-hour limit ... %, Weekly ... %).' }
                Add-SwUsageSnapshot -Account $who -Usage $u -Source 'paste' | Out-Null
                "Saved for $($who.Name)."
            }
            'set' {
                $u = @{}; $now = Get-Date
                if ($Arg2) { $u['fiveHour'] = @{ pct = [double]$Arg2 }; if ($FiveHourReset) { $u['fiveHour']['resetsAt'] = (ConvertFrom-SwResetText $FiveHourReset $now).ToUniversalTime().ToString('o') } }
                if ($Arg3) { $u['sevenDay'] = @{ pct = [double]$Arg3 }; if ($WeeklyReset) { $u['sevenDay']['resetsAt'] = (ConvertFrom-SwResetText $WeeklyReset $now).ToUniversalTime().ToString('o') } }
                if (-not $u.Count) { throw 'Usage: share-work usage set <5h%> [<weekly%>] [-FiveHourReset "8:10 PM"] [-WeeklyReset "Tue 11:00 PM"] [-Account name]' }
                Add-SwUsageSnapshot -Account $who -Usage $u -Source 'manual' | Out-Null
                "Saved for $($who.Name)."
            }
            'fetch' {
                $cliMe = $null
                try {
                    $cj = Get-Content (Join-Path $HOME '.claude.json') -Raw | ConvertFrom-Json -AsHashtable
                    $uuid = $cj['oauthAccount']['accountUuid']; $cliMe = $all | Where-Object Uuid -eq $uuid | Select-Object -First 1
                } catch { }
                if (-not $cliMe) { throw 'The account logged in to the Claude Code CLI is not one of the desktop accounts; paste the Usage page instead.' }
                Add-SwUsageSnapshot -Account $cliMe -Usage (Get-SwUsageFromApi) -Source 'api' | Out-Null
                "Fetched for $($cliMe.Name)."
            }
        }
        if ($Arg1 -and $Arg1 -notin 'paste', 'set', 'fetch') { throw "Unknown: usage $Arg1 (use paste, set, fetch)" }
        $now = (Get-Date).ToUniversalTime()
        $rec = Get-SwSwitchRecommendation -Me $me -Accounts $all -NowUtc $now
        if ($Json) {
            $acc = foreach ($f in @($rec.Me) + @($rec.Others)) {
                [ordered]@{ account = $f.Account.Name; current = ($f.Account.Uuid -eq $me.Uuid); stale = $f.Stale; headroomPct = $f.Headroom
                    fiveHour = $f.FiveHour | Select-Object Pct, ResetsAt, RatePerHour, EtaLine, EtaFull, WillLast, AgeMinutes, Basis
                    sevenDay = $f.SevenDay | Select-Object Pct, ResetsAt, RatePerHour, EtaLine, EtaFull, WillLast, AgeMinutes, Basis }
            }
            [ordered]@{ schemaVersion = 1; level = $rec.Level; reason = $rec.Reason; switchTo = $(if ($rec.Target) { $rec.Target.Name }); switchToReason = $rec.TargetReason; accounts = @($acc) } | ConvertTo-Json -Depth 6
            break
        }
        $s = Get-SwUsageSettings
        "Plan usage  (switch line: 5-hour $($s.Threshold)%, weekly $($s.WeeklyThreshold)%)"
        ''
        foreach ($f in @($rec.Me) + @($rec.Others)) {
            $mark = if ($f.Account.Uuid -eq $me.Uuid) { '*' } else { ' ' }
            $age = @($f.FiveHour.AgeMinutes, $f.SevenDay.AgeMinutes | Where-Object { $null -ne $_ } | Measure-Object -Minimum)
            "$mark $($f.Account.Name)" + $(if (-not $f.Known) { '   no data — paste its Usage page: share-work usage paste -Account ' + $f.Account.Name } else { "   measured $([int]$age.Minimum) min ago" + $(if ($f.Stale) { ' (old)' } else { '' }) })
            foreach ($w in $f.FiveHour, $f.SevenDay) {
                if (-not $w.Known) { continue }
                $label = if ($w.Window -eq 'fiveHour') { '5-hour ' } else { 'weekly ' }
                $pred = if ($w.EtaFull -and $w.WillLast -eq $false) { "  -> 100% at $($w.EtaFull.ToLocalTime().ToString('ddd HH:mm')), before the reset" }
                        elseif ($w.RatePerHour) { "  -> $($w.RatePerHour)%/h, lasts to the reset" } else { '' }
                '    {0} {1} {2,5}%  {3}{4}' -f $label, (Format-SwUsageBar $w.Pct), $w.Pct, (Format-SwResetIn $w.ResetsAt $now), $pred
            }
            $tk = @(Get-SwTokenRows $f.Account $now.AddHours(-5))
            if ($tk) { '    tokens  last 5 h: {0:N0} weighted ({1:N0} out) in {2} turn(s)' -f ($tk | Measure-Object { [double]$_['weighted'] } -Sum).Sum, ($tk | Measure-Object { [double]$_['output'] } -Sum).Sum, $tk.Count }
        }
        ''
        switch ($rec.Level) {
            'now' { "SWITCH NOW: $($rec.Reason)." }
            'soon' { "Switch soon: $($rec.Reason)." }
            default { "No need to switch: $($me.Name) has $(if ($null -ne $rec.Me.Headroom) { "$([math]::Round($rec.Me.Headroom))% headroom" } else { 'no usage data yet' })." }
        }
        if ($rec.Target -and $rec.Level -ne 'ok') { "Best account: $($rec.Target.Name) — $($rec.TargetReason). Type /handoff, then switch in the app." }
        elseif ($rec.Target) { "Next best: $($rec.Target.Name) — $($rec.TargetReason)." }
    }
    'log' {
        $h = Get-SwHome; $dbg = Join-Path $h 'debug.log'
        switch ($Arg1) {
            'on' { $cfg = Get-SwConfig; $cfg['debugLog'] = $true; Save-SwConfig $cfg; "Debug log on: $dbg" }
            'off' { $cfg = Get-SwConfig; $cfg['debugLog'] = $false; Save-SwConfig $cfg; 'Debug log off (existing log kept; `log clear` removes it).' }
            'clear' {
                $cfg = Get-SwConfig; $cfg['debugLog'] = $false; Save-SwConfig $cfg
                Remove-Item $dbg -Force -ErrorAction SilentlyContinue
                'Debug log removed and turned off.'
            }
            'debug' { if (Test-Path $dbg) { Get-Content $dbg -Tail 80 } else { 'No debug log (turn it on with `log on`).' } }
            default { Get-Content (Join-Path $h 'sync.log') -Tail 40 -ErrorAction SilentlyContinue }
        }
    }
}
