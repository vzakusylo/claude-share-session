# Project identity: a cwd maps to its main git repository (worktrees included).
# Part of ShareWork.psm1 (dot-sourced into the module scope).


function ConvertTo-SwNativePath([string]$P) {
    if ($IsWindows) { $P -replace '/', '\' } else { $P }
}

function Get-SwProjectKey([string]$Cwd) {
    <# Main repository root for a cwd (worktrees map to their main repo). Lower-case full path. #>
    if (-not $Cwd) { return '' }
    $root = $null
    try {
        $common = & git -C $Cwd rev-parse --path-format=absolute --git-common-dir 2>$null
        if ($LASTEXITCODE -eq 0 -and $common) {
            $common = ConvertTo-SwNativePath (($common | Select-Object -First 1).Trim())
            $root = if ((Split-Path $common -Leaf) -eq '.git') { Split-Path $common -Parent } else { $common }
        }
    } catch { }
    if (-not $root) {
        $root = (ConvertTo-SwNativePath $Cwd) -replace '[\\/]\.claude[\\/]worktrees[\\/][^\\/]+.*$', ''
    }
    $root.TrimEnd('\', '/').ToLowerInvariant()
}

function Get-SwProjectSlug([string]$ProjectKey) { ($ProjectKey -replace '[^A-Za-z0-9]+', '-').Trim('-') }
