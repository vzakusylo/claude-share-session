# Per-account status files (each account writes only its own).
# Part of ShareWork.psm1 (dot-sourced into the module scope).


function Get-SwIndexByCliSession($Account, [string]$CliSessionId) {
    if (-not $Account.Dir -or -not $CliSessionId) { return $null }
    $hit = Get-ChildItem $Account.Dir -Recurse -Filter 'local_*.json' -File |
        Select-String -SimpleMatch -Pattern "`"$CliSessionId`"" -List | Select-Object -First 1
    if ($hit) { Read-SwIndex $hit.Path } else { $null }
}

function Update-SwStatus {
    param([Parameter(Mandatory)] $Me, [Parameter(Mandatory)] [string] $CliSessionId, [string] $Cwd)
    $p = Join-Path (Get-SwHome) ("status/{0}.json" -f $Me.Name)
    $st = if (Test-Path $p) { Get-Content $p -Raw | ConvertFrom-Json -AsHashtable } else { $null }
    if (-not $st) { $st = @{ account = $Me.Name; accountUuid = $Me.Uuid; sessions = @() } }
    $idx = Get-SwIndexByCliSession $Me $CliSessionId
    if (-not $Cwd -and $idx) { $Cwd = $idx['cwd'] }
    $summary = $null; $wrap = $null
    if ($idx) {
        if ($idx['postTurnSummary']) { $summary = $idx['postTurnSummary']['status_detail'] }
        if ($idx['turnWrapUp']) { $wrap = $idx['turnWrapUp']['description'] }
    }
    $entry = [ordered]@{
        cliSessionId = $CliSessionId
        sessionId    = if ($idx) { $idx['sessionId'] } else { $null }
        title        = if ($idx -and $idx['title']) { $idx['title'] } else { '(terminal session)' }
        cwd          = $Cwd
        project      = Get-SwProjectKey $Cwd
        branch       = if ($idx) { $idx['branch'] } else { $null }
        at           = (Get-Date).ToUniversalTime().ToString('o')
        summary      = $summary
        wrapUp       = $wrap
    }
    $list = @($entry) + @($st['sessions'] | Where-Object { $_ -and $_['cliSessionId'] -ne $CliSessionId })
    $st['sessions'] = @($list | Select-Object -First 40)
    $st['updatedAt'] = $entry.at
    $st['account'] = $Me.Name; $st['accountUuid'] = $Me.Uuid
    Write-SwFileAtomic $p ($st | ConvertTo-Json -Depth 6)
}

function Get-SwStatuses {
    Get-ChildItem (Join-Path (Get-SwHome) 'status') -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
        try { Get-Content $_.FullName -Raw | ConvertFrom-Json -AsHashtable } catch { }
    }
}
