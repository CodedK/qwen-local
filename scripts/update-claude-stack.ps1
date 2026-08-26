<#
.SYNOPSIS
    Updates Claude Code, its marketplaces/plugins, related npm CLIs and VS Code extensions.
.DESCRIPTION
    Companion utility to the Qwen stack - keeps the AI tooling on a machine current
    in one pass, and reports a before/after version table so you can see what moved.

    What it touches:
      1. Claude Code itself      (`claude update`, or npm if installed that way)
      2. Plugin marketplaces     (`claude plugin marketplace update`)
      3. Related global npm CLIs (qwen-code, codex, claude-flow, ... - configurable)
      4. VS Code extensions      (Cline, Continue)
      5. Health check            (`claude doctor`)

    Plugin *content* updates come from refreshing their marketplace - Claude Code
    has no per-plugin update command. Marketplaces backed by git are pulled; the
    rest are re-fetched from source.

.PARAMETER DryRun
    Show what would be updated without changing anything.
.PARAMETER SkipNpm
    Don't touch global npm packages.
.PARAMETER SkipExtensions
    Don't touch VS Code extensions.
.PARAMETER NpmPackages
    Override the list of global npm packages to update.
.EXAMPLE
    .\update-claude-stack.ps1
    .\update-claude-stack.ps1 -DryRun
    .\update-claude-stack.ps1 -NpmPackages '@anthropic-ai/claude-code','@qwen-code/qwen-code'
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipNpm,
    [switch]$SkipExtensions,
    [switch]$SkipMarketplaces,
    [string[]]$NpmPackages
)

$ErrorActionPreference = 'Continue'
$claudeDir = Join-Path $env:USERPROFILE '.claude'

$section = 0
function Write-Section([string]$msg) {
    $script:section++
    Write-Host ''
    Write-Host ("  [{0}] {1}" -f $script:section, $msg) -ForegroundColor Cyan
    Write-Host '  ---------------------------------------------------------------'
}
function Test-Cmd([string]$n) { return [bool](Get-Command $n -ErrorAction Ignore) }

# IMPORTANT: the `npm` PowerShell shim mangles arguments when invoked with & and
# reports nonsense like 'Unknown command: "pm"'. Always call npm.cmd on Windows.
$npm = if (Test-Cmd 'npm.cmd') { 'npm.cmd' } elseif (Test-Cmd 'npm') { 'npm' } else { $null }

Write-Host ''
Write-Host '  Claude stack updater' -ForegroundColor Green
if ($DryRun) { Write-Host '  DRY RUN - nothing will be modified' -ForegroundColor Yellow }

$before = [ordered]@{}
$after  = [ordered]@{}

function Get-GlobalNpmVersions {
    if (-not $npm) { return @{} }
    $map = @{}
    $lines = & $npm list -g --depth=0 2>$null
    foreach ($l in $lines) {
        # matches: "+-- @scope/name@1.2.3"  and  "`-- name@1.2.3"
        if ($l -match '[+`\\|]--\s+(@?[^@\s]+(?:/[^@\s]+)?)@([0-9][^\s]*)') {
            $map[$matches[1]] = $matches[2]
        }
    }
    return $map
}

# ------------------------------------------------------- 0. baseline ---------
Write-Section 'Reading current versions'
$globalsBefore = Get-GlobalNpmVersions
if (Test-Cmd 'claude') {
    $cv = (& claude --version 2>$null) -join ' '
    $before['claude-code'] = ($cv -split '\s+')[0]
    Write-Host ("    claude-code : {0}" -f $before['claude-code'])
} else {
    Write-Warning '    claude CLI not found on PATH'
}

# Default set: Claude Code plus the AI CLIs commonly installed alongside it.
# Only packages actually present are touched.
if (-not $NpmPackages) {
    $candidates = @(
        '@anthropic-ai/claude-code'
        '@qwen-code/qwen-code'
        '@openai/codex'
        'claude-flow'
        '@nanonets/graft'
        'codeburn'
    )
    $NpmPackages = $candidates | Where-Object { $globalsBefore.ContainsKey($_) }
}
foreach ($p in $NpmPackages) {
    if ($globalsBefore.ContainsKey($p)) {
        $before[$p] = $globalsBefore[$p]
        Write-Host ("    {0,-28}: {1}" -f $p, $globalsBefore[$p])
    }
}

# ------------------------------------------------------- 1. safety backup ----
Write-Section 'Backing up plugin configuration'
$cfgFiles = @('installed_plugins.json', 'known_marketplaces.json', 'config.json') |
            ForEach-Object { Join-Path $claudeDir "plugins\$_" } |
            Where-Object { Test-Path $_ }

if ($cfgFiles.Count -eq 0) {
    Write-Host '    no plugin config found - skipping'
} elseif ($DryRun) {
    Write-Host ("    would back up {0} file(s)" -f $cfgFiles.Count)
} else {
    $stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $claudeDir "backups\plugins-$stamp"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $cfgFiles | ForEach-Object { Copy-Item $_ $backupDir -Force }
    Write-Host ("    saved {0} file(s) -> {1}" -f $cfgFiles.Count, $backupDir) -ForegroundColor Green
}

# ------------------------------------------------------- 2. Claude Code ------
Write-Section 'Updating Claude Code'
if (-not (Test-Cmd 'claude')) {
    Write-Warning '    skipped - claude not installed'
} elseif ($DryRun) {
    Write-Host '    would run: claude update'
} else {
    # `claude update` handles the native build; for an npm install it is a no-op,
    # so the npm pass below covers that case.
    & claude update 2>&1 | ForEach-Object { "    $_" }
}

# ------------------------------------------------------- 3. marketplaces -----
if ($SkipMarketplaces) {
    Write-Section 'Skipping marketplaces (-SkipMarketplaces)'
} else {
    Write-Section 'Updating plugin marketplaces'

    $mkDir = Join-Path $claudeDir 'plugins\marketplaces'
    if (Test-Path $mkDir) {
        $names = Get-ChildItem $mkDir -Directory | Select-Object -ExpandProperty Name
        Write-Host ("    {0} marketplace(s): {1}" -f $names.Count, ($names -join ', '))
    }

    if ($DryRun) {
        Write-Host '    would run: claude plugin marketplace update'
    } elseif (Test-Cmd 'claude') {
        # No name argument = update them all.
        & claude plugin marketplace update 2>&1 | ForEach-Object { "    $_" }
    }

    # Report plugin inventory so a broken update is visible immediately.
    $ipPath = Join-Path $claudeDir 'plugins\installed_plugins.json'
    if (Test-Path $ipPath) {
        try {
            $ip = Get-Content $ipPath -Raw | ConvertFrom-Json
            $count = @($ip.plugins.PSObject.Properties).Count
            Write-Host ("    installed plugins: {0}" -f $count) -ForegroundColor Green
        } catch { Write-Warning "    could not parse installed_plugins.json: $($_.Exception.Message)" }
    }
}

# ------------------------------------------------------- 4. npm globals ------
if ($SkipNpm) {
    Write-Section 'Skipping npm packages (-SkipNpm)'
} elseif (-not $npm) {
    Write-Section 'Skipping npm packages (npm not found)'
} else {
    Write-Section 'Updating global npm CLIs'
    if ($NpmPackages.Count -eq 0) {
        Write-Host '    none of the known packages are installed'
    }
    foreach ($p in $NpmPackages) {
        if ($DryRun) {
            Write-Host ("    would run: npm install -g {0}@latest" -f $p)
            continue
        }
        Write-Host ("    {0} ..." -f $p) -ForegroundColor DarkCyan
        & $npm install -g "$p@latest" 2>&1 |
            Where-Object { $_ -match 'added|changed|up to date|removed|npm error' } |
            ForEach-Object { "      $_" }
    }
}

# ------------------------------------------------------- 5. VS Code ----------
if ($SkipExtensions) {
    Write-Section 'Skipping VS Code extensions (-SkipExtensions)'
} elseif (-not (Test-Cmd 'code')) {
    Write-Section 'Skipping VS Code extensions (code CLI not found)'
} else {
    Write-Section 'Updating VS Code extensions'
    $exts = @('saoudrizwan.claude-dev', 'Continue.continue')
    foreach ($e in $exts) {
        if ($DryRun) { Write-Host ("    would run: code --install-extension {0} --force" -f $e); continue }
        Write-Host ("    {0} ..." -f $e) -ForegroundColor DarkCyan
        & code --install-extension $e --force 2>&1 |
            Where-Object { $_ -match 'successfully installed|already installed|Failed' } |
            ForEach-Object { "      $_" }
    }
}

# ------------------------------------------------------- 6. health -----------
Write-Section 'Health check'
if ($DryRun) {
    Write-Host '    would run: claude doctor'
} elseif (Test-Cmd 'claude') {
    & claude doctor 2>&1 | Select-Object -First 25 | ForEach-Object { "    $_" }
}

# ------------------------------------------------------- 7. summary ----------
Write-Section 'Version changes'
if ($DryRun) {
    Write-Host '    (dry run - no changes made)' -ForegroundColor Yellow
} else {
    $globalsAfter = Get-GlobalNpmVersions
    if (Test-Cmd 'claude') { $after['claude-code'] = (((& claude --version 2>$null) -join ' ') -split '\s+')[0] }
    foreach ($p in $NpmPackages) { if ($globalsAfter.ContainsKey($p)) { $after[$p] = $globalsAfter[$p] } }

    $rows = foreach ($k in $before.Keys) {
        $old = $before[$k]
        $new = if ($after.Contains($k)) { $after[$k] } else { '?' }
        [pscustomobject]@{
            Component = $k
            Before    = $old
            After     = $new
            Changed   = if ($old -ne $new) { 'YES' } else { '' }
        }
    }
    if ($rows) { $rows | Format-Table -AutoSize }
}

Write-Host ''
Write-Host '  Done. Restart Claude Code for plugin changes to load.' -ForegroundColor Green
Write-Host ''
