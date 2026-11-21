# Plan usage per account: snapshots of the 5-hour and weekly windows, token spending from transcripts,
# a linear forecast and a "switch to another account" recommendation.
# Model borrowed from claude-swap (realiti4/claude-swap): windows five_hour / seven_day with utilization % and
# resets_at, a switch line (default 90%), the binding window is the one closest to its line, the "best" target
# is the account with the most headroom under every line, a reset that has passed means the window is empty.
# Part of ShareWork.psm1 (dot-sourced into the module scope).

function Get-SwUsageDir {
    $d = Join-Path (Get-SwHome) 'usage'
    if (-not (Test-Path $d)) { New-Item -ItemType Directory $d -Force | Out-Null }
    $d
}

function Get-SwUsageSettings {
    $c = Get-SwConfig
    [pscustomobject]@{
        Threshold       = if ($c['usageThreshold']) { [double]$c['usageThreshold'] } else { 90 }
        WeeklyThreshold = if ($c['usageWeeklyThreshold']) { [double]$c['usageWeeklyThreshold'] } elseif ($c['usageThreshold']) { [double]$c['usageThreshold'] } else { 90 }
        WarnMinutes     = if ($c['usageWarnMinutes']) { [double]$c['usageWarnMinutes'] } else { 30 }
        StaleMinutes    = if ($c['usageStaleMinutes']) { [double]$c['usageStaleMinutes'] } else { 60 }
    }
}

# ---- parsing the Usage page ("Settings > Usage" in the app, or claude.ai/settings/usage) ------------

function ConvertFrom-SwResetText([string]$Text, [datetime]$Now) {
    <# "Resets at 8:10 PM", "Resets Tue 11:00 PM", "Resets in 2 hr 5 min", "Resets Nov 25, 3:00 PM" -> local DateTime #>
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $t = ($Text -replace '^\s*Resets\s*', '').Trim()
    if ($t -match '^in\s+(?:(\d+)\s*(?:d|day|days))?\s*(?:(\d+)\s*(?:h|hr|hrs|hour|hours))?\s*(?:(\d+)\s*(?:m|min|mins|minutes?))?$') {
        return $Now.AddDays([int]('0' + $Matches[1])).AddHours([int]('0' + $Matches[2])).AddMinutes([int]('0' + $Matches[3]))
    }
    $t = $t -replace '^at\s+', ''
    $timeFormats = 'h:mm tt', 'h tt', 'H:mm', 'h:mmtt', 'htt'
    if ($t -match '^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\w*\s+(.+)$') {
        $dow = [array]::IndexOf(@('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'), $Matches[1])
        $tm = [datetime]::ParseExact($Matches[2].Trim(), [string[]]$timeFormats, $inv, 'AllowWhiteSpaces')
        $d = $Now.Date.AddDays((($dow - [int]$Now.DayOfWeek) + 7) % 7).Add($tm.TimeOfDay)
        if ($d -le $Now) { $d = $d.AddDays(7) }
        return $d
    }
    try {
        $tm = [datetime]::ParseExact($t, [string[]]$timeFormats, $inv, 'AllowWhiteSpaces')
        $d = $Now.Date.Add($tm.TimeOfDay); if ($d -le $Now) { $d = $d.AddDays(1) }
        return $d
    } catch { }
    try {
        $d = [datetime]::ParseExact($t, [string[]]@('MMM d, h:mm tt', 'MMM d h:mm tt', 'MMM d, yyyy h:mm tt'), $inv, 'AllowWhiteSpaces')
        if ($d.Year -lt $Now.Year) { $d = $d.AddYears($Now.Year - $d.Year) }
        if ($d -lt $Now.AddDays(-1)) { $d = $d.AddYears(1) }
        return $d
    } catch { }
    $null
}

function ConvertFrom-SwUsageText {
    <#
      Parses text copied from the Usage page, e.g.
        5-hour limit / Resets at 8:10 PM / 23% / Weekly · all models / Resets Tue 11:00 PM / 75%
      Returns @{ fiveHour = @{ pct; resetsAt }; sevenDay = @{ pct; resetsAt } } (missing windows left out).
    #>
    param([Parameter(Mandatory)] [string] $Text, [datetime] $Now = (Get-Date))
    $out = @{}
    $cur = $null
    foreach ($line in ($Text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if ($line -match '(?i)^(5|five)[- ]?h(ou)?r') { $cur = 'fiveHour'; $out[$cur] = @{}; continue }
        if ($line -match '(?i)^weekly|^7[- ]?day') {
            # only the "all models" weekly window is the plan-wide one; per-model weekly lines are ignored
            $cur = if ($line -match '(?i)all models' -or $line -match '(?i)^weekly\s*$' -or -not $out.ContainsKey('sevenDay')) { 'sevenDay' } else { $null }
            if ($cur) { $out[$cur] = @{} }
            continue
        }
        if (-not $cur) { continue }
        if ($line -match '(?i)^resets') { $r = ConvertFrom-SwResetText $line $Now; if ($r) { $out[$cur]['resetsAt'] = $r.ToUniversalTime().ToString('o') }; continue }
        if ($line -match '^(\d+(?:[.,]\d+)?)\s*%') { $out[$cur]['pct'] = [double]($Matches[1] -replace ',', '.'); continue }
    }
    foreach ($k in @($out.Keys)) { if (-not $out[$k].ContainsKey('pct')) { $out.Remove($k) } }
    $out
}

# ---- snapshots ---------------------------------------------------------------------------------

function Get-SwUsageFile($Account) { Join-Path (Get-SwUsageDir) ("{0}.json" -f $Account.Uuid) }

function Get-SwUsageSnapshots($Account) {
    $j = Read-SwJsonFile (Get-SwUsageFile $Account)
    if ($j -and $j['snapshots']) { @($j['snapshots']) } else { @() }
}

function Add-SwUsageSnapshot {
    <# Records a measurement for an account (written only for that account's file). #>
    param([Parameter(Mandatory)] $Account, [Parameter(Mandatory)] [hashtable] $Usage, [string] $Source = 'manual', [datetime] $Now = (Get-Date))
    $snap = [ordered]@{ at = $Now.ToUniversalTime().ToString('o'); source = $Source }
    foreach ($w in 'fiveHour', 'sevenDay') { if ($Usage[$w]) { $snap[$w] = $Usage[$w] } }
    $all = @(Get-SwUsageSnapshots $Account) + @($snap)
    if ($all.Count -gt 300) { $all = $all[-300..-1] }
    Write-SwFileAtomic (Get-SwUsageFile $Account) (@{ account = $Account.Name; uuid = $Account.Uuid; snapshots = $all } | ConvertTo-Json -Depth 6)
    Write-SwLog ("usage {0}: 5h {1}% weekly {2}% ({3})" -f $Account.Name, $(if ($Usage['fiveHour']) { $Usage['fiveHour']['pct'] } else { '-' }), $(if ($Usage['sevenDay']) { $Usage['sevenDay']['pct'] } else { '-' }), $Source)
    $snap
}

# ---- token spending from transcripts -----------------------------------------------------------

function Get-SwWeightedTokens([hashtable]$U) {
    <# One number per message, roughly proportional to what the plan counts: cache reads are cheap. #>
    if (-not $U) { return 0 }
    [double]$U['input_tokens'] + [double]$U['output_tokens'] + [double]$U['cache_creation_input_tokens'] + 0.1 * [double]$U['cache_read_input_tokens']
}

function Add-SwTokenUsage {
    <#
      Adds the tokens of a session's transcript written since the last call to the account that ran the turn.
      Called after every turn (after-turn), so each message is counted once, for the account that spent it.
    #>
    param([Parameter(Mandatory)] $Account, [Parameter(Mandatory)] [string] $CliSessionId, [string] $TranscriptPath)
    if (-not $TranscriptPath) {
        $TranscriptPath = Get-ChildItem (Join-Path $HOME '.claude/projects') -Recurse -Filter "$CliSessionId.jsonl" -File -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $TranscriptPath -or -not (Test-Path -LiteralPath $TranscriptPath)) { return $null }
    $curPath = Join-Path (Get-SwUsageDir) 'cursors.json'
    $cur = Read-SwJsonFile $curPath; if (-not $cur) { $cur = @{} }
    $since = if ($cur[$CliSessionId]) { [datetimeoffset]::Parse($cur[$CliSessionId], [Globalization.CultureInfo]::InvariantCulture) } else { [datetimeoffset]::MinValue }
    $sum = [ordered]@{ input = 0.0; output = 0.0; cacheRead = 0.0; cacheCreate = 0.0; weighted = 0.0; messages = 0 }
    $last = $since; $seen = @{}
    foreach ($line in [IO.File]::ReadLines($TranscriptPath)) {
        if ($line -notmatch '"output_tokens"') { continue }
        try { $j = $line | ConvertFrom-Json -AsHashtable -DateKind String } catch { continue }
        $u = if ($j['message']) { $j['message']['usage'] } else { $null }
        if (-not $u -or -not $j['timestamp']) { continue }
        $ts = [datetimeoffset]::Parse([string]$j['timestamp'], [Globalization.CultureInfo]::InvariantCulture)
        if ($ts -le $since) { continue }
        # one API response can be written as several lines (one per content block): count it once
        $rid = [string]$j['requestId']; if ($rid) { if ($seen.ContainsKey($rid)) { continue }; $seen[$rid] = $true }
        $sum.input += [double]$u['input_tokens']; $sum.output += [double]$u['output_tokens']
        $sum.cacheRead += [double]$u['cache_read_input_tokens']; $sum.cacheCreate += [double]$u['cache_creation_input_tokens']
        $sum.weighted += Get-SwWeightedTokens $u; $sum.messages++
        if ($ts -gt $last) { $last = $ts }
    }
    if ($sum.messages -eq 0) { return $null }
    $cur[$CliSessionId] = $last.ToString('o')
    Write-SwFileAtomic $curPath ($cur | ConvertTo-Json)
    $row = [ordered]@{ at = $last.UtcDateTime.ToString('o'); session = $CliSessionId } + $sum
    Add-Content -Path (Join-Path (Get-SwUsageDir) ("tokens-{0}.jsonl" -f $Account.Uuid)) -Value ($row | ConvertTo-Json -Compress) -Encoding utf8
    Write-SwDebug ("tokens {0}: +{1:N0} weighted ({2} message(s)) in {3}" -f $Account.Name, $sum.weighted, $sum.messages, $CliSessionId)
    $row
}

function Get-SwTokenRows($Account, [datetime]$SinceUtc) {
    $p = Join-Path (Get-SwUsageDir) ("tokens-{0}.jsonl" -f $Account.Uuid)
    if (-not (Test-Path $p)) { return @() }
    @(Get-Content $p | ForEach-Object { try { $_ | ConvertFrom-Json -AsHashtable -DateKind String } catch { } } |
        Where-Object { $_ -and ([datetime]::Parse($_['at'], [Globalization.CultureInfo]::InvariantCulture, 'AdjustToUniversal,AssumeUniversal')) -gt $SinceUtc })
}

function Get-SwTokensBetween($Account, [datetime]$FromUtc, [datetime]$ToUtc) {
    $s = 0.0
    foreach ($r in Get-SwTokenRows $Account $FromUtc) {
        $t = [datetime]::Parse($r['at'], [Globalization.CultureInfo]::InvariantCulture, 'AdjustToUniversal,AssumeUniversal')
        if ($t -le $ToUtc) { $s += [double]$r['weighted'] }
    }
    $s
}

# ---- forecast ----------------------------------------------------------------------------------

function Get-SwWindowForecast {
    <#
      Estimates one window (fiveHour = 5 h long, sevenDay = 7 days long) for an account right now.
      pct now      = last measured pct + tokens spent since then x pct-per-token (learned from earlier snapshots
                     in the same window), or the measured pct when no token data exists; 0 after the reset.
      rate (%/h)   = from two snapshots of the same window, else from recent token burn, else average since
                     the window started.
    #>
    param($Account, [ValidateSet('fiveHour', 'sevenDay')] [string] $Window, [datetime] $NowUtc = (Get-Date).ToUniversalTime(), [double] $Line = 90)
    $len = if ($Window -eq 'fiveHour') { [timespan]::FromHours(5) } else { [timespan]::FromDays(7) }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $snaps = @(Get-SwUsageSnapshots $Account | Where-Object { $_[$Window] -and $null -ne $_[$Window]['pct'] })
    if (-not $snaps) { return [pscustomobject]@{ Window = $Window; Known = $false; Pct = $null; ResetsAt = $null; RatePerHour = $null; EtaLine = $null; EtaFull = $null; WillLast = $null; AgeMinutes = $null; Basis = 'no data' } }
    $last = $snaps[-1]
    $at = [datetime]::Parse($last['at'], $inv, 'AdjustToUniversal,AssumeUniversal')
    $reset = if ($last[$Window]['resetsAt']) { [datetime]::Parse($last[$Window]['resetsAt'], $inv, 'AdjustToUniversal,AssumeUniversal') } else { $null }
    $age = ($NowUtc - $at).TotalMinutes
    if ($reset -and $reset -le $NowUtc) {
        # the window has reset since the measurement: empty again, next reset unknown
        return [pscustomobject]@{ Window = $Window; Known = $true; Pct = 0.0; ResetsAt = $null; RatePerHour = $null; EtaLine = $null; EtaFull = $null; WillLast = $true; AgeMinutes = $age; Basis = 'reset passed' }
    }
    $pct = [double]$last[$Window]['pct']
    $sameWindow = @($snaps | Where-Object { -not $reset -or -not $_[$Window]['resetsAt'] -or [math]::Abs(([datetime]::Parse($_[$Window]['resetsAt'], $inv, 'AdjustToUniversal,AssumeUniversal') - $reset).TotalMinutes) -lt 20 })
    # pct per weighted token, learned from consecutive snapshots in this window that have token data between them
    $ppt = $null; $dp = 0.0; $dt = 0.0
    for ($i = 1; $i -lt $sameWindow.Count; $i++) {
        $a0 = [datetime]::Parse($sameWindow[$i - 1]['at'], $inv, 'AdjustToUniversal,AssumeUniversal'); $a1 = [datetime]::Parse($sameWindow[$i]['at'], $inv, 'AdjustToUniversal,AssumeUniversal')
        $d = [double]$sameWindow[$i][$Window]['pct'] - [double]$sameWindow[$i - 1][$Window]['pct']
        $tk = Get-SwTokensBetween $Account $a0 $a1
        if ($d -gt 0 -and $tk -gt 0) { $dp += $d; $dt += $tk }
    }
    if ($dt -gt 0) { $ppt = $dp / $dt }
    $basis = 'measured'
    $since = Get-SwTokensBetween $Account $at $NowUtc
    if ($ppt -and $since -gt 0) { $pct = [math]::Min(100, $pct + $since * $ppt); $basis = 'measured + tokens since' }
    # rate
    $rate = $null
    $recentFrom = $NowUtc.AddMinutes(-60)
    $recent = Get-SwTokensBetween $Account $recentFrom $NowUtc
    if ($ppt -and $recent -gt 0) { $rate = $recent * $ppt; $basis += ', rate from last hour of tokens' }
    elseif ($sameWindow.Count -ge 2) {
        $f = $sameWindow[0]; $fa = [datetime]::Parse($f['at'], $inv, 'AdjustToUniversal,AssumeUniversal')
        $h = ($at - $fa).TotalHours
        if ($h -gt 0.05) { $rate = [math]::Max(0, ($pct - [double]$f[$Window]['pct'])) / [math]::Max($h, ($NowUtc - $fa).TotalHours); $basis += ', rate from snapshots' }
    }
    if ($null -eq $rate -and $reset) {
        $elapsed = ($len - ($reset - $at)).TotalHours
        if ($elapsed -gt 0.1) { $rate = $pct / $elapsed; $basis += ', average rate since window start' }
    }
    $etaLine = $null; $etaFull = $null; $willLast = $null
    if ($rate -and $rate -gt 0) {
        if ($pct -lt $Line) { $etaLine = $NowUtc.AddHours(($Line - $pct) / $rate) } else { $etaLine = $NowUtc }
        $etaFull = $NowUtc.AddHours((100 - $pct) / $rate)
        if ($reset) { $willLast = $etaFull -ge $reset }
    } elseif ($null -ne $rate) { $willLast = $true }
    [pscustomobject]@{ Window = $Window; Known = $true; Pct = [math]::Round($pct, 1); ResetsAt = $reset; RatePerHour = $(if ($null -ne $rate) { [math]::Round($rate, 2) }); EtaLine = $etaLine; EtaFull = $etaFull; WillLast = $willLast; AgeMinutes = [math]::Round($age); Basis = $basis }
}

function Get-SwUsageForecast {
    param($Account, [datetime] $NowUtc = (Get-Date).ToUniversalTime())
    $s = Get-SwUsageSettings
    $f5 = Get-SwWindowForecast $Account 'fiveHour' $NowUtc $s.Threshold
    $f7 = Get-SwWindowForecast $Account 'sevenDay' $NowUtc $s.WeeklyThreshold
    $known = $f5.Known -or $f7.Known
    # headroom under each line; the binding window is the one closest to its line (claude-swap)
    $h5 = if ($f5.Known) { $s.Threshold - $f5.Pct } else { $null }
    $h7 = if ($f7.Known) { $s.WeeklyThreshold - $f7.Pct } else { $null }
    $hs = @($h5, $h7 | Where-Object { $null -ne $_ })
    $headroom = if ($hs) { ($hs | Measure-Object -Minimum).Minimum } else { $null }
    $binding = if ($null -eq $h5) { $f7 } elseif ($null -eq $h7) { $f5 } elseif ($h5 -le $h7) { $f5 } else { $f7 }
    $age = @($f5.AgeMinutes, $f7.AgeMinutes | Where-Object { $null -ne $_ } | Measure-Object -Minimum)
    [pscustomobject]@{
        Account = $Account; Known = $known; FiveHour = $f5; SevenDay = $f7; Headroom = $headroom; Binding = $binding
        OverLine = ($known -and $null -ne $headroom -and $headroom -le 0)
        Stale = (-not $known) -or ($age.Count -and $age.Minimum -gt $s.StaleMinutes)
    }
}

function Get-SwSwitchRecommendation {
    <#
      Should the account in use switch, and to which account?
        * switch now   : the binding window is at/over its line;
        * switch soon  : the forecast reaches the line within WarnMinutes, before the window resets;
        * target       : "best" strategy — the other account with the most headroom under every line;
                         accounts with no data are listed last as "unknown"; if every account is over its lines,
                         the one whose binding window resets first.
    #>
    param([Parameter(Mandatory)] $Me, [object[]] $Accounts = @(Get-SwAccounts), [datetime] $NowUtc = (Get-Date).ToUniversalTime())
    $s = Get-SwUsageSettings
    $mine = Get-SwUsageForecast $Me $NowUtc
    $level = 'ok'; $why = $null
    if ($mine.Known) {
        foreach ($f in $mine.FiveHour, $mine.SevenDay) {
            if (-not $f.Known) { continue }
            $line = if ($f.Window -eq 'fiveHour') { $s.Threshold } else { $s.WeeklyThreshold }
            $name = if ($f.Window -eq 'fiveHour') { '5-hour' } else { 'weekly' }
            if ($f.Pct -ge $line) { $level = 'now'; $why = "$name limit at $($f.Pct)% (line $line%)"; break }
            if ($f.EtaLine -and ($f.EtaLine - $NowUtc).TotalMinutes -le $s.WarnMinutes -and (-not $f.ResetsAt -or $f.EtaLine -lt $f.ResetsAt)) {
                $level = 'soon'; $why = "$name limit predicted to reach $line% at $($f.EtaLine.ToLocalTime().ToString('HH:mm')) (now $($f.Pct)%, $($f.RatePerHour)%/h)"
            }
        }
    }
    $others = @(foreach ($a in $Accounts) { if ($a.Uuid -ne $Me.Uuid) { Get-SwUsageForecast $a $NowUtc } })
    $ok = @($others | Where-Object { $_.Known -and -not $_.OverLine } | Sort-Object @{ e = { $_.Headroom }; Descending = $true })
    $target = $ok | Select-Object -First 1
    $targetWhy = $null
    if ($target) { $targetWhy = "$([math]::Round($target.Headroom))% headroom" + $(if ($target.Stale) { ' (measurement is old)' } else { '' }) }
    else {
        $unknown = @($others | Where-Object { -not $_.Known }) | Select-Object -First 1
        if ($unknown) { $target = $unknown; $targetWhy = 'usage unknown — paste its Usage page after switching' }
        else {
            $target = $others | Sort-Object { $r = $_.Binding.ResetsAt; if ($r) { $r } else { [datetime]::MaxValue } } | Select-Object -First 1
            if ($target -and $target.Binding.ResetsAt) { $targetWhy = "all accounts over their lines; resets first, at $($target.Binding.ResetsAt.ToLocalTime().ToString('ddd HH:mm'))" }
        }
    }
    [pscustomobject]@{ Level = $level; Reason = $why; Me = $mine; Target = $(if ($target) { $target.Account }); TargetReason = $targetWhy; Others = $others }
}

function Format-SwUsageBar([double]$Pct, [int]$Width = 20) {
    $n = [math]::Max(0, [math]::Min($Width, [math]::Round($Pct / 100 * $Width)))
    '[' + ('#' * $n) + ('.' * ($Width - $n)) + ']'
}

function Format-SwResetIn($ResetUtc, [datetime]$NowUtc) {
    if (-not $ResetUtc) { return '' }
    $ResetUtc = [datetime]$ResetUtc
    $d = $ResetUtc - $NowUtc
    $when = if ($d.TotalDays -ge 1) { '{0}d {1}h' -f [int][math]::Floor($d.TotalDays), $d.Hours } elseif ($d.TotalHours -ge 1) { '{0}h {1}m' -f [int][math]::Floor($d.TotalHours), $d.Minutes } else { '{0}m' -f [int][math]::Max(0, $d.TotalMinutes) }
    "resets in $when ($($ResetUtc.ToLocalTime().ToString('ddd HH:mm')))"
}

function Get-SwSwitchMessage {
    <# One short line for hooks, or $null when nothing needs saying. #>
    param([Parameter(Mandatory)] $Me, [object[]] $Accounts = @(Get-SwAccounts), [datetime] $NowUtc = (Get-Date).ToUniversalTime())
    $r = Get-SwSwitchRecommendation -Me $Me -Accounts $Accounts -NowUtc $NowUtc
    if ($r.Level -eq 'ok') { return $null }
    $verb = if ($r.Level -eq 'now') { 'Switch accounts now' } else { 'Switch accounts soon' }
    $to = if ($r.Target) { " -> $($r.Target.Name) ($($r.TargetReason))" } else { '' }
    "Claude usage ($($Me.Name)): $($r.Reason). $verb$to. Type /handoff first, then switch in the app."
}

function Get-SwSwitchNotice {
    <# Get-SwSwitchMessage, but at most once per QuietMinutes for the same account and level (hooks run every turn). #>
    param([Parameter(Mandatory)] $Me, [object[]] $Accounts = @(Get-SwAccounts), [datetime] $NowUtc = (Get-Date).ToUniversalTime(), [int] $QuietMinutes = 20)
    $msg = Get-SwSwitchMessage -Me $Me -Accounts $Accounts -NowUtc $NowUtc
    if (-not $msg) { return $null }
    $p = Join-Path (Get-SwUsageDir) 'notified.json'
    $st = Read-SwJsonFile $p; if (-not $st) { $st = @{} }
    $key = $Me.Uuid + '|' + $(if ($msg -match 'now') { 'now' } else { 'soon' })
    if ($st[$key] -and ($NowUtc - [datetime]::Parse($st[$key], [Globalization.CultureInfo]::InvariantCulture, 'AdjustToUniversal,AssumeUniversal')).TotalMinutes -lt $QuietMinutes) { return $null }
    $st[$key] = $NowUtc.ToString('o'); Write-SwFileAtomic $p ($st | ConvertTo-Json)
    Write-SwLog "usage notice: $msg"
    $msg
}

# ---- fetch like claude-swap (only for the account logged in to the Claude Code CLI) --------------

function Get-SwUsageFromApi {
    <#
      GET https://api.anthropic.com/api/oauth/usage with the CLI login's OAuth token (as claude-swap does).
      The token is read from ~/.claude/.credentials.json, sent only to api.anthropic.com, never logged or stored.
      Desktop-app accounts keep their login inside the app, so only the CLI account can be measured this way.
    #>
    param([string] $CredentialsPath = (Join-Path $HOME '.claude/.credentials.json'))
    $c = Read-SwJsonFile $CredentialsPath
    $o = if ($c) { $c['claudeAiOauth'] } else { $null }
    if (-not $o -or -not $o['accessToken']) { throw 'No Claude Code CLI login found (~/.claude/.credentials.json). Run `claude` and /login, or paste the Usage page instead.' }
    if ($o['expiresAt'] -and [double]$o['expiresAt'] -lt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) { throw 'The CLI login token has expired; run `claude` once to refresh it.' }
    $r = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Method Get -TimeoutSec 5 -Headers @{
        Authorization = "Bearer $($o['accessToken'])"; 'anthropic-beta' = 'oauth-2025-04-20'; 'User-Agent' = 'claude-share-session/1.0' }
    ConvertFrom-SwApiUsage $r
}

function ConvertFrom-SwApiUsage($Response) {
    $j = if ($Response -is [string]) { $Response | ConvertFrom-Json -AsHashtable -DateKind String } else { $Response | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable -DateKind String }
    $out = @{}
    foreach ($pair in @(@('five_hour', 'fiveHour'), @('seven_day', 'sevenDay'))) {
        $w = $j[$pair[0]]
        if ($w -and $null -ne $w['utilization']) {
            $out[$pair[1]] = @{ pct = [double]$w['utilization'] }
            if ($w['resets_at']) { $out[$pair[1]]['resetsAt'] = ([datetimeoffset]::Parse([string]$w['resets_at'], [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime.ToString('o') }
        }
    }
    $out
}
