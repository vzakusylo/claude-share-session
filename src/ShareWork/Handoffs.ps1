# Handoff notes written before switching accounts.
# Part of ShareWork.psm1 (dot-sourced into the module scope).


function New-SwHandoff {
    param([Parameter(Mandatory)] $Me, [Parameter(Mandatory)] [string] $Cwd, [Parameter(Mandatory)] [string] $Body,
        [string] $Title = 'handoff', [string] $CliSessionId, [string] $To = 'any')
    $proj = Get-SwProjectKey $Cwd
    $dir = Join-Path (Get-SwHome) ("handoffs/" + (Get-SwProjectSlug $proj))
    $ts = Get-Date
    $file = Join-Path $dir ('{0:yyyyMMdd-HHmmss}-{1}.md' -f $ts, $Me.Name)
    $fm = @(
        '---'
        "from: $($Me.Name)"
        "to: $To"
        "title: $($Title -replace '[\r\n]+',' ')"
        "project: $proj"
        "cwd: $Cwd"
        "cliSessionId: $CliSessionId"
        ('createdAt: {0}' -f $ts.ToUniversalTime().ToString('o'))
        '---'
        ''
    ) -join "`n"
    Write-SwFileAtomic $file ($fm + $Body.Trim() + "`n")
    Write-SwLog "handoff by $($Me.Name) for $proj -> $file"
    $file
}

function Get-SwHandoffs([string]$ProjectKey, [int]$Days = 14) {
    $dir = Join-Path (Get-SwHome) ("handoffs/" + (Get-SwProjectSlug $ProjectKey))
    Get-ChildItem $dir -Filter '*.md' -File -ErrorAction SilentlyContinue |
        Where-Object LastWriteTime -gt (Get-Date).AddDays(-$Days) | Sort-Object Name -Descending | ForEach-Object {
            $from = if ($_.BaseName -match '-([^-]+)$') { $Matches[1] } else { '?' }
            [pscustomobject]@{ File = $_.FullName; From = $from; Time = $_.LastWriteTime; Text = (Get-Content $_.FullName -Raw) }
        }
}
