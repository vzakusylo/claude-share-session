# Sidebar mirroring: session index files local_*.json between accounts.
# Part of ShareWork.psm1 (dot-sourced into the module scope).


function Read-SwIndex([string]$Path) {
    # -DateKind String: never turn ISO-looking strings into DateTime (would rewrite them on save)
    try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -DateKind String } catch { $null }
}

function Get-SwComparable([hashtable]$Index) {
    $c = [ordered]@{}
    foreach ($k in ($Index.Keys | Sort-Object)) { if ($k -notin $script:AccountBoundKeys) { $c[$k] = $Index[$k] } }
    $c | ConvertTo-Json -Depth 50 -Compress
}

function Test-SwExcluded([hashtable]$Index, [hashtable]$Config) {
    $cwd = [string]$Index['cwd']
    foreach ($pat in @($Config.excludeCwd)) { if ($pat -and $cwd -like $pat) { return $true } }
    $false
}

function Find-SwIndexFile($Account, [string]$FileName) {
    Get-ChildItem $Account.Dir -Recurse -Filter $FileName -File -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Sync-SwSessions {
    <#
      Mirror desktop session index files from -From to every account in -To.
      Rule per session id: create if missing; if both exist, the newer file (LastWriteTimeUtc) wins.
      Account-bound fields of an existing target copy are preserved; never deletes anything.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $From,
        [Parameter(Mandatory)] [object[]] $To,
        [switch] $DryRun,
        [string] $OnlyCliSessionId
    )
    $cfg = Get-SwConfig
    $home_ = Get-SwHome
    $result = [System.Collections.Generic.List[object]]::new()
    $srcFiles = Get-ChildItem $From.Dir -Recurse -Filter 'local_*.json' -File -ErrorAction SilentlyContinue
    $srcTombs = Get-SwTombstoneMap $From
    foreach ($dst in $To) {
        if ($dst.Uuid -eq $From.Uuid) { continue }
        if (-not $dst.PrimaryDir) { continue }
        $dstTombs = Get-SwTombstoneMap $dst
        foreach ($sf in $srcFiles) {
            $src = Read-SwIndex $sf.FullName
            if (-not $src -or -not $src['cliSessionId']) { continue }
            if ($OnlyCliSessionId -and $src['cliSessionId'] -ne $OnlyCliSessionId) { continue }
            if (Test-SwExcluded $src $cfg) { continue }

            # a session deleted in either account is never copied, re-created or updated,
            # unless someone worked in it after the deletion
            $activity = Get-SwSessionActivityMs $src $sf
            $dead = $false
            foreach ($id in @(($sf.BaseName -replace '^local_', ''), [string]$src['cliSessionId'])) {
                foreach ($m in $srcTombs, $dstTombs) { if ($m.ContainsKey($id) -and $m[$id].Ms -ge $activity) { $dead = $true } }
            }
            if ($dead) { continue }

            $tf = Find-SwIndexFile $dst $sf.Name
            $action = $null; $out = $null
            if (-not $tf) {
                if ($src['isArchived'] -and -not $cfg.importArchived) { continue }
                $out = [ordered]@{}
                foreach ($k in $src.Keys) { if ($k -notin $script:AccountBoundKeys) { $out[$k] = $src[$k] } }
                $out['remoteMcpServersConfig'] = @()
                $targetPath = Join-Path $dst.PrimaryDir $sf.Name
                $action = 'create'
            } else {
                if ($sf.LastWriteTimeUtc -le $tf.LastWriteTimeUtc.AddSeconds(1)) { continue }
                $tgt = Read-SwIndex $tf.FullName
                if (-not $tgt) { continue }
                if ((Get-SwComparable $src) -eq (Get-SwComparable $tgt)) { continue }
                $out = [ordered]@{}
                foreach ($k in $src.Keys) { if ($k -notin $script:AccountBoundKeys) { $out[$k] = $src[$k] } }
                foreach ($k in $script:AccountBoundKeys) { if ($tgt.ContainsKey($k)) { $out[$k] = $tgt[$k] } }
                $targetPath = $tf.FullName
                $action = 'update'
            }
            $row = [pscustomobject]@{
                Action = $action; From = $From.Name; To = $dst.Name; Title = $src['title']
                Cwd = $src['cwd']; CliSessionId = $src['cliSessionId']; File = $targetPath
            }
            $result.Add($row)
            if ($DryRun) { continue }
            try {
                if ($action -eq 'update') {
                    $bdir = Join-Path $home_ ("backups/{0}/{1:yyyyMMdd}" -f $dst.Name, (Get-Date))
                    if (-not (Test-Path $bdir)) { New-Item -ItemType Directory $bdir -Force | Out-Null }
                    Copy-Item -LiteralPath $targetPath -Destination (Join-Path $bdir ('{0:HHmmss}-{1}' -f (Get-Date), $sf.Name)) -Force
                }
                Write-SwFileAtomic $targetPath ($out | ConvertTo-Json -Depth 50)
                # keep the source timestamp so "newest wins" stays true in both directions
                (Get-Item -LiteralPath $targetPath).LastWriteTimeUtc = $sf.LastWriteTimeUtc
                Write-SwLog ("{0} {1}->{2} '{3}' {4}" -f $action, $From.Name, $dst.Name, $src['title'], $src['cliSessionId'])
            } catch {
                Write-SwLog ("ERROR {0} {1}: {2}" -f $action, $targetPath, $_.Exception.Message)
            }
        }
    }
    # prune backups older than 14 days
    if (-not $DryRun) {
        Get-ChildItem (Join-Path $home_ 'backups') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ChildItem $_.FullName -Directory | Where-Object LastWriteTime -lt (Get-Date).AddDays(-14) |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $result
}
