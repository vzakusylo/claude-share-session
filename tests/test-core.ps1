#requires -Version 7.2
<#
  Core tests on a fully SYNTHETIC fixture: no real Claude data is read or written, so this runs on any
  Windows/macOS/Linux machine with PowerShell 7 (also in CI).
  usage: pwsh -NoProfile -File tests/test-core.ps1 [-Work <empty temp dir>]
#>
param([string] $Work = (Join-Path ([IO.Path]::GetTempPath()) ('sharework-core-' + [guid]::NewGuid().ToString('N').Substring(0, 8))))
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $Work | Out-Null
$sessions = Join-Path $Work 'sessions'
$env:SHAREWORK_SESSIONS_ROOT = $sessions
$env:SHAREWORK_HOME = Join-Path $Work 'home'
$env:SHAREWORK_CLAUDE_JSON = Join-Path $Work 'no-cli-login.json'   # behave like a machine without a CLI login (CI)
foreach ($v in 'CLAUDE_CODE_ACCOUNT_UUID', 'CLAUDE_CODE_ORGANIZATION_UUID', 'CLAUDE_CODE_USER_EMAIL', 'SHAREWORK_NO_PUSH') { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
Import-Module (Join-Path $repo 'src/ShareWork.psm1') -Force

$fail = 0; $pass = 0
function Check([string]$name, [bool]$ok) { if ($ok) { $script:pass++; "PASS  $name" } else { $script:fail++; "FAIL  $name" } }

# ---------- fixture ------------------------------------------------------------------------------
$A = '11111111-1111-4111-8111-111111111111'; $OA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
$B = '22222222-2222-4222-8222-222222222222'; $OB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
$C = '33333333-3333-4333-8333-333333333333'; $OC = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
foreach ($p in "$A/$OA", "$A/$OB", "$B/$OB", "$B/$OA", "$C/$OC") { New-Item -ItemType Directory (Join-Path $sessions $p) -Force | Out-Null }
$repoDir = Join-Path $Work 'repo'
function New-Index([string]$acct, [string]$org, [string]$id, [hashtable]$extra = @{}, [datetime]$mtime = (Get-Date).AddMinutes(-30)) {
    $j = [ordered]@{
        sessionId = "local_$id"; cliSessionId = "cli-$id"; cwd = $repoDir; title = "Session $id"; model = 'm'
        createdAt = 1793017543205; lastActivityAt = 1793024555913; isArchived = $false
        remoteMcpServersConfig = @(@{ name = "connector-of-$acct" }); bridgeSessionIds = @('b1'); chromeTabGroupId = 7
        scheduledTaskId = $null; indexedAtIso = '2026-11-08T21:35:48.124Z'
    }
    foreach ($k in $extra.Keys) { $j[$k] = $extra[$k] }
    $p = Join-Path $sessions "$acct/$org/local_$id.json"
    [IO.File]::WriteAllText($p, ($j | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    (Get-Item $p).LastWriteTimeUtc = $mtime.ToUniversalTime()
    $p
}
New-Index $A $OA 's1' @{ title = 'Ünïcødé ✓ título — привет'; scheduledTaskId = 'daily' } | Out-Null
New-Index $A $OA 's2' @{ isArchived = $true } | Out-Null
New-Index $A $OA 's3' @{ cwd = (Join-Path $Work 'secret/client') } | Out-Null
New-Index $B $OB 's9' | Out-Null
$cfg = Get-SwConfig; $cfg.names[$A] = 'alice'; $cfg.names[$B] = 'bob'; $cfg.excludeCwd = @((Join-Path $Work 'secret') + '*'); Save-SwConfig $cfg

# ---------- accounts ------------------------------------------------------------------------------
$all = @(Get-SwAccounts); $alice = $all | Where-Object Uuid -eq $A; $bob = $all | Where-Object Uuid -eq $B; $carol = $all | Where-Object Uuid -eq $C
Check 'accounts: three found' ($all.Count -eq 3)
Check 'accounts: names from config, uuid prefix otherwise' ($alice.Name -eq 'alice' -and $bob.Name -eq 'bob' -and $carol.Name -eq '33333333')
Check 'accounts: primary org = org with sessions' ($alice.PrimaryOrg -eq $OA -and $bob.PrimaryOrg -eq $OB)
Check 'accounts: brand-new account is not a target' (-not $carol.PrimaryDir)
$cfg = Get-SwConfig; $cfg['orgs'] = @{ $C = $OC }; Save-SwConfig $cfg
$carol = @(Get-SwAccounts) | Where-Object Uuid -eq $C
Check 'accounts: known org makes a new account a target' ($carol.PrimaryOrg -eq $OC)
$cfg = Get-SwConfig; $cfg.orgs.Remove($C); Save-SwConfig $cfg
$all = @(Get-SwAccounts); $alice = $all | Where-Object Uuid -eq $A; $bob = $all | Where-Object Uuid -eq $B

# ---------- session mirroring ---------------------------------------------------------------------
$dry = @(Sync-SwSessions -From $alice -To @($bob) -DryRun)
Check 'dry run: reports 1 create (archived and excluded skipped)' ($dry.Count -eq 1 -and $dry[0].Action -eq 'create')
Check 'dry run: writes nothing' (-not (Test-Path (Join-Path $sessions "$B/$OB/local_s1.json")))
$rows = @(Sync-SwSessions -From $alice -To @($bob))
$copyPath = Join-Path $sessions "$B/$OB/local_s1.json"
$copy = Read-SwIndex $copyPath
Check 'create: copy written into target primary org' (Test-Path $copyPath)
Check 'create: account-bound fields dropped' (@($copy['remoteMcpServersConfig']).Count -eq 0 -and -not $copy.ContainsKey('bridgeSessionIds') -and -not $copy.ContainsKey('chromeTabGroupId'))
Check 'create: scheduledTaskId kept' ($copy['scheduledTaskId'] -eq 'daily')
Check 'create: unicode title preserved' ($copy['title'] -eq 'Ünïcødé ✓ título — привет')
Check 'create: ISO date string not rewritten' ($copy['indexedAtIso'] -eq '2026-11-08T21:35:48.124Z')
Check 'create: large integers preserved' ($copy['createdAt'] -eq 1793017543205)
Check 'create: source mtime preserved' ([Math]::Abs(((Get-Item $copyPath).LastWriteTimeUtc - (Get-Item (Join-Path $sessions "$A/$OA/local_s1.json")).LastWriteTimeUtc).TotalSeconds) -lt 1)
Check 'create: archived session not imported' (-not (Test-Path (Join-Path $sessions "$B/$OB/local_s2.json")))
Check 'create: excluded folder not mirrored' (-not (Test-Path (Join-Path $sessions "$B/$OB/local_s3.json")))
Check 'create: no temp files left' (@(Get-ChildItem $sessions -Recurse -Force -Filter '.sw-tmp-*').Count -eq 0)
Check 'idempotent: second run changes nothing' (@(Sync-SwSessions -From $alice -To @($bob)).Count -eq 0)

# bob continues the session: newer copy flows back, alice keeps her connectors
$j = Read-SwIndex $copyPath; $j['completedTurns'] = 5; $j['remoteMcpServersConfig'] = @(@{ name = 'connector-of-bob' })
[IO.File]::WriteAllText($copyPath, ($j | ConvertTo-Json -Depth 10)); (Get-Item $copyPath).LastWriteTimeUtc = (Get-Date).ToUniversalTime()
$rows = @(Sync-SwSessions -From $bob -To @($alice))
$back = Read-SwIndex (Join-Path $sessions "$A/$OA/local_s1.json")
Check 'update: newer copy flows back' (@($rows | Where-Object { $_.Action -eq 'update' -and $_.CliSessionId -eq 'cli-s1' }).Count -eq 1 -and $back['completedTurns'] -eq 5)
Check "create: bob's own session reaches alice" (@($rows | Where-Object { $_.Action -eq 'create' -and $_.CliSessionId -eq 'cli-s9' }).Count -eq 1)
Check 'update: target keeps its own account-bound fields' ($back['remoteMcpServersConfig'][0]['name'] -eq "connector-of-$A" -and $back.ContainsKey('bridgeSessionIds'))
Check 'update: backup written before overwrite' (@(Get-ChildItem (Join-Path $env:SHAREWORK_HOME 'backups') -Recurse -Filter '*local_s1.json').Count -ge 1)

# older source never overwrites newer target
$sp = Join-Path $sessions "$A/$OA/local_s1.json"; $j = Read-SwIndex $sp; $j['title'] = 'stale'
[IO.File]::WriteAllText($sp, ($j | ConvertTo-Json -Depth 10)); (Get-Item $sp).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-5)
Check 'update: older source does not overwrite newer target' (@(Sync-SwSessions -From $alice -To @($bob)).Count -eq 0 -and (Read-SwIndex $copyPath)['title'] -ne 'stale')

# pins (isStarred): the account syncing now (the last one used) decides, even if the other file is newer
$pa = New-Index $A $OA 'p1' @{ isStarred = $true } ((Get-Date).AddHours(-3))
$pb = New-Index $B $OB 'p1' @{ isStarred = $false; completedTurns = 9 } ((Get-Date).AddHours(-1))
$pbTime = (Get-Item $pb).LastWriteTimeUtc
$dry = @(Sync-SwSessions -From $alice -To @($bob) -OnlyCliSessionId 'cli-p1' -DryRun)
Check 'pin: dry run reports pin, writes nothing' ($dry.Count -eq 1 -and $dry[0].Action -eq 'pin' -and -not (Read-SwIndex $pb)['isStarred'])
$rows = @(Sync-SwSessions -From $alice -To @($bob) -OnlyCliSessionId 'cli-p1')
$pj = Read-SwIndex $pb
Check 'pin: pinned in last account -> pinned in other (newer) account' ($rows.Count -eq 1 -and $rows[0].Action -eq 'pin' -and $pj['isStarred'] -eq $true)
Check 'pin: only isStarred changed, other fields kept' ($pj['completedTurns'] -eq 9 -and $pj['remoteMcpServersConfig'][0]['name'] -eq "connector-of-$B")
Check 'pin: target mtime kept' ([Math]::Abs(((Get-Item $pb).LastWriteTimeUtc - $pbTime).TotalSeconds) -lt 1)
Check 'pin: idempotent' (@(Sync-SwSessions -From $alice -To @($bob) -OnlyCliSessionId 'cli-p1').Count -eq 0)
# bob is now the last account and unpins: alice follows
$j = Read-SwIndex $pb; $j['isStarred'] = $false; [IO.File]::WriteAllText($pb, ($j | ConvertTo-Json -Depth 10)); (Get-Item $pb).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-4)
$rows = @(Sync-SwSessions -From $bob -To @($alice) -OnlyCliSessionId 'cli-p1')
Check 'pin: unpin in last account -> unpinned in other account' ($rows.Count -eq 1 -and (Read-SwIndex $pa)['isStarred'] -eq $false)
# source without isStarred never touches the target pin
$j = Read-SwIndex $pa; $j.Remove('isStarred'); [IO.File]::WriteAllText($pa, ($j | ConvertTo-Json -Depth 10)); (Get-Item $pa).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-6)
$j = Read-SwIndex $pb; $j['isStarred'] = $true; [IO.File]::WriteAllText($pb, ($j | ConvertTo-Json -Depth 10))
Check 'pin: source without isStarred leaves target pin alone' (@(Sync-SwSessions -From $alice -To @($bob) -OnlyCliSessionId 'cli-p1').Count -eq 0 -and (Read-SwIndex $pb)['isStarred'] -eq $true)
Remove-Item $pa, $pb

# importArchived + only-one-session filter
$cfg = Get-SwConfig; $cfg.importArchived = $true; Save-SwConfig $cfg
$rows = @(Sync-SwSessions -From $alice -To @($bob) -OnlyCliSessionId 'cli-s2')
Check 'importArchived: archived session imported on request' ($rows.Count -eq 1 -and (Test-Path (Join-Path $sessions "$B/$OB/local_s2.json")))
$cfg = Get-SwConfig; $cfg.importArchived = $false; Save-SwConfig $cfg

# corrupt index files are skipped, not fatal
[IO.File]::WriteAllText((Join-Path $sessions "$A/$OA/local_broken.json"), '{ not json')
$ok = $true; try { Sync-SwSessions -From $alice -To @($bob) | Out-Null } catch { $ok = $false }
Check 'robust: corrupt index file is skipped' $ok
Remove-Item (Join-Path $sessions "$A/$OA/local_broken.json")

# ---------- project identity -----------------------------------------------------------------------
$sep = [IO.Path]::DirectorySeparatorChar
$k1 = Get-SwProjectKey (Join-Path $Work 'proj')
$k2 = Get-SwProjectKey ((Join-Path $Work 'proj') + "$sep.claude${sep}worktrees${sep}feature-x${sep}src")
Check 'project: worktree maps to main repo (no git)' ($k1 -eq $k2)
Check 'project: trailing separator ignored' ((Get-SwProjectKey ((Join-Path $Work 'proj') + $sep)) -eq $k1)
Check 'project: case-insensitive' ((Get-SwProjectKey (Join-Path $Work 'PROJ')) -eq $k1)
if (Get-Command git -ErrorAction SilentlyContinue) {
    $g = Join-Path $Work 'gitrepo'; New-Item -ItemType Directory (Join-Path $g 'sub') -Force | Out-Null
    git -C $g init -q 2>$null
    Check 'project: subfolder of a git repo maps to repo root' ((Get-SwProjectKey (Join-Path $g 'sub')) -eq (Get-SwProjectKey $g))
}
Check 'project: slug is filesystem-safe' ((Get-SwProjectSlug 'c:\work\my repo') -eq 'c-work-my-repo')

# ---------- status, handoff, briefing --------------------------------------------------------------
$env:CLAUDE_CODE_ACCOUNT_UUID = $A
$me = Get-SwCurrentAccount
Check 'current account from env' ($me.Uuid -eq $A)
Update-SwStatus -Me $me -CliSessionId 'cli-s1' -Cwd $repoDir
1..45 | ForEach-Object { Update-SwStatus -Me $me -CliSessionId "cli-x$_" -Cwd $repoDir }
Update-SwStatus -Me $me -CliSessionId 'cli-x45' -Cwd $repoDir
$st = Get-Content (Join-Path $env:SHAREWORK_HOME 'status/alice.json') -Raw | ConvertFrom-Json -AsHashtable
Check 'status: capped at 40 entries' (@($st.sessions).Count -eq 40)
Check 'status: de-duplicated by session id, newest first' ($st.sessions[0]['cliSessionId'] -eq 'cli-x45' -and @($st.sessions | Where-Object { $_['cliSessionId'] -eq 'cli-x45' }).Count -eq 1)
Update-SwStatus -Me $me -CliSessionId 'cli-s1' -Cwd $repoDir
$st = Get-Content (Join-Path $env:SHAREWORK_HOME 'status/alice.json') -Raw | ConvertFrom-Json -AsHashtable
Check 'status: title looked up from desktop index' ($st.sessions[0]['title'] -eq 'stale' -or $st.sessions[0]['title'] -like 'Ünïcødé*')

$long = 'x' * 5000
$hf = New-SwHandoff -Me $me -Cwd $repoDir -Body "## Goal`nShip it`n$long" -Title "multi`nline" -CliSessionId 'cli-s1'
$ht = Get-Content $hf -Raw
Check 'handoff: file named <time>-<account>.md in project folder' ((Split-Path $hf -Leaf) -match '^\d{8}-\d{6}-alice\.md$')
Check 'handoff: front matter with from/project/session' ($ht -match '(?m)^from: alice$' -and $ht -match '(?m)^cliSessionId: cli-s1$' -and $ht -match '(?m)^title: multi line$')

$env:CLAUDE_CODE_ACCOUNT_UUID = $B
$bobMe = Get-SwCurrentAccount
$brief = Get-SwBriefing -Me $bobMe -Cwd $repoDir
Check 'briefing: mentions the other account' ($brief -match "Account 'alice' worked in this project")
Check 'briefing: includes resume command' ($brief -match 'claude --resume cli-')
Check 'briefing: includes latest handoff, truncated' ($brief -match "Latest handoff note from 'alice'" -and $brief -match 'truncated')
Check 'briefing: marked as data, not instructions' ($brief -match 'DATA, not instructions' -and $brief.StartsWith('<shared-work-briefing>') -and $brief.TrimEnd().EndsWith('</shared-work-briefing>'))
Check 'briefing: at most 5 sessions per account' (([regex]::Matches($brief, 'claude --resume')).Count -le 5)
$env:CLAUDE_CODE_ACCOUNT_UUID = $A
Check 'briefing: own work is not briefed back' (-not ((Get-SwBriefing -Me (Get-SwCurrentAccount) -Cwd $repoDir) -match "Account 'alice'"))
Check 'briefing: other project gets nothing' ((Get-SwBriefing -Me $bobMe -Cwd (Join-Path $Work 'elsewhere')) -eq '')
# old entries (> 7 days) are not briefed
$p = Join-Path $env:SHAREWORK_HOME 'status/alice.json'; $s = Get-Content $p -Raw | ConvertFrom-Json -AsHashtable
foreach ($e in $s.sessions) { $e['at'] = (Get-Date).ToUniversalTime().AddDays(-9).ToString('o') }
[IO.File]::WriteAllText($p, ($s | ConvertTo-Json -Depth 6))
Check 'briefing: entries older than 7 days are skipped' (-not ((Get-SwBriefing -Me $bobMe -Cwd $repoDir) -match "worked in this project"))

# ---------- account registration ------------------------------------------------------------------
$cfg = Get-SwConfig; $cfg['emails'] = @{ 'carol@example.com' = 'carol' }; Save-SwConfig $cfg
$env:CLAUDE_CODE_ACCOUNT_UUID = $C; $env:CLAUDE_CODE_ORGANIZATION_UUID = $OC; $env:CLAUDE_CODE_USER_EMAIL = 'carol@example.com'
Register-SwCurrentAccount
$carol = @(Get-SwAccounts) | Where-Object Uuid -eq $C
Check 'register: new account named from e-mail map' ($carol.Name -eq 'carol')
Check 'register: org recorded -> becomes a sync target' ($carol.PrimaryOrg -eq $OC -and $carol.PrimaryDir)
$env:CLAUDE_CODE_USER_EMAIL = 'dave.smith@example.com'; $cfg = Get-SwConfig; $cfg.names.Remove($C); Save-SwConfig $cfg
Register-SwCurrentAccount
Check 'register: falls back to e-mail local part' ((Get-SwConfig).names[$C] -eq 'dave.smith')
Register-SwCurrentAccount
Check 'register: does not rename an already named account' ((Get-SwConfig).names[$C] -eq 'dave.smith')
foreach ($v in 'CLAUDE_CODE_ACCOUNT_UUID', 'CLAUDE_CODE_ORGANIZATION_UUID', 'CLAUDE_CODE_USER_EMAIL') { Remove-Item "env:$v" -ErrorAction SilentlyContinue }

# ---------- lock ----------------------------------------------------------------------------------
Check 'lock: body runs and returns its output' ((Invoke-SwWithLock { 42 }) -eq 42)

# ---------- hooks (run as real processes, like Claude Code does) ----------------------------------
$pwsh = (Get-Process -Id $PID).Path
$h = Join-Path $repo 'hooks'
$out = 'not json{' | & $pwsh -NoProfile -File (Join-Path $h 'session-start.ps1'); $code = $LASTEXITCODE
Check 'hook session-start: bad input -> exit 0, no output' ($code -eq 0 -and -not $out)
$env:CLAUDE_CODE_ACCOUNT_UUID = $B
Update-SwStatus -Me ([pscustomobject]@{ Uuid = $A; Name = 'alice'; Dir = (Join-Path $sessions $A) }) -CliSessionId 'cli-s1' -Cwd $repoDir
$out = (@{ cwd = $repoDir; hook_event_name = 'SessionStart' } | ConvertTo-Json) | & $pwsh -NoProfile -File (Join-Path $h 'session-start.ps1')
$parsed = $null; try { $parsed = $out | ConvertFrom-Json } catch { }
Check 'hook session-start: valid JSON with additionalContext' ($LASTEXITCODE -eq 0 -and $parsed.hookSpecificOutput.hookEventName -eq 'SessionStart' -and $parsed.hookSpecificOutput.additionalContext -match 'alice')
$sw = [Diagnostics.Stopwatch]::StartNew()
'{}' | & $pwsh -NoProfile -File (Join-Path $h 'turn-end.ps1'); $code = $LASTEXITCODE
Check 'hook turn-end: no session id -> exit 0' ($code -eq 0)
$env:SHAREWORK_NO_PUSH = '1'
(@{ session_id = 'cli-hook-test'; cwd = $repoDir } | ConvertTo-Json) | & $pwsh -NoProfile -File (Join-Path $h 'turn-end.ps1'); $code = $LASTEXITCODE
Check 'hook turn-end: returns quickly (< 5 s)' ($code -eq 0 -and $sw.Elapsed.TotalSeconds -lt 5)
$deadline = (Get-Date).AddSeconds(30); $seen = $false
while ((Get-Date) -lt $deadline -and -not $seen) {
    Start-Sleep -Milliseconds 500
    $f = Join-Path $env:SHAREWORK_HOME 'status/bob.json'
    if (Test-Path $f) { $seen = (Get-Content $f -Raw) -match 'cli-hook-test' }
}
Check 'hook turn-end: background step records status' $seen
Remove-Item env:SHAREWORK_NO_PUSH, env:CLAUDE_CODE_ACCOUNT_UUID -ErrorAction SilentlyContinue

# ---------- installer -----------------------------------------------------------------------------
$cd = Join-Path $Work 'claude-home'; New-Item -ItemType Directory (Join-Path $cd 'skills') -Force | Out-Null
$userHook = @{ hooks = @(@{ type = 'command'; command = 'echo'; args = @('mine') }) }
@{ model = 'x'; env = @{ FOO = '1' }; hooks = @{ Stop = @($userHook) } } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $cd 'settings.json')
New-Item -ItemType Directory (Join-Path $cd 'skills/handoff-foreign') -Force | Out-Null
& $pwsh -NoProfile -File (Join-Path $repo 'install.ps1') -ClaudeDir $cd | Out-Null
& $pwsh -NoProfile -File (Join-Path $repo 'install.ps1') -ClaudeDir $cd | Out-Null
$s = Get-Content (Join-Path $cd 'settings.json') -Raw | ConvertFrom-Json -AsHashtable
Check 'installer: three hook events, no duplicates after 2 runs' (@($s.hooks.SessionStart).Count -eq 1 -and @($s.hooks.SessionEnd).Count -eq 1 -and @($s.hooks.Stop).Count -eq 2)
Check 'installer: user hooks and settings kept' (($s.hooks.Stop | ConvertTo-Json -Depth 10) -match 'mine' -and $s.model -eq 'x' -and $s.env.FOO -eq '1')
Check 'installer: hooks call pwsh directly with args' ($s.hooks.SessionStart[0].hooks[0].args -contains '-File' -and $s.hooks.SessionStart[0].hooks[0].command -like '*pwsh*')
$sk = Get-Content (Join-Path $cd 'skills/handoff/SKILL.md') -Raw
Check 'installer: skills installed with real path' ($sk -notmatch '\{\{SHAREWORK_DIR\}\}' -and $sk.Contains((Join-Path $repo 'share-work.ps1')))
Check 'installer: settings backup made' (@(Get-ChildItem $cd -Filter 'settings.json.bak-sharework-*').Count -ge 1)
& $pwsh -NoProfile -File (Join-Path $repo 'install.ps1') -ClaudeDir $cd -Uninstall | Out-Null
$s = Get-Content (Join-Path $cd 'settings.json') -Raw | ConvertFrom-Json -AsHashtable
Check 'uninstall: only our hooks removed' (@($s.hooks.Stop).Count -eq 1 -and -not $s.hooks.ContainsKey('SessionStart') -and ($s.hooks.Stop | ConvertTo-Json -Depth 10) -match 'mine')
Check 'uninstall: our skills removed, foreign skill folders kept' (-not (Test-Path (Join-Path $cd 'skills/handoff')) -and (Test-Path (Join-Path $cd 'skills/handoff-foreign')))

# ---------- environment sync ------------------------------------------------------------------------
$pol = [pscustomobject]@{ Enabled = $true; ActiveUuid = $null; AllowDeletesFrom = $null; Note = $null }
$polB = [pscustomobject]@{ Enabled = $true; ActiveUuid = $B; AllowDeletesFrom = $B; Note = $null }
$all = @(Get-SwAccounts); $alice = $all | Where-Object Uuid -eq $A; $bob = $all | Where-Object Uuid -eq $B
foreach ($n in 'd1', 'd2', 'd3', 'd4') { New-Index $A $OA $n | Out-Null }
Sync-SwSessions -From $alice -To @($bob) | Out-Null
$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
function New-Tomb([string]$acct, [string]$org, [string]$id, [long]$ms) { [IO.File]::WriteAllText((Join-Path $sessions "$acct/$org/deleted_$id"), "$ms") }
New-Tomb $A $OA 'd1' $nowMs; New-Tomb $A $OA 'cli-d2' $nowMs; New-Tomb $A $OA 'bad' 0; [IO.File]::WriteAllText((Join-Path $sessions "$A/$OA/deleted_junk"), 'not a number')
$d3 = Join-Path $sessions "$B/$OB/local_d3.json"
# bob really worked in d3 after alice deleted it: real activity (lastActivityAt) is newer than the deletion
$j = Read-SwIndex $d3; $j['lastActivityAt'] = $nowMs; [IO.File]::WriteAllText($d3, ($j | ConvertTo-Json -Depth 10))
New-Tomb $A $OA 'd3' ($nowMs - 600000)
New-Tomb $A $OA 'd4' $nowMs

$dry = @(Sync-SwTombstones -From $alice -To @($bob) -DryRun -Policy $pol)
Check 'tombstone: dry run reports, writes nothing' ($dry.Count -gt 0 -and (Test-Path (Join-Path $sessions "$B/$OB/local_d1.json")) -and -not (Test-Path (Join-Path $sessions "$B/$OB/deleted_d1")))
$rows = @(Sync-SwTombstones -From $alice -To @($bob) -Policy $polB)
Check 'tombstone: open account is not written' ($rows.Count -eq 0 -and (Test-Path (Join-Path $sessions "$B/$OB/local_d1.json")))
$rows = @(Sync-SwTombstones -From $alice -To @($bob) -Policy $pol)
Check 'tombstone: copied to the other account' ((Test-Path (Join-Path $sessions "$B/$OB/deleted_d1")) -and (Test-Path (Join-Path $sessions "$B/$OB/deleted_cli-d2")))
Check 'tombstone: session moved to backups, not deleted' (-not (Test-Path (Join-Path $sessions "$B/$OB/local_d1.json")) -and -not (Test-Path (Join-Path $sessions "$B/$OB/local_d2.json")) -and @(Get-ChildItem (Join-Path $env:SHAREWORK_HOME 'backups') -Recurse -Filter '*local_d1.json').Count -ge 1)
Check 'tombstone: matched by cliSessionId too' (@($rows | Where-Object Action -eq 'session-removed').Count -eq 3 -or @($rows | Where-Object Action -eq 'session-removed').Count -ge 2)
Check 'tombstone: newer activity in target keeps its session' ((Test-Path $d3) -and -not (Test-Path (Join-Path $sessions "$B/$OB/deleted_d3")))
Check 'tombstone: corrupt tombstones skipped' (-not (Test-Path (Join-Path $sessions "$B/$OB/deleted_junk")))
Check 'tombstone: idempotent second run' (@(Sync-SwTombstones -From $alice -To @($bob) -Policy $pol).Count -eq 0)
Remove-Item (Join-Path $sessions "$A/$OA/local_d1.json"), (Join-Path $sessions "$A/$OA/local_d2.json") -ErrorAction SilentlyContinue
New-Index $A $OA 'd1' | Out-Null
$rows = @(Sync-SwSessions -From $alice -To @($bob))
Check 'sessions: tombstoned session is not recreated' (-not (Test-Path (Join-Path $sessions "$B/$OB/local_d1.json")) -and @($rows | Where-Object CliSessionId -in 'cli-d1', 'cli-d2').Count -eq 0)
Check 'sessions: idempotent after tombstones' (@(Sync-SwSessions -From $alice -To @($bob)).Count -eq 0)

# ---------- deletion bugs (regression) ------------------------------------------------------------
# Bug 1: an account already has the tombstone, but an older sync brought the session file back.
foreach ($n in 'r1', 'r2') { New-Index $B $OB $n | Out-Null }          # alive in bob, old activity
New-Tomb $B $OB 'r1' $nowMs; New-Tomb $B $OB 'cli-r2' $nowMs            # ...and bob's own tombstones
$rows = @(Sync-SwTombstones -From $alice -To @($bob) -Policy $pol)
Check 'bug1: resurrected session removed when target already has the tombstone' (-not (Test-Path (Join-Path $sessions "$B/$OB/local_r1.json")) -and -not (Test-Path (Join-Path $sessions "$B/$OB/local_r2.json")))
Check 'bug1: removal reported, no duplicate tombstone written' (@($rows | Where-Object Action -eq 'session-removed').Count -eq 2 -and @($rows | Where-Object { $_.Action -eq 'tombstone' -and $_.Title -in 'r1', 'cli-r2' }).Count -eq 0)

# Bug 2: the app rewrote the file (new mtime) but nobody worked in the session after the deletion.
$p = New-Index $B $OB 'm1'                                             # activity = old fixed fixture time
New-Tomb $A $OA 'm1' ($nowMs - 3600000)                               # deleted an hour ago
(Get-Item $p).LastWriteTimeUtc = (Get-Date).ToUniversalTime()        # file touched just now
$rows = @(Sync-SwTombstones -From $alice -To @($bob) -Policy $pol)
Check 'bug2: file mtime newer than deletion does not keep the session' (-not (Test-Path $p) -and (Test-Path (Join-Path $sessions "$B/$OB/deleted_m1")))

# a deleted session alive in the source account is not pushed anywhere (source has its own tombstone)
New-Index $A $OA 'z1' | Out-Null; New-Tomb $A $OA 'z1' $nowMs
$rows = @(Sync-SwSessions -From $alice -To @($bob))
Check 'sessions: session tombstoned in the source is not pushed' (-not (Test-Path (Join-Path $sessions "$B/$OB/local_z1.json")) -and @($rows | Where-Object CliSessionId -eq 'cli-z1').Count -eq 0)

# a deleted session is not updated in a target that still has it either
New-Index $B $OB 'u1' | Out-Null; $up = New-Index $A $OA 'u1' @{ title = 'changed' } ((Get-Date).AddMinutes(5))
New-Tomb $A $OA 'u1' $nowMs
$rows = @(Sync-SwSessions -From $alice -To @($bob))
Check 'sessions: tombstoned session is not updated in the target' (@($rows | Where-Object CliSessionId -eq 'cli-u1').Count -eq 0)

# deleted in one account -> gone in ALL others (three accounts, two of them targets)
$C2 = '44444444-4444-4444-8444-444444444444'; $OC2 = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
New-Item -ItemType Directory (Join-Path $sessions "$C2/$OC2") -Force | Out-Null
New-Index $C2 $OC2 'seed' | Out-Null
foreach ($acct in @(@($A, $OA), @($B, $OB), @($C2, $OC2))) { New-Index $acct[0] $acct[1] 'all1' | Out-Null }
$three = @(Get-SwAccounts | Where-Object { $_.Uuid -in $A, $B, $C2 })
$alice3 = $three | Where-Object Uuid -eq $A
Remove-Item (Join-Path $sessions "$A/$OA/local_all1.json"); New-Tomb $A $OA 'all1' $nowMs    # user deletes it in alice
$rows = @(Sync-SwAll -From $alice3 -To $three -Policy $pol)
Check 'all accounts: deletion in one account removes the session in every other account' (-not (Test-Path (Join-Path $sessions "$B/$OB/local_all1.json")) -and -not (Test-Path (Join-Path $sessions "$C2/$OC2/local_all1.json")))
Check 'all accounts: every other account gets the tombstone' ((Test-Path (Join-Path $sessions "$B/$OB/deleted_all1")) -and (Test-Path (Join-Path $sessions "$C2/$OC2/deleted_all1")))
$rows = @(foreach ($acc3 in $three) { Sync-SwAll -From $acc3 -To $three -Policy $pol })   # not $a: PowerShell names ignore case ($A)
Check 'all accounts: full two-way sync does not bring it back' (-not @(Get-ChildItem $sessions -Recurse -Filter 'local_all1.json').Count)
$polA = [pscustomobject]@{ Enabled = $true; ActiveUuid = $A; AllowDeletesFrom = $A; Note = $null }
New-Index $A $OA 'act1' | Out-Null; New-Index $B $OB 'act1' | Out-Null; New-Tomb $B $OB 'act1' $nowMs
$rows = @(Sync-SwTombstones -From $bob -To @($alice3) -Policy $polA)
Check 'all accounts: account open in the app is never cleaned while open' ((Test-Path (Join-Path $sessions "$A/$OA/local_act1.json")) -and $rows.Count -eq 0)
Remove-Item (Join-Path $sessions $C2) -Recurse -Force

# presets
$pf = Join-Path $Work 'ccd-session-presets.json'
function Save-Presets($d) { [IO.File]::WriteAllText($pf, ($d | ConvertTo-Json -Depth 10)) }
function Load-Presets { Get-Content $pf -Raw | ConvertFrom-Json -AsHashtable -DateKind String }
Save-Presets @{ builtIns = @(@{ id = 'builtin1'; name = 'Built' }); seededFromDraft = $true
    byAccount = @{ $A = @{ presets = @(@{ id = 'p1'; name = 'one'; createdAt = 1793000000000 }) }; $B = @{ presets = @() } } }
$before = Load-Presets
$dry = @(Sync-SwPresets -From $alice -To @($bob) -DryRun -Policy $pol)
Check 'presets: dry run writes nothing' ($dry.Count -eq 1 -and @((Load-Presets).byAccount[$B].presets).Count -eq 0)
Check 'presets: open account is not written' (@(Sync-SwPresets -From $alice -To @($bob) -Policy $polB).Count -eq 0 -and @((Load-Presets).byAccount[$B].presets).Count -eq 0)
$rows = @(Sync-SwPresets -From $alice -To @($bob) -Policy $pol)
$d = Load-Presets
Check 'presets: created in A appears in B' ($rows[0].Action -eq 'preset-create' -and $d.byAccount[$B].presets[0].id -eq 'p1' -and $d.byAccount[$B].presets[0].name -eq 'one')
Check 'presets: builtIns and seededFromDraft untouched' ((($d.builtIns | ConvertTo-Json -Compress) -eq ($before.builtIns | ConvertTo-Json -Compress)) -and $d.seededFromDraft -eq $true)
Check 'presets: idempotent' (@(Sync-SwPresets -From $alice -To @($bob) -Policy $pol).Count -eq 0)
$d.byAccount[$B].presets[0].name = 'edited'; $d.byAccount[$B].presets[0].lastUsedAt = 1793100000000; Save-Presets $d
$rows = @(Sync-SwPresets -From $bob -To @($alice) -Policy $pol)
Check 'presets: later edit in B flows back to A' ($rows[0].Action -eq 'preset-update' -and (Load-Presets).byAccount[$A].presets[0].name -eq 'edited')
Check 'presets: older source does not overwrite' (@(Sync-SwPresets -From $alice -To @($bob) -Policy $pol).Count -eq 0)
[IO.File]::WriteAllText($pf, '{ broken')
Check 'presets: corrupt file skipped, untouched' (@(Sync-SwPresets -From $alice -To @($bob) -Policy $pol).Count -eq 0 -and (Get-Content $pf -Raw) -eq '{ broken')

# archive index (line format)
[IO.File]::WriteAllText((Join-Path $sessions "$A/$OA/archived-sessions.idx"), "s1`ns2`n"); [IO.File]::WriteAllText((Join-Path $sessions "$B/$OB/archived-sessions.idx"), "s2`n")
$rows = @(Sync-SwArchiveIndex -From $alice -To @($bob) -Policy $pol)
Check 'archive index: union written' ($rows.Count -eq 1 -and ((Get-Content (Join-Path $sessions "$B/$OB/archived-sessions.idx")) -join ',') -eq 's2,s1')
Check 'archive index: idempotent' (@(Sync-SwArchiveIndex -From $alice -To @($bob) -Policy $pol).Count -eq 0)

# plugins (report only)
foreach ($p in "$A/$OA", "$B/$OB") { New-Item -ItemType Directory (Join-Path $Work "plugin-list/$p") -Force | Out-Null }
[IO.File]::WriteAllText((Join-Path $Work "plugin-list/$A/$OA/plugins.json"), (@{ plugins = @(@{ id = 'pl-shared' }, @{ id = 'pl-only-a' }) } | ConvertTo-Json -Depth 5))
[IO.File]::WriteAllText((Join-Path $Work "plugin-list/$B/$OB/plugins.json"), (@{ plugins = @(@{ id = 'pl-shared' }) } | ConvertTo-Json -Depth 5))
$rows = @(Sync-SwPlugins -From $alice -To @($bob))
Check 'plugins: plugin only in A is reported' ($rows.Count -eq 1 -and $rows[0].Action -eq 'plugin-missing' -and $rows[0].Title -eq 'pl-only-a')
Check 'plugins: nothing written' ((Get-Content (Join-Path $Work "plugin-list/$B/$OB/plugins.json") -Raw) -notmatch 'pl-only-a')
$o = & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $repo 'share-work.ps1') status 2>&1 | Out-String
Check 'status: environment section lists missing plugin' ($o -match 'Environment:' -and $o -match "pl-only-a.*alice.*bob")
$cfg = Get-SwConfig; $cfg['environmentExclude'] = @('plugins'); Save-SwConfig $cfg
Check 'config: environmentExclude opts an item out' (@(Sync-SwPlugins -From $alice -To @($bob)).Count -eq 0)
$cfg = Get-SwConfig; $cfg['environmentExclude'] = @(); $cfg['syncEnvironment'] = $false; Save-SwConfig $cfg
Check 'config: syncEnvironment=false disables Sync-SwAll environment part' (@(Sync-SwAll -From $alice -To @($bob) -DryRun -Policy $pol | Where-Object Action -like 'plugin-*').Count -eq 0)
$cfg = Get-SwConfig; $cfg['syncEnvironment'] = $true; Save-SwConfig $cfg

# ---------- CLI ----------------------------------------------------------------------------------
$o = & $pwsh -NoProfile -File (Join-Path $repo 'share-work.ps1') status 2>&1 | Out-String
Check 'cli: status runs' ($LASTEXITCODE -eq 0 -and $o -match 'alice' -and $o -match 'bob')
if ($LASTEXITCODE -ne 0) { "      output: $($o.Trim())" }
Check 'cli: current account guessed without env or CLI login' ($o -match 'Current account: \S+')
$o = & $pwsh -NoProfile -File (Join-Path $repo 'share-work.ps1') sync -DryRun 2>&1 | Out-String
Check 'cli: sync -DryRun runs' ($LASTEXITCODE -eq 0 -and $o -match 'dry run|Nothing to do')
$o = & $pwsh -NoProfile -File (Join-Path $repo 'share-work.ps1') name 2222 bobby 2>&1 | Out-String
Check 'cli: name by uuid prefix' ((Get-SwConfig).names[$B] -eq 'bobby')
$o = & $pwsh -NoProfile -File (Join-Path $repo 'share-work.ps1') handoff -Cwd $repoDir 2>&1 | Out-String
Check 'cli: empty handoff body is rejected' ($LASTEXITCODE -ne 0)

''
"$pass passed, $fail failed"
Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { exit 1 }
