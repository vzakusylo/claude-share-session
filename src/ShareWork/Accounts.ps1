# Accounts on this machine, the current account, auto-registration.
# Part of ShareWork.psm1 (dot-sourced into the module scope).


function Get-SwAccounts {
    <# All accounts that have a desktop session index on this machine. #>
    $root = Get-SwSessionsRoot
    $cfg = Get-SwConfig
    foreach ($a in Get-ChildItem $root -Directory -ErrorAction SilentlyContinue) {
        if ($a.Name -notmatch '^[0-9a-f-]{36}$') { continue }
        $orgs = @(Get-ChildItem $a.FullName -Directory | ForEach-Object {
                [pscustomobject]@{ Dir = $_.FullName; Org = $_.Name; Count = @(Get-ChildItem $_.FullName -Filter 'local_*.json' -File).Count }
            })
        $known = if ($cfg.ContainsKey('orgs') -and $cfg.orgs.ContainsKey($a.Name)) { $cfg.orgs[$a.Name] } else { $null }
        $primary = if ($known) { $orgs | Where-Object Org -eq $known | Select-Object -First 1 } else { $null }
        if (-not $primary) { $primary = $orgs | Where-Object Count -gt 0 | Sort-Object Count -Descending | Select-Object -First 1 }
        # a brand-new account with no sessions yet: unknown org -> not a sync target until it registers itself
        $name = if ($cfg.names.ContainsKey($a.Name)) { $cfg.names[$a.Name] } else { $a.Name.Substring(0, 8) }
        [pscustomobject]@{
            Uuid       = $a.Name
            Name       = $name
            Dir        = $a.FullName
            PrimaryOrg = if ($primary) { $primary.Org } else { $null }
            PrimaryDir = if ($primary) { $primary.Dir } else { $null }
            Sessions   = [int](($orgs | Measure-Object Count -Sum).Sum)
        }
    }
}

function Register-SwCurrentAccount {
    <# Inside a desktop session: remember this account's org and give it a name (from config.emails or the e-mail). #>
    $uuid = $env:CLAUDE_CODE_ACCOUNT_UUID; $org = $env:CLAUDE_CODE_ORGANIZATION_UUID; $mail = $env:CLAUDE_CODE_USER_EMAIL
    if (-not $uuid -or -not $org) { return }
    $cfg = Get-SwConfig
    if (-not $cfg.ContainsKey('orgs')) { $cfg['orgs'] = @{} }
    if (-not $cfg.ContainsKey('emails')) { $cfg['emails'] = @{} }
    $changed = $false
    if ($cfg.orgs[$uuid] -ne $org) { $cfg.orgs[$uuid] = $org; $changed = $true }
    if (-not $cfg.names.ContainsKey($uuid) -and $mail) {
        $cfg.names[$uuid] = if ($cfg.emails.ContainsKey($mail)) { $cfg.emails[$mail] } else { ($mail -split '@')[0] }
        $changed = $true
    }
    if ($changed) { Save-SwConfig $cfg; Write-SwLog "registered account $uuid ($mail) as '$($cfg.names[$uuid])', org $org" }
}

function Get-SwCurrentAccount {
    <# Account of the running Claude Code process: desktop env var, else CLI login, else most recently active. #>
    $accts = @(Get-SwAccounts)
    $uuid = $env:CLAUDE_CODE_ACCOUNT_UUID
    if (-not $uuid) {
        try {
            $cjPath = if ($env:SHAREWORK_CLAUDE_JSON) { $env:SHAREWORK_CLAUDE_JSON } else { Join-Path $HOME '.claude.json' }
            $cj = Get-Content $cjPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable
            if ($cj['oauthAccount']) { $uuid = $cj['oauthAccount']['accountUuid'] }
        } catch { }
    }
    $hit = $accts | Where-Object Uuid -eq $uuid | Select-Object -First 1
    if ($hit) { return $hit }
    if ($uuid) {
        $cfg = Get-SwConfig
        $n = if ($cfg.names.ContainsKey($uuid)) { $cfg.names[$uuid] } else { $uuid.Substring(0, 8) }
        return [pscustomobject]@{ Uuid = $uuid; Name = $n; Dir = $null; PrimaryOrg = $null; PrimaryDir = $null; Sessions = 0 }
    }
    # fallback: whoever wrote an index file last
    $accts | Sort-Object {
        $last = Get-ChildItem $_.Dir -Recurse -Filter 'local_*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($last) { $last.LastWriteTimeUtc } else { [datetime]::MinValue }   # account without sessions sorts last
    } -Descending | Select-Object -First 1
}
