#requires -Version 7.2
# SessionStart hook: inject a briefing about other accounts' work in this project.
# Fails open: any error -> no output, exit 0 (coordination must never block a session).
try {
    Import-Module (Join-Path $PSScriptRoot '..\src\ShareWork.psm1') -Force
    $raw = [Console]::In.ReadToEnd()
    $in = if ($raw) { $raw | ConvertFrom-Json -AsHashtable } else { @{} }
    $cwd = if ($in['cwd']) { $in['cwd'] } else { (Get-Location).Path }
    try { Register-SwCurrentAccount } catch { }
    $me = Get-SwCurrentAccount
    if (-not $me) { exit 0 }
    $brief = Get-SwBriefing -Me $me -Cwd $cwd
    if ($brief) {
        @{ hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $brief } } |
            ConvertTo-Json -Depth 4 -Compress
    }
} catch {
    try { Import-Module (Join-Path $PSScriptRoot '..\src\ShareWork.psm1'); Write-SwLog "session-start hook error: $($_.Exception.Message)" } catch { }
}
exit 0
