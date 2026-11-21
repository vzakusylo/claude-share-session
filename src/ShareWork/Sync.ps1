# Write policy, combined sync (sessions + tasks) and the cross-process lock.
# Part of ShareWork.psm1 (dot-sourced into the module scope).

function Test-SwDesktopRunning {
    [bool](Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^claude$' -and $_.Path -and ($_.Path -like '*\WindowsApps\Claude_*' -or $_.Path -like '*AnthropicClaude*' -or $_.Path -like '*/Claude.app/Contents/MacOS/*') })
}

function Get-SwTaskWritePolicy {
    <#
      Which registries may be written now.
        Inside a desktop session: everything except the active account; deletions allowed from it.
        Terminal, app closed: everything; no deletions (we cannot tell which account deleted a task).
        Terminal, app running: nothing (we do not know which account the app has open).
    #>
    if ($env:CLAUDE_CODE_ACCOUNT_UUID) {
        return [pscustomobject]@{ Enabled = $true; ActiveUuid = $env:CLAUDE_CODE_ACCOUNT_UUID; AllowDeletesFrom = $env:CLAUDE_CODE_ACCOUNT_UUID; Note = $null }
    }
    if (-not (Test-SwDesktopRunning)) {
        return [pscustomobject]@{ Enabled = $true; ActiveUuid = $null; AllowDeletesFrom = $null; Note = $null }
    }
    [pscustomobject]@{ Enabled = $false; ActiveUuid = $null; AllowDeletesFrom = $null
        Note = 'Scheduled tasks skipped: the desktop app is running and this terminal cannot tell which account it has open. Run the sync from a Claude session (/shared-work) or with the app closed.' }
}

function Sync-SwAll {
    <# Sessions + scheduled tasks from one account to others, honouring the task write policy. #>
    param([Parameter(Mandatory)] $From, [Parameter(Mandatory)] [object[]] $To, [switch] $DryRun, $Policy = (Get-SwTaskWritePolicy))
    $rows = @(Sync-SwSessions -From $From -To $To -DryRun:$DryRun)
    if ($Policy.Enabled) {
        $rows += @(Sync-SwScheduledTasks -From $From -To $To -ActiveUuid $Policy.ActiveUuid `
                -AllowDeletes:($Policy.AllowDeletesFrom -and $Policy.AllowDeletesFrom -eq $From.Uuid) -DryRun:$DryRun)
    }
    $rows += @(Sync-SwEnvironment -From $From -To $To -DryRun:$DryRun -Policy $Policy)
    $rows
}

function Sync-SwEverything {
    <#
      Full merge between ALL accounts: every account is a source once, so every chat reaches every account and a
      deletion made in ANY account removes the chat everywhere (the account open in the app is cleaned later).
      Used when the user switches accounts and by `share-work sync`.
    #>
    param([object[]] $Accounts = @(Get-SwAccounts), [switch] $DryRun, $Policy = (Get-SwTaskWritePolicy), [string] $Reason = 'sync')
    Write-SwDebug ("{0}: start, {1} account(s): {2}; open in app: {3}; dryRun={4}" -f $Reason, @($Accounts).Count,
        (($Accounts | ForEach-Object Name) -join ', '), $(if ($Policy.ActiveUuid) { ($Accounts | Where-Object Uuid -eq $Policy.ActiveUuid).Name } else { '-' }), [bool]$DryRun)
    $rows = @(foreach ($src in $Accounts) { Sync-SwAll -From $src -To $Accounts -DryRun:$DryRun -Policy $Policy })
    foreach ($r in $rows) { Write-SwDebug ("{0}:   {1,-16} {2} -> {3}  '{4}'  {5}" -f $Reason, $r.Action, $r.From, $r.To, $r.Title, $r.Cwd) }
    Write-SwDebug ("{0}: done, {1} change(s){2}" -f $Reason, $rows.Count, $(if ($rows) { ': ' + (($rows | Group-Object Action | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', ') } else { '' }))
    $rows
}

function Test-SwAccountSwitch {
    <#
      Records the account that started a session; returns the previous account's uuid when it differs
      (a switch), '' on the very first run, $null when nothing changed.
    #>
    param([Parameter(Mandatory)] $Me)
    $p = Join-Path (Get-SwHome) 'last-account.json'
    $prev = Read-SwJsonFile $p
    $prevUuid = if ($prev) { [string]$prev['uuid'] } else { $null }
    if ($prevUuid -eq $Me.Uuid) { return $null }
    Write-SwFileAtomic $p (@{ uuid = $Me.Uuid; name = $Me.Name; at = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json)
    $prevName = if ($prev) { $prev['name'] } else { '(none)' }
    Write-SwLog ("account switch {0} -> {1}" -f $prevName, $Me.Name)
    Write-SwDebug ("switch detected: {0} -> {1}" -f $prevName, $Me.Name)
    if ($prevUuid) { $prevUuid } else { '' }
}

function Start-SwDetached([string[]] $ShareWorkArgs) {
    <# Run share-work.ps1 with these arguments in the background (hidden window / nohup) and return at once. #>
    $script = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../share-work.ps1'))
    $exe = (Get-Process -Id $PID).Path
    if ($IsWindows) {
        $a = @('-NoLogo', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-File', "`"$script`"") + $ShareWorkArgs
        Start-Process -FilePath $exe -ArgumentList $a -WindowStyle Hidden | Out-Null
    } else {
        $q = { param($s) "'" + ($s -replace "'", "'\''") + "'" }
        $cmd = "nohup $(& $q $exe) -NoLogo -NoProfile -NonInteractive -File $(& $q $script) " + (($ShareWorkArgs | ForEach-Object { & $q $_ }) -join ' ') + ' >/dev/null 2>&1 &'
        $psi = [System.Diagnostics.ProcessStartInfo]::new('/bin/sh'); $psi.ArgumentList.Add('-c'); $psi.ArgumentList.Add($cmd)
        $psi.UseShellExecute = $false
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    }
}

function Invoke-SwWithLock([scriptblock]$Body, [int]$TimeoutMs = 20000) {
    $m = [System.Threading.Mutex]::new($false, $(if ($IsWindows) { 'Local\ClaudeShareWorkSync' } else { 'ClaudeShareWorkSync' }))
    $got = $false
    try {
        try { $got = $m.WaitOne($TimeoutMs) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if (-not $got) { Write-SwLog 'lock timeout, skipped'; return }
        & $Body
    } finally { if ($got) { $m.ReleaseMutex() }; $m.Dispose() }
}
