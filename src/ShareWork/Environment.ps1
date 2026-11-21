# Per-account "environment" mirroring: session deletions, archive index, presets, tool toggles, plugin report.
# Part of ShareWork.psm1 (dot-sourced into the module scope).

<#
  Same rules as sessions and scheduled tasks: merge by key, newest wins, nothing deleted silently (removed
  sessions are moved to backups), atomic writes, never write the account that is open in the app.
  Paths are relative to the desktop data folder (parent of the sessions root):
      claude-code-sessions\<account>\<org>\deleted_<id>              tombstone, content = deletion time (epoch ms)
      claude-code-sessions\<account>\<org>\archived-sessions.idx     archive index
      ccd-session-presets.json                                       shared file, byAccount.<account>.presets[]
      mcp-user-tool-toggles.json                                     shared file, owners.<key>
      plugin-list\<account>\<org>\plugins.json                       installed plugins (report only)
#>

function Get-SwDataRoot { Split-Path (Get-SwSessionsRoot) -Parent }

function Test-SwEnvItem([string]$Item) {
    $cfg = Get-SwConfig
    if (-not $cfg['syncEnvironment']) { return $false }
    $item_ = $Item
    -not (@($cfg['environmentExclude']) | Where-Object { $_ -eq $item_ })
}

# Accounts this call may write to: policy enabled, not the account open in the app, has a known org.
function Get-SwEnvTargets($From, [object[]]$To, $Policy) {
    if (-not $Policy.Enabled -or -not $From.PrimaryDir) { return @() }
    @($To | Where-Object { $_.Uuid -ne $From.Uuid -and $_.PrimaryDir -and (-not $Policy.ActiveUuid -or $_.Uuid -ne $Policy.ActiveUuid) })
}

function Backup-SwFile([string]$Path, [string]$AccountName, [switch]$Move) {
    $bdir = Join-Path (Get-SwHome) ("backups/{0}/{1:yyyyMMdd}" -f $AccountName, (Get-Date))
    if (-not (Test-Path $bdir)) { New-Item -ItemType Directory $bdir -Force | Out-Null }
    $dest = Join-Path $bdir ('{0:HHmmss}-{1}' -f (Get-Date), (Split-Path $Path -Leaf))
    if ($Move) { Move-Item -LiteralPath $Path -Destination $dest -Force } else { Copy-Item -LiteralPath $Path -Destination $dest -Force }
}

function New-SwEnvRow($Action, $From, $To, $Title, $Cwd = $null) {
    [pscustomobject]@{ Action = $Action; From = $From.Name; To = $To.Name; Title = $Title; Cwd = $Cwd }
}

# ---- 1. session deletions ---------------------------------------------------------------------

function ConvertTo-SwTombstoneId([string]$FileName) { ($FileName -replace '^deleted_', '') -replace '^local_', '' }

function Get-SwTombstoneFiles($Account) {
    if (-not $Account.Dir) { return @() }
    foreach ($f in Get-ChildItem $Account.Dir -Recurse -Filter 'deleted_*' -File -ErrorAction SilentlyContinue) {
        $ms = 0L
        try { $raw = (Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop).Trim() } catch { continue }
        if (-not [long]::TryParse($raw, [ref]$ms)) { continue }   # corrupt tombstone: ignored
        [pscustomobject]@{ Id = ConvertTo-SwTombstoneId $f.Name; Ms = $ms; File = $f; Content = $raw }
    }
}

function Get-SwTombstoneSet($Account) {
    $set = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($t in @(Get-SwTombstoneFiles $Account)) { [void]$set.Add($t.Id) }
    , $set
}

function Get-SwTombstoneMap($Account) {
    <# id -> newest deletion time (epoch ms) for one account. #>
    $map = @{}
    foreach ($t in @(Get-SwTombstoneFiles $Account)) { if (-not $map.ContainsKey($t.Id) -or $t.Ms -gt $map[$t.Id].Ms) { $map[$t.Id] = $t } }
    $map
}

function Get-SwSessionActivityMs($Index, $File) {
    <#
      Last real activity of a session, in epoch ms. The file's mtime is NOT used when the index has activity
      fields: the app rewrites index files on its own (focus, startup) and the mirror copies source mtimes,
      so mtime says nothing about whether the user worked in the session after it was deleted.
    #>
    $best = 0L
    if ($Index) {
        foreach ($k in 'lastActivityAt', 'lastTurnEdgeAt', 'latestUserFrameAt') {
            $v = 0L; if ($null -ne $Index[$k] -and [long]::TryParse([string]$Index[$k], [ref]$v) -and $v -gt $best) { $best = $v }
        }
    }
    if ($best -eq 0 -and $File) { $best = [DateTimeOffset]::new($File.LastWriteTimeUtc).ToUnixTimeMilliseconds() }
    $best
}

function Sync-SwTombstones {
    <#
      Make a session deleted in any account deleted in every account.
      For each target (never the account open in the app):
        * copy tombstones from -From that the target lacks;
        * for every tombstone the target now knows (copied, or its own), move a still-existing session file to
          backups unless the session had real activity AFTER the deletion (then the session wins and no
          tombstone is written for it). This also cleans sessions an older sync version brought back.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $From, [Parameter(Mandatory)] [object[]] $To, [switch] $DryRun, $Policy = (Get-SwTaskWritePolicy))
    $rows = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-SwEnvItem 'tombstones')) { return $rows }
    $src = Get-SwTombstoneMap $From
    foreach ($dst in Get-SwEnvTargets $From $To $Policy) {
        $have = Get-SwTombstoneMap $dst
        $all = @{}
        foreach ($m in $have, $src) { foreach ($k in $m.Keys) { if (-not $all.ContainsKey($k) -or $m[$k].Ms -gt $all[$k].Ms) { $all[$k] = $m[$k] } } }
        if ($all.Count -eq 0) { continue }
        # index the target's sessions by both ids once
        $byId = @{}
        foreach ($f in Get-ChildItem $dst.Dir -Recurse -Filter 'local_*.json' -File -ErrorAction SilentlyContinue) {
            $idx = Read-SwIndex $f.FullName
            $s = [pscustomobject]@{ File = $f; Index = $idx; Activity = (Get-SwSessionActivityMs $idx $f) }
            foreach ($id in @(($f.BaseName -replace '^local_', ''), $(if ($idx) { [string]$idx['cliSessionId'] }))) {
                if ($id) { if (-not $byId.ContainsKey($id)) { $byId[$id] = @() }; $byId[$id] += $s }
            }
        }
        $removed = @{}
        foreach ($id in $all.Keys) {
            $t = $all[$id]
            $hits = @($byId[$id] | Where-Object { $_ -and -not $removed.ContainsKey($_.File.FullName) })
            if (@($hits | Where-Object { $_.Activity -gt $t.Ms })) { continue }   # worked on after the deletion: keep it
            foreach ($h in $hits) {
                $removed[$h.File.FullName] = $true
                $rows.Add((New-SwEnvRow 'session-removed' $From $dst $(if ($h.Index) { $h.Index['title'] } else { $id }) $(if ($h.Index) { $h.Index['cwd'] })))
            }
            $copy = -not $have.ContainsKey($id)
            if ($copy) { $rows.Add((New-SwEnvRow 'tombstone' $From $dst $id)) }
            if ($DryRun) { continue }
            try {
                foreach ($h in $hits) { if (Test-Path -LiteralPath $h.File.FullName) { Backup-SwFile $h.File.FullName $dst.Name -Move } }
                if ($copy) {
                    $target = Join-Path $dst.PrimaryDir "deleted_$id"
                    Write-SwFileAtomic $target $t.Content
                    (Get-Item -LiteralPath $target).LastWriteTimeUtc = $t.File.LastWriteTimeUtc
                }
                if ($copy -or $hits) { Write-SwLog ("tombstone {0}->{1} {2} (removed {3} session file(s))" -f $From.Name, $dst.Name, $id, $hits.Count) }
            } catch { Write-SwLog ("ERROR tombstone {0}: {1}" -f $id, $_.Exception.Message) }
        }
    }
    $rows
}

# ---- 2. archive index -------------------------------------------------------------------------
# Format not verified against a real file: only a JSON array of strings or one id per line is handled;
# anything else is skipped untouched.

function Read-SwArchiveIds([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop } catch { return $null }
    if ($null -eq $raw) { $raw = '' }
    $t = $raw.Trim()
    if ($t.StartsWith('[')) {
        try { $a = @($t | ConvertFrom-Json -AsHashtable -DateKind String) } catch { return $null }
        if (@($a | Where-Object { $_ -isnot [string] }).Count) { return $null }
        return [pscustomobject]@{ Format = 'json'; Ids = @($a) }
    }
    $lines = @($raw -split '\r?\n' | Where-Object { $_.Trim() })
    if (@($lines | Where-Object { $_.Trim() -notmatch '^[A-Za-z0-9_.:-]+$' }).Count) { return $null }
    [pscustomobject]@{ Format = 'lines'; Ids = @($lines | ForEach-Object { $_.Trim() }) }
}

function Sync-SwArchiveIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $From, [Parameter(Mandatory)] [object[]] $To, [switch] $DryRun, $Policy = (Get-SwTaskWritePolicy))
    $rows = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-SwEnvItem 'archive')) { return $rows }
    $targets = @(Get-SwEnvTargets $From $To $Policy)
    if (-not $targets) { return $rows }
    $src = Read-SwArchiveIds (Join-Path $From.PrimaryDir 'archived-sessions.idx')
    if (-not $src -or -not $src.Ids) { return $rows }
    foreach ($dst in $targets) {
        $path = Join-Path $dst.PrimaryDir 'archived-sessions.idx'
        $cur = Read-SwArchiveIds $path
        if (-not $cur -and (Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 0) { continue }   # unknown format: leave alone
        $have = if ($cur) { @($cur.Ids) } else { @() }
        $missing = @($src.Ids | Where-Object { $_ -notin $have } | Select-Object -Unique)
        if (-not $missing) { continue }
        $fmt = if ($cur) { $cur.Format } else { $src.Format }
        $rows.Add((New-SwEnvRow 'archive-index' $From $dst "$($missing.Count) archived session id(s)"))
        if ($DryRun) { continue }
        try {
            $all = @($have) + $missing
            if (Test-Path -LiteralPath $path) { Backup-SwFile $path $dst.Name }
            $text = if ($fmt -eq 'json') { ConvertTo-Json -InputObject @($all) -Compress } else { ($all -join "`n") + "`n" }
            Write-SwFileAtomic $path $text
            Write-SwLog ("archive index {0}->{1}: +{2}" -f $From.Name, $dst.Name, $missing.Count)
        } catch { Write-SwLog ("ERROR archive index {0}: {1}" -f $path, $_.Exception.Message) }
    }
    $rows
}

# ---- 3. presets (shared file) -----------------------------------------------------------------

function Get-SwPresetStamp($p) {
    $best = [DateTimeOffset]::MinValue
    foreach ($k in 'lastUsedAt', 'createdAt') { $i = ConvertTo-SwInstant $p[$k]; if ($i -and $i -gt $best) { $best = $i } }
    $best
}

function Merge-SwPresetsInto($Doc, $From, [object[]]$Targets) {
    $rows = [System.Collections.Generic.List[object]]::new()
    $ba = $Doc['byAccount']
    if ($ba -isnot [System.Collections.IDictionary] -or $ba[$From.Uuid] -isnot [System.Collections.IDictionary]) { return $rows }
    $srcPresets = @($ba[$From.Uuid]['presets'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['id'] })
    foreach ($dst in $Targets) {
        if ($ba[$dst.Uuid] -isnot [System.Collections.IDictionary]) { $ba[$dst.Uuid] = [ordered]@{} }
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($p in @($ba[$dst.Uuid]['presets'])) { if ($null -ne $p) { $list.Add($p) } }
        $changed = $false
        foreach ($p in $srcPresets) {
            $i = -1
            for ($j = 0; $j -lt $list.Count; $j++) { if ($list[$j] -is [System.Collections.IDictionary] -and $list[$j]['id'] -eq $p['id']) { $i = $j; break } }
            if ($i -lt 0) {
                $list.Add((Copy-SwObject $p)); $changed = $true
                $rows.Add((New-SwEnvRow 'preset-create' $From $dst $p['name']))
            } elseif ((Get-SwPresetStamp $p) -gt (Get-SwPresetStamp $list[$i]) -and -not (Test-SwSame $p $list[$i])) {
                $list[$i] = Copy-SwObject $p; $changed = $true
                $rows.Add((New-SwEnvRow 'preset-update' $From $dst $p['name']))
            }
        }
        if ($changed) { $ba[$dst.Uuid]['presets'] = @($list) }
    }
    $rows
}

function Sync-SwPresets {
    <# builtIns and seededFromDraft are never touched. Only entries of non-open accounts are written; the file is re-read right before writing. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $From, [Parameter(Mandatory)] [object[]] $To, [switch] $DryRun, $Policy = (Get-SwTaskWritePolicy))
    $none = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-SwEnvItem 'presets')) { return $none }
    $targets = @(Get-SwEnvTargets $From $To $Policy)
    if (-not $targets) { return $none }
    $path = Join-Path (Get-SwDataRoot) 'ccd-session-presets.json'
    $doc = Read-SwJsonFile $path
    if ($doc -isnot [System.Collections.IDictionary]) { return $none }
    $rows = @(Merge-SwPresetsInto (Copy-SwObject $doc) $From $targets)
    if ($DryRun -or -not @($rows).Count) { return $rows }
    try {
        $fresh = Read-SwJsonFile $path
        if ($fresh -isnot [System.Collections.IDictionary]) { return $none }
        $rows = @(Merge-SwPresetsInto $fresh $From $targets)
        if (-not @($rows).Count) { return $rows }
        Backup-SwFile $path $From.Name
        Write-SwFileAtomic $path ($fresh | ConvertTo-Json -Depth 50)
        Write-SwLog ("presets {0}->: {1}" -f $From.Name, (($rows | ForEach-Object { "$($_.Action) $($_.To) '$($_.Title)'" }) -join '; '))
    } catch { Write-SwLog ("ERROR presets: {0}" -f $_.Exception.Message) }
    $rows
}

# ---- 5. tool toggles (shared file; entries keyed by account uuid, created where missing) ------------

function Merge-SwTogglesInto($Doc, $From, [object[]]$Targets) {
    $rows = [System.Collections.Generic.List[object]]::new()
    $o = $Doc['owners']
    if ($o -isnot [System.Collections.IDictionary] -or -not $o.Contains($From.Uuid)) { return $rows }
    foreach ($dst in $Targets) {
        if ($o.Contains($dst.Uuid)) { continue }
        $o[$dst.Uuid] = Copy-SwObject $o[$From.Uuid]
        $rows.Add((New-SwEnvRow 'toggle-create' $From $dst 'tool toggles'))
    }
    $rows
}

function Sync-SwToggles {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $From, [Parameter(Mandatory)] [object[]] $To, [switch] $DryRun, $Policy = (Get-SwTaskWritePolicy))
    $none = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-SwEnvItem 'toggles')) { return $none }
    $targets = @(Get-SwEnvTargets $From $To $Policy)
    if (-not $targets) { return $none }
    $path = Join-Path (Get-SwDataRoot) 'mcp-user-tool-toggles.json'
    $doc = Read-SwJsonFile $path
    if ($doc -isnot [System.Collections.IDictionary]) { return $none }
    $rows = @(Merge-SwTogglesInto (Copy-SwObject $doc) $From $targets)
    if ($DryRun -or -not @($rows).Count) { return $rows }
    try {
        $fresh = Read-SwJsonFile $path
        if ($fresh -isnot [System.Collections.IDictionary]) { return $none }
        $rows = @(Merge-SwTogglesInto $fresh $From $targets)
        if (-not @($rows).Count) { return $rows }
        Backup-SwFile $path $From.Name
        Write-SwFileAtomic $path ($fresh | ConvertTo-Json -Depth 50)
    } catch { Write-SwLog ("ERROR toggles: {0}" -f $_.Exception.Message) }
    $rows
}

# ---- 4. plugins (read-only report: schema not verified) ---------------------------------------

function Get-SwPluginIds($Account) {
    if (-not $Account.PrimaryOrg) { return $null }
    $path = Join-Path (Get-SwDataRoot) "plugin-list/$($Account.Uuid)/$($Account.PrimaryOrg)/plugins.json"
    $doc = Read-SwJsonFile $path
    if ($null -eq $doc) { return $null }
    $list = if ($doc -is [System.Collections.IDictionary]) { if ($doc.Contains('plugins')) { , $doc['plugins'] } else { $doc } } else { , $doc }
    $ids = if ($list -is [System.Collections.IDictionary]) { @($list.Keys) } else {
        @($list | ForEach-Object {
                if ($_ -is [string]) { $_ }
                elseif ($_ -is [System.Collections.IDictionary]) { $e = $_; [string]($e['id'], $e['pluginId'], $e['name'] | Where-Object { $_ } | Select-Object -First 1) }
            })
    }
    @($ids | Where-Object { $_ } | Sort-Object -Unique)
}

function Sync-SwPlugins {
    <# Reports plugins installed in -From but not in -To. Never writes. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $From, [Parameter(Mandatory)] [object[]] $To, [switch] $DryRun, $Policy = $null)
    $rows = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-SwEnvItem 'plugins')) { return $rows }
    $src = Get-SwPluginIds $From
    if (-not $src) { return $rows }
    foreach ($dst in $To) {
        if ($dst.Uuid -eq $From.Uuid) { continue }
        $have = Get-SwPluginIds $dst
        if ($null -eq $have) { continue }
        foreach ($id in @($src | Where-Object { $_ -notin $have })) { $rows.Add((New-SwEnvRow 'plugin-missing' $From $dst $id)) }
    }
    $rows
}

function Sync-SwEnvironment {
    param([Parameter(Mandatory)] $From, [Parameter(Mandatory)] [object[]] $To, [switch] $DryRun, $Policy = (Get-SwTaskWritePolicy))
    $cfg = Get-SwConfig
    if (-not $cfg['syncEnvironment']) { return @() }
    $rows = @()
    foreach ($fn in 'Sync-SwTombstones', 'Sync-SwArchiveIndex', 'Sync-SwPresets', 'Sync-SwToggles', 'Sync-SwPlugins') {
        try { $rows += @(& $fn -From $From -To $To -DryRun:$DryRun -Policy $Policy) } catch { Write-SwLog "ERROR $fn`: $($_.Exception.Message)" }
    }
    $rows
}
