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

function Invoke-SwWithLock([scriptblock]$Body, [int]$TimeoutMs = 20000) {
    $m = [System.Threading.Mutex]::new($false, $(if ($IsWindows) { 'Local\ClaudeShareWorkSync' } else { 'ClaudeShareWorkSync' }))
    $got = $false
    try {
        try { $got = $m.WaitOne($TimeoutMs) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if (-not $got) { Write-SwLog 'lock timeout, skipped'; return }
        & $Body
    } finally { if ($got) { $m.ReleaseMutex() }; $m.Dispose() }
}
