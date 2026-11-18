#requires -Version 7.2
# Scenario test for scheduled-task registry mirroring. Works on a COPY of the real session index.
# usage: pwsh -NoProfile -File tests\test-scheduled.ps1 -Work <empty temp dir>
param([Parameter(Mandatory)] [string] $Work)
$ErrorActionPreference = 'Stop'
$real = Join-Path (Get-ChildItem "$env:LOCALAPPDATA\Claude-Data" -Directory -Filter 'claude_*' | Select-Object -First 1).FullName 'claude-code-sessions'
Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $Work | Out-Null
Copy-Item $real (Join-Path $Work 'sessions') -Recurse
$env:SHAREWORK_SESSIONS_ROOT = Join-Path $Work 'sessions'
$env:SHAREWORK_HOME = Join-Path $Work 'home'
Remove-Item env:CLAUDE_CODE_ACCOUNT_UUID -ErrorAction SilentlyContinue
Import-Module (Join-Path $PSScriptRoot '..\src\ShareWork.psm1') -Force

# the two accounts with the most sessions play "alice" (A) and "bob" (B) in this sandbox
$two = @(Get-SwAccounts | Where-Object PrimaryDir | Sort-Object Sessions -Descending | Select-Object -First 2)
if ($two.Count -lt 2) { throw 'Need at least two signed-in accounts with sessions to run this test.' }
$cfg = Get-SwConfig; $cfg.names[$two[0].Uuid] = 'alice'; $cfg.names[$two[1].Uuid] = 'bob'; Save-SwConfig $cfg
$all = @(Get-SwAccounts); $alice = $all | Where-Object Name -eq 'alice'; $bob = $all | Where-Object Name -eq 'bob'
function Pol($active) { [pscustomobject]@{ Enabled = $true; ActiveUuid = $active.Uuid; AllowDeletesFrom = $active.Uuid; Note = $null } }
function Tasks($acct) { @((Read-SwJsonFile (Get-SwTaskRegistryPath $acct))['scheduledTasks']) }
function Task($acct, $id) { Tasks $acct | Where-Object { $_['id'] -eq $id } }
function Edit-Reg($acct, [scriptblock]$fn) {
    $p = Get-SwTaskRegistryPath $acct; $r = Read-SwJsonFile $p; & $fn $r
    Start-Sleep -Milliseconds 1100   # mtime granularity / "newer" rule
    Write-SwFileAtomic $p ($r | ConvertTo-Json -Depth 50)
}
function TaskRows($rows) { @($rows | Where-Object { $_.Action -like 'task-*' }) }
# start from "bob has no tasks", whatever the real machine state is
$vp = Get-SwTaskRegistryPath $bob
$vr = Read-SwJsonFile $vp
if ($vr) { $vr['scheduledTasks'] = @(); Write-SwFileAtomic $vp ($vr | ConvertTo-Json -Depth 50); (Get-Item $vp).LastWriteTimeUtc = [datetime]'2026-01-01' }
$fail = 0
function Check([string]$name, [bool]$ok) { if ($ok) { "PASS  $name" } else { "FAIL  $name"; $script:fail++ } }

# seed alice with a task of her own (real machines differ)
Edit-Reg $alice { param($x) $x['scheduledTasks'] = @($x['scheduledTasks'] | Where-Object { $_ -and $_['id'] -ne 'seed-task' }) + @(@{ id = 'seed-task'; displayName = 'Seed task'; fireAt = 1794173700000; enabled = $false; cwd = 'C:\work\demo'; filePath = 'C:\Users\me\.claude\scheduled-tasks\seed-task\SKILL.md'; notifySessionId = 'local_seed'; lastRunAt = '2026-11-08T21:35:48.124Z' }) }

# 1. alice active: push creates alice's task in bob
$r = TaskRows (Sync-SwAll -From $alice -To @($bob) -Policy (Pol $alice))
Check '1 create alice task in bob' (($r | Where-Object Action -eq 'task-create').Count -ge 1 -and (Task $bob 'seed-task'))
Check '1 copied task keeps prompt path + notify session' ((Task $bob 'seed-task')['filePath'] -like '*\.claude\scheduled-tasks\seed-task\SKILL.md' -and (Task $bob 'seed-task')['notifySessionId'])

# 2. idempotent
$r = TaskRows (Sync-SwAll -From $alice -To @($bob) -Policy (Pol $alice))
Check '2 second push changes nothing' ($r.Count -eq 0)

# 3. alice creates a recurring task
Edit-Reg $alice { param($x) $x['scheduledTasks'] = @($x['scheduledTasks']) + @(@{ id = 'test-daily'; displayName = 'Daily test'; cronExpression = '0 9 * * *'; enabled = $true; cwd = 'C:\work\demo'; filePath = 'C:\Users\me\.claude\scheduled-tasks\test-daily\SKILL.md'; createdAt = 1 }) }
$r = TaskRows (Sync-SwAll -From $alice -To @($bob) -Policy (Pol $alice))
Check '3 new alice task appears in bob' ((Task $bob 'test-daily')['cronExpression'] -eq '0 9 * * *')

# 4. task runs in alice -> run state reaches bob
Edit-Reg $alice { param($x) ($x['scheduledTasks'] | Where-Object { $_['id'] -eq 'test-daily' })['lastRunAt'] = '2026-11-10T08:00:05.000Z'; ($x['scheduledTasks'] | Where-Object { $_['id'] -eq 'test-daily' })['lastScheduledFor'] = '2026-11-10T08:00:00.000Z' }
$r = TaskRows (Sync-SwAll -From $alice -To @($bob) -Policy (Pol $alice))
Check '4 lastRunAt mirrored (no catch-up double run)' ((Task $bob 'test-daily')['lastScheduledFor'] -eq '2026-11-10T08:00:00.000Z')

# 5. switch to bob: it runs the task next day and renames it -> alice gets both
Edit-Reg $bob { param($x) $t = $x['scheduledTasks'] | Where-Object { $_['id'] -eq 'test-daily' }; $t['lastRunAt'] = '2026-11-11T08:00:04.000Z'; $t['lastScheduledFor'] = '2026-11-11T08:00:00.000Z'; $t['displayName'] = 'Daily test (renamed in bob)' }
$r = TaskRows (Sync-SwAll -From $bob -To @($alice) -Policy (Pol $bob))
$k = Task $alice 'test-daily'
Check '5 bob run + rename reach alice' ($k['displayName'] -eq 'Daily test (renamed in bob)' -and $k['lastScheduledFor'] -eq '2026-11-11T08:00:00.000Z')

# 6. latest run wins even if the other registry is newer: alice (newer file) has OLD run state
Edit-Reg $alice { param($x) $t = $x['scheduledTasks'] | Where-Object { $_['id'] -eq 'test-daily' }; $t['lastScheduledFor'] = '2026-11-10T08:00:00.000Z'; $t['lastRunAt'] = '2026-11-10T08:00:05.000Z'; $t['enabled'] = $false }
$r = TaskRows (Sync-SwAll -From $alice -To @($bob) -Policy (Pol $alice))
$v = Task $bob 'test-daily'
Check '6 newer config wins (enabled=false)' ($v['enabled'] -eq $false)
Check '6 but latest run state is kept' ($v['lastScheduledFor'] -eq '2026-11-11T08:00:00.000Z')

# 7. one-time task that already fired in alice is disabled in bob even if bob copy said enabled
$fire = [DateTimeOffset]::new(2026, 11, 9, 20, 0, 0, [TimeSpan]::Zero).ToUnixTimeMilliseconds()
Edit-Reg $bob { param($x) $x['scheduledTasks'] = @($x['scheduledTasks']) + @(@{ id = 'test-once'; displayName = 'Once'; fireAt = $fire; enabled = $true; cwd = 'C:\work\demo' }) }
Edit-Reg $alice { param($x) $x['scheduledTasks'] = @($x['scheduledTasks']) + @(@{ id = 'test-once'; displayName = 'Once'; fireAt = $fire; enabled = $true; cwd = 'C:\work\demo'; lastRunAt = '2026-11-09T20:00:02.000Z'; lastScheduledFor = '2026-11-09T20:00:00.000Z' }) }
(Get-Item (Get-SwTaskRegistryPath $bob)).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(5)   # bob file looks newer
$r = TaskRows (Sync-SwAll -From $alice -To @($bob) -Policy (Pol $alice))
Check '7 fired one-time task disabled in other account' ((Task $bob 'test-once')['enabled'] -eq $false)

# 8. the active account's registry is never written
$before = (Get-FileHash (Get-SwTaskRegistryPath $alice)).Hash
$r = TaskRows (Sync-SwAll -From $bob -To @($alice) -Policy (Pol $alice))   # alice is active, bob -> alice must be skipped
Check '8 active account registry untouched' ((Get-FileHash (Get-SwTaskRegistryPath $alice)).Hash -eq $before -and $r.Count -eq 0)

# 9. deletion in the active account propagates
$r = TaskRows (Sync-SwAll -From $alice -To @($bob) -Policy (Pol $alice))       # refresh snapshot
Edit-Reg $alice { param($x) $x['scheduledTasks'] = @($x['scheduledTasks'] | Where-Object { $_['id'] -ne 'test-daily' }) }
$r = TaskRows (Sync-SwAll -From $alice -To @($bob) -Policy (Pol $alice))
Check '9 task deleted in alice is deleted in bob' (-not (Task $bob 'test-daily') -and ($r | Where-Object Action -eq 'task-delete'))

# 10. without proof of the active account (terminal) a missing task is NOT treated as deleted
Edit-Reg $alice { param($x) $x['scheduledTasks'] = @($x['scheduledTasks'] | Where-Object { $_['id'] -ne 'test-once' }) }
$termPolicy = [pscustomobject]@{ Enabled = $true; ActiveUuid = $null; AllowDeletesFrom = $null; Note = $null }
$r = TaskRows (Sync-SwAll -From $alice -To @($bob) -Policy $termPolicy)
Check '10 no deletes without active-account proof' ([bool](Task $bob 'test-once'))

# 11. terminal + app running -> tasks skipped entirely
$p = Get-SwTaskWritePolicy
Check '11 policy in terminal with app running disables tasks' ((Test-SwDesktopRunning) -eq (-not $p.Enabled))

# 12. registry files stay valid JSON with the app's top-level flags
$reg = Read-SwJsonFile (Get-SwTaskRegistryPath $bob)
Check '12 registry keeps app flags' ($reg.ContainsKey('sundayAliasBoundaryStamped') -and $reg.ContainsKey('recordedSkips'))
Check '12 no temp files left' (@(Get-ChildItem $env:SHAREWORK_SESSIONS_ROOT -Recurse -Filter '.sw-tmp-*').Count -eq 0)
Check '12 backups written' (@(Get-ChildItem (Join-Path $env:SHAREWORK_HOME 'backups') -Recurse -Filter '*scheduled-tasks.json').Count -gt 0)

''
if ($fail) { "$fail FAILED"; exit 1 } else { 'ALL PASSED' }
