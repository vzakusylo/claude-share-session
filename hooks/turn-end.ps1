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
    $script = Join-Path $PSScriptRoot '../share-work.ps1'
    $exe = (Get-Process -Id $PID).Path
    if ($IsWindows) {
        $a = @('-NoLogo', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-File', "`"$script`"", 'after-turn',
            '-CliSessionId', $sid, '-DelaySeconds', '6')
        if ($cwd) { $a += @('-Cwd', "`"$cwd`"") }
        Start-Process -FilePath $exe -ArgumentList $a -WindowStyle Hidden | Out-Null
    } else {
        # macOS / Linux: detach with nohup so the hook returns immediately and the child survives it
        $q = { param($s) "'" + ($s -replace "'", "'\''") + "'" }
        $cmd = "nohup $(& $q $exe) -NoLogo -NoProfile -NonInteractive -File $(& $q $script) after-turn -CliSessionId $(& $q $sid) -DelaySeconds 6"
        if ($cwd) { $cmd += " -Cwd $(& $q $cwd)" }
        # ProcessStartInfo.ArgumentList passes argv as-is (Start-Process re-splits the string on Unix)
        $psi = [System.Diagnostics.ProcessStartInfo]::new('/bin/sh')
        $psi.ArgumentList.Add('-c'); $psi.ArgumentList.Add("$cmd >/dev/null 2>&1 &")
        $psi.UseShellExecute = $false
        [System.Diagnostics.Process]::Start($psi).WaitForExit(5000) | Out-Null   # sh exits at once, the child keeps running
    }
    # usage: warn in the app when this account is at, or predicted to reach, its limit (cached data only, no network)
    if ($Event -eq 'Stop') {
        try {
            Import-Module (Join-Path $PSScriptRoot '../src/ShareWork.psm1') -Force
            $me = Get-SwCurrentAccount
            if ($me) { $msg = Get-SwSwitchNotice -Me $me; if ($msg) { @{ systemMessage = $msg } | ConvertTo-Json -Compress } }
        } catch { }
    }
} catch {
    try { Import-Module (Join-Path $PSScriptRoot '../src/ShareWork.psm1'); Write-SwLog "$Event hook error: $($_.Exception.Message)" } catch { }
}
exit 0
