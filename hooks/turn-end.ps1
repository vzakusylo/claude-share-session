#requires -Version 7.2
# Stop / SessionEnd hook: hand everything to a detached background process and return at once.
# The background process (share-work.ps1 after-turn) waits a few seconds, because the desktop app writes
# the final session index just after the turn ends, then records this account's status and mirrors the
# sidebar to the other accounts. Fails open: any error -> exit 0.
param([string] $Event = 'Stop')
try {
    $raw = [Console]::In.ReadToEnd()
    $in = if ($raw) { $raw | ConvertFrom-Json -AsHashtable } else { @{} }
    $sid = [string]$in['session_id']
    $cwd = [string]$in['cwd']
    if (-not $sid) { exit 0 }
    $script = Join-Path $PSScriptRoot '..\share-work.ps1'
    $a = @('-NoLogo', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-File', "`"$script`"", 'after-turn',
        '-CliSessionId', $sid, '-DelaySeconds', '6')
    if ($cwd) { $a += @('-Cwd', "`"$cwd`"") }
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $a -WindowStyle Hidden | Out-Null
} catch {
    try { Import-Module (Join-Path $PSScriptRoot '..\src\ShareWork.psm1'); Write-SwLog "$Event hook error: $($_.Exception.Message)" } catch { }
}
exit 0
