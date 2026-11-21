# Shared folder, desktop data folder, config file, log, atomic writes, JSON helpers.
# Part of ShareWork.psm1 (dot-sourced into the module scope).


function Get-SwHome {
    if ($env:SHAREWORK_HOME) { $h = $env:SHAREWORK_HOME } else { $h = Join-Path $HOME '.claude/shared-work' }
    foreach ($d in $h, (Join-Path $h 'status'), (Join-Path $h 'handoffs'), (Join-Path $h 'backups')) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    $h
}

function Get-SwSessionsRoot {
    if ($env:SHAREWORK_SESSIONS_ROOT) { return $env:SHAREWORK_SESSIONS_ROOT }
    # Windows (MSIX): %LOCALAPPDATA%\Claude-Data\claude_<pkg>\claude-code-sessions
    # macOS:          ~/Library/Application Support/Claude*/claude-code-sessions
    # Linux:          ~/.config/Claude*/claude-code-sessions
    $bases = if ($IsWindows) { @((Join-Path $env:LOCALAPPDATA 'Claude-Data'), $env:LOCALAPPDATA, $env:APPDATA) }
             elseif ($IsMacOS) { @((Join-Path $HOME 'Library/Application Support')) }
             else { @((Join-Path $HOME '.config')) }
    $cands = foreach ($b in $bases | Where-Object { $_ -and (Test-Path $_) }) {
        foreach ($d in @(Get-Item $b) + @(Get-ChildItem $b -Directory -Filter 'Claude*' -ErrorAction SilentlyContinue) +
                       @(Get-ChildItem $b -Directory -Filter 'claude_*' -ErrorAction SilentlyContinue)) {
            $s = Join-Path $d.FullName 'claude-code-sessions'
            if (Test-Path $s) { Get-Item $s }
        }
    }
    $hit = $cands | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $hit) { throw "Claude desktop 'claude-code-sessions' folder not found (looked in: $($bases -join '; ')). Set SHAREWORK_SESSIONS_ROOT." }
    $hit.FullName
}

function Get-SwConfig {
    $p = Join-Path (Get-SwHome) 'accounts.json'
    if (Test-Path $p) {
        $c = Get-Content $p -Raw | ConvertFrom-Json -AsHashtable
    } else { $c = @{} }
    if (-not $c.ContainsKey('names')) { $c['names'] = @{} }
    if (-not $c.ContainsKey('excludeCwd')) { $c['excludeCwd'] = @() }
    if (-not $c.ContainsKey('importArchived')) { $c['importArchived'] = $false }
    if (-not $c.ContainsKey('syncEnvironment')) { $c['syncEnvironment'] = $true }
    if (-not $c.ContainsKey('environmentExclude')) { $c['environmentExclude'] = @() }
    $c
}

function Save-SwConfig([hashtable]$Config) {
    $p = Join-Path (Get-SwHome) 'accounts.json'
    Write-SwFileAtomic $p ($Config | ConvertTo-Json -Depth 5)
}

function Write-SwLog([string]$Message) {
    try {
        $p = Join-Path (Get-SwHome) 'sync.log'
        $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $PID, $Message
        Add-Content -Path $p -Value $line -Encoding utf8
        if ((Get-Item $p).Length -gt 1MB) {
            $keep = Get-Content $p -Tail 2000; Set-Content $p $keep -Encoding utf8
        }
    } catch { }
}

function Write-SwFileAtomic([string]$Path, [string]$Content) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # temp name deliberately does NOT end in .json so the desktop app never picks it up half-written
    $tmp = Join-Path $dir ('.sw-tmp-' + [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($tmp, $Content, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}


function Read-SwJsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -DateKind String } catch { $null }
}
