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

# ---------- CLI ----------------------------------------------------------------------------------
$o = & $pwsh -NoProfile -File (Join-Path $repo 'share-work.ps1') status 2>&1 | Out-String
Check 'cli: status runs' ($LASTEXITCODE -eq 0 -and $o -match 'alice' -and $o -match 'bob')
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
