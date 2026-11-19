# Scheduled-task registry mirroring (scheduled-tasks.json) with run-state and delete rules.
# Part of ShareWork.psm1 (dot-sourced into the module scope).

<#
  The desktop app keeps the scheduler registry per account+org:
      claude-code-sessions\<accountUuid>\<orgUuid>\scheduled-tasks.json   { scheduledTasks: [...], recordedSkips: {...}, ... }
  (path built as join(userData, "claude-code-sessions", account, org, "scheduled-tasks.json") in app.asar 4.23118).
  The task prompt itself lives in the shared %USERPROFILE%\.claude\scheduled-tasks\<id>\SKILL.md.
  The app only runs the registry of the signed-in account and holds it in memory, rewriting the file on every change.
  Therefore:
    * we NEVER write the registry of the account that is active in the app (it would be overwritten);
    * a task deleted in account A is removed elsewhere only when A is known for sure to be the active account
      (hook context, CLAUDE_CODE_ACCOUNT_UUID set) — a lost write can never turn into a deletion.
#>

function Get-SwTaskRegistryPath($Account) { Join-Path $Account.PrimaryDir 'scheduled-tasks.json' }



function Get-SwCanonical($v) {
    if ($v -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}; foreach ($k in ($v.Keys | Sort-Object)) { $o[$k] = Get-SwCanonical $v[$k] }; return $o
    }
    if ($v -is [System.Collections.IList]) { return , @($v | ForEach-Object { Get-SwCanonical $_ }) }
    $v
}
function Test-SwSame($a, $b) {
    ((Get-SwCanonical $a) | ConvertTo-Json -Depth 50 -Compress) -eq ((Get-SwCanonical $b) | ConvertTo-Json -Depth 50 -Compress)
}

function Copy-SwObject($Obj) { if ($null -eq $Obj) { return $null }; $Obj | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable -DateKind String }

function ConvertTo-SwInstant($v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    if ($v -is [long] -or $v -is [int] -or $v -is [double]) { return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$v) }
    try { [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture) } catch { $null }
}

function Merge-SwTask($Src, $Dst, [bool]$SrcNewer) {
    $m = if ($SrcNewer -or -not $Dst) { Copy-SwObject $Src } else { Copy-SwObject $Dst }
    if ($Dst) {
        foreach ($k in $script:TaskRunStateKeys) {
            $a = ConvertTo-SwInstant $Src[$k]; $b = ConvertTo-SwInstant $Dst[$k]
            if ($a -and (-not $b -or $a -gt $b)) { $m[$k] = $Src[$k] }
            elseif ($b) { $m[$k] = $Dst[$k] }
        }
    }
    # a one-time task that already fired somewhere must not fire again
    $fire = ConvertTo-SwInstant $m['fireAt']
    if ($fire -and $m['enabled']) {
        $ran = @($m['lastRunAt'], $m['lastScheduledFor']) | ForEach-Object { ConvertTo-SwInstant $_ } | Where-Object { $_ } |
            Sort-Object -Descending | Select-Object -First 1
        if ($ran -and $ran -ge $fire) { $m['enabled'] = $false }
    }
    $m
}

function Get-SwTaskSnapshot([string]$AccountName) {
    $p = Join-Path (Get-SwHome) "sched/$AccountName.json"
    $j = Read-SwJsonFile $p
    if ($j -and $j['ids']) { @($j['ids']) } elseif ($j) { @() } else { $null }
}

function Save-SwTaskSnapshot([string]$AccountName, [string[]]$Ids) {
    $p = Join-Path (Get-SwHome) "sched/$AccountName.json"
    Write-SwFileAtomic $p (@{ ids = @($Ids | Sort-Object -Unique); at = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json)
}

function Sync-SwScheduledTasks {
    <#
      Merge the scheduler registry of -From into every account in -To (by task id).
      -ActiveUuid: account open in the desktop app right now — never written.
      -AllowDeletes: propagate tasks deleted in -From since the last sync (only when -From is surely the active account).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $From,
        [Parameter(Mandatory)] [object[]] $To,
        [string] $ActiveUuid,
        [switch] $AllowDeletes,
        [switch] $DryRun
    )
    $cfg = Get-SwConfig
    $home_ = Get-SwHome
    $rows = [System.Collections.Generic.List[object]]::new()
    if (-not $From.PrimaryDir) { return $rows }
    $srcPath = Get-SwTaskRegistryPath $From
    $src = Read-SwJsonFile $srcPath
    if (-not $src) { return $rows }
    $srcTasks = @($src['scheduledTasks'] | Where-Object { $_ -and $_['id'] })
    $srcIds = @($srcTasks | ForEach-Object { $_['id'] })
    $srcTime = (Get-Item -LiteralPath $srcPath).LastWriteTimeUtc

    $deleted = @()
    if ($AllowDeletes) {
        $prev = Get-SwTaskSnapshot $From.Name
        if ($null -ne $prev) { $deleted = @($prev | Where-Object { $_ -notin $srcIds }) }
    }

    foreach ($dstAcct in $To) {
        if ($dstAcct.Uuid -eq $From.Uuid -or -not $dstAcct.PrimaryDir) { continue }
        if ($ActiveUuid -and $dstAcct.Uuid -eq $ActiveUuid) { continue }
        $dstPath = Get-SwTaskRegistryPath $dstAcct
        $dst = Read-SwJsonFile $dstPath
        $dstExists = [bool]$dst
        if (-not $dst) {
            $dst = [ordered]@{}
            foreach ($k in $src.Keys) { if ($k -ne 'scheduledTasks' -and $k -ne 'recordedSkips') { $dst[$k] = $src[$k] } }
            $dst['scheduledTasks'] = @(); $dst['recordedSkips'] = @{}
        }
        $dstTime = if ($dstExists) { (Get-Item -LiteralPath $dstPath).LastWriteTimeUtc } else { [datetime]::MinValue }
        $srcNewer = $srcTime -ge $dstTime
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($t in @($dst['scheduledTasks'] | Where-Object { $_ })) { $list.Add($t) }
        $changed = $false

        foreach ($id in $deleted) {
            $hit = @($list | Where-Object { $_['id'] -eq $id })
            foreach ($h in $hit) {
                [void]$list.Remove($h); $changed = $true
                $rows.Add([pscustomobject]@{ Action = 'task-delete'; From = $From.Name; To = $dstAcct.Name; Title = $h['displayName']; Cwd = $h['cwd'] })
            }
        }
        foreach ($t in $srcTasks) {
            if (Test-SwExcluded $t $cfg) { continue }
            $i = -1
            for ($j = 0; $j -lt $list.Count; $j++) { if ($list[$j]['id'] -eq $t['id']) { $i = $j; break } }
            if ($i -lt 0) {
                $list.Add((Merge-SwTask $t $null $true)); $changed = $true
                $rows.Add([pscustomobject]@{ Action = 'task-create'; From = $From.Name; To = $dstAcct.Name; Title = $t['displayName']; Cwd = $t['cwd'] })
                continue
            }
            $merged = Merge-SwTask $t $list[$i] $srcNewer
            if (-not (Test-SwSame $merged $list[$i])) {
                $list[$i] = $merged; $changed = $true
                $rows.Add([pscustomobject]@{ Action = 'task-update'; From = $From.Name; To = $dstAcct.Name; Title = $t['displayName']; Cwd = $t['cwd'] })
            }
        }
        # recordedSkips: union by key
        $skips = if ($dst['recordedSkips']) { Copy-SwObject $dst['recordedSkips'] } else { @{} }
        if ($src['recordedSkips']) {
            foreach ($k in $src['recordedSkips'].Keys) {
                if (-not $skips.ContainsKey($k)) { $skips[$k] = $src['recordedSkips'][$k]; $changed = $true }
            }
        }
        if ($DryRun) { continue }
        if (-not $changed) {
            if ($dstExists) { Save-SwTaskSnapshot $dstAcct.Name @($list | ForEach-Object { $_['id'] }) }
            continue
        }
        try {
            if ($dstExists) {
                $bdir = Join-Path $home_ ("backups/{0}/{1:yyyyMMdd}" -f $dstAcct.Name, (Get-Date))
                if (-not (Test-Path $bdir)) { New-Item -ItemType Directory $bdir -Force | Out-Null }
                Copy-Item -LiteralPath $dstPath -Destination (Join-Path $bdir ('{0:HHmmss}-scheduled-tasks.json' -f (Get-Date))) -Force
            }
            $dst['scheduledTasks'] = @($list)
            $dst['recordedSkips'] = $skips
            Write-SwFileAtomic $dstPath ($dst | ConvertTo-Json -Depth 50)
            if ($srcNewer) { (Get-Item -LiteralPath $dstPath).LastWriteTimeUtc = $srcTime }
            Save-SwTaskSnapshot $dstAcct.Name @($list | ForEach-Object { $_['id'] })
            Write-SwLog ("tasks {0}->{1}: {2}" -f $From.Name, $dstAcct.Name, (($rows | Where-Object To -eq $dstAcct.Name | ForEach-Object { "$($_.Action) '$($_.Title)'" }) -join '; '))
        } catch {
            Write-SwLog ("ERROR tasks {0}: {1}" -f $dstPath, $_.Exception.Message)
        }
    }
    if (-not $DryRun -and ($AllowDeletes -or $null -eq (Get-SwTaskSnapshot $From.Name))) { Save-SwTaskSnapshot $From.Name $srcIds }
    $rows
}
