<#
.SYNOPSIS
    Registers the local qwen-mcp server with Claude Code.
.DESCRIPTION
    Makes the Ollama Qwen models available to Claude Code as native tools
    (ask_qwen, list_qwen_models, qwen_health) instead of something you shell out
    to. Cursor and any other MCP client can use the same entry.

    The server itself lives in mcp/qwen-mcp and has no dependencies, so there is
    nothing to npm install - registration is the whole job.

    Preferred route is `claude mcp add`. If the Claude Code CLI is not on this
    machine, the entry is merged into ~/.claude.json instead: the existing file
    is backed up first, only the one key is touched, and the result is re-parsed
    to prove it survived. Nothing is ever blindly overwritten.

    Re-running is safe. An existing registration is left alone unless -Force.
.EXAMPLE
    .\scripts\install-qwen-mcp.ps1
.EXAMPLE
    .\scripts\install-qwen-mcp.ps1 -Scope project -Force
.NOTES
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.
#>
[CmdletBinding()]
param(
    [string]$Name = 'qwen',
    [ValidateSet('local','user','project')]
    [string]$Scope = 'user',
    [string]$OllamaHost = 'http://127.0.0.1:11434',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Without an explicit exit, PowerShell hands the caller whatever the last native
# command happened to leave behind - the merger's benign "already present" 2 on a
# successful re-run, and 0 on a total failure when invoked with -File. install.ps1
# and CI need to tell those apart, so the outcome is tracked and exited on.
$exitCode = 0

# While ErrorActionPreference is Stop, anything a native command writes to stderr
# becomes a terminating error the moment it is merged into the pipeline - and
# `claude mcp get` reports "no such server" on stderr as its normal not-found
# path. Relax the preference around native calls and judge them by exit code.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Backup-IfExists([string]$path) {
    if (Test-Path $path) {
        $bak = "$path.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $path $bak -Force
        Write-Host "    backed up existing -> $(Split-Path $bak -Leaf)" -ForegroundColor DarkGray
        return $bak
    }
    return $null
}

# ------------------------------------------------------------------- node ----
$node = Join-Path $env:ProgramFiles 'nodejs\node.exe'
if (-not (Test-Path $node)) {
    $c = Get-Command node -ErrorAction Ignore
    if ($c) { $node = $c.Source } else { throw 'node.exe not found. Install Node 18+ (winget install OpenJS.NodeJS.LTS) and re-run.' }
}

# The server uses global fetch, which only exists from Node 18.
$nodeVersion = (& $node --version).Trim()
$major = 0
if ($nodeVersion -match '^v(\d+)') { $major = [int]$matches[1] }
if ($major -lt 18) { throw "Node $nodeVersion is too old - qwen-mcp needs >= 18 for global fetch." }

# ----------------------------------------------------------------- server ----
$server = Join-Path (Split-Path $PSScriptRoot -Parent) 'mcp\qwen-mcp\index.js'
if (-not (Test-Path $server)) { throw "Server not found at $server. Is the repo complete?" }

# Catch a syntax error here rather than as a silent connection failure later.
$check = Invoke-Native $node @('--check', $server)
if ($check.ExitCode -ne 0) {
    $check.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    throw "$server failed a syntax check."
}

Write-Host ''
Write-Host '  qwen-mcp registration' -ForegroundColor Cyan
Write-Host "    node   : $node ($nodeVersion)"
Write-Host "    server : $server"
Write-Host "    ollama : $OllamaHost"
Write-Host "    name   : $Name (scope: $Scope)"
Write-Host ''

# ------------------------------------------------------- route 1: claude CLI --
# Ask for the .cmd shim by name first, so a PATHEXT quirk cannot hand back the
# extensionless shell script that Windows cannot execute directly.
$claude = Get-Command 'claude.cmd' -ErrorAction Ignore
if (-not $claude) { $claude = Get-Command 'claude' -ErrorAction Ignore }

$registered = $false

if ($claude) {
    Write-Host '  Using the Claude Code CLI' -ForegroundColor Cyan
    $probe = Invoke-Native $claude.Source @('mcp', 'get', $Name)
    $exists = ($probe.ExitCode -eq 0)

    if ($exists -and -not $Force) {
        Write-Host "    '$Name' is already registered - left untouched. Re-run with -Force to replace it." -ForegroundColor Yellow
        $registered = $true
    } else {
        if ($exists) {
            Write-Host "    replacing existing '$Name'" -ForegroundColor DarkGray
            $rm = Invoke-Native $claude.Source @('mcp', 'remove', $Name)
            $rm.Output | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        }
        $add = Invoke-Native $claude.Source @('mcp', 'add', $Name, '-s', $Scope, '-e', "OLLAMA_HOST=$OllamaHost", '--', $node, $server)
        $add.Output | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        if ($add.ExitCode -eq 0) {
            $registered = $true
            Write-Host "    registered '$Name' in $Scope scope" -ForegroundColor Green
        } else {
            Write-Warning "claude mcp add exited $($add.ExitCode) - falling back to editing the config directly."
        }
    }
} else {
    Write-Host '  Claude Code CLI not found - editing the config directly' -ForegroundColor Yellow
}

# -------------------------------------------------- route 2: merge the JSON ---
if (-not $registered) {
    $cfg = Join-Path $env:USERPROFILE '.claude.json'
    Write-Host "  Merging into $cfg" -ForegroundColor Cyan

    $bak = Backup-IfExists $cfg

    # The edit is done in Node, not PowerShell. Windows PowerShell 5.1's
    # ConvertFrom-Json folds key case and hard-fails on an object holding both
    # "C:/proj" and "c:/proj" - which a real ~/.claude.json does, because it keys
    # projects by path. ConvertTo-Json would also need a depth guess and emits a
    # BOM that JSON.parse rejects. Node is already required for this server and
    # round-trips the file exactly.
    $merger = @'
const fs = require('fs');
const [cfgPath, name, command, serverPath, ollamaHost, force] = process.argv.slice(2);

let root = {};
if (fs.existsSync(cfgPath)) {
    const raw = fs.readFileSync(cfgPath, 'utf8').replace(/^\uFEFF/, '');
    if (raw.trim()) root = JSON.parse(raw);
}
const beforeKeys = Object.keys(root).length;

if (!root.mcpServers || typeof root.mcpServers !== 'object') root.mcpServers = {};
if (root.mcpServers[name] && force !== 'true') {
    console.error(`'${name}' already exists in ${cfgPath}. Re-run with -Force to replace it.`);
    process.exit(2);
}
root.mcpServers[name] = { type: 'stdio', command, args: [serverPath], env: { OLLAMA_HOST: ollamaHost } };

fs.writeFileSync(cfgPath, JSON.stringify(root, null, 2), 'utf8');

const back = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
if (back.mcpServers[name].command !== command || Object.keys(back).length < beforeKeys) {
    console.error('post-write verification failed');
    process.exit(3);
}
console.log(`merged ${name} into mcpServers (${Object.keys(back.mcpServers).length} servers, ${Object.keys(back).length} top-level keys)`);
'@

    $mergerPath = Join-Path $env:TEMP 'qwen-mcp-merge.js'
    # Set-Content -Encoding UTF8 emits a BOM on Windows PowerShell 5.1. Node
    # happens to strip one from CommonJS source, but writing a BOM into a file
    # meant to be read as UTF-8 is the exact trap this repo keeps hitting.
    [System.IO.File]::WriteAllText($mergerPath, $merger, (New-Object System.Text.UTF8Encoding $false))

    $forceFlag = 'false'
    if ($Force) { $forceFlag = 'true' }
    $merge = Invoke-Native $node @($mergerPath, $cfg, $Name, $node, $server, $OllamaHost, $forceFlag)
    $merge.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    Remove-Item $mergerPath -Force -ErrorAction Ignore

    if ($merge.ExitCode -eq 0) {
        $registered = $true
        Write-Host "    merged '$Name' into mcpServers" -ForegroundColor Green
    } elseif ($merge.ExitCode -eq 2) {
        Write-Host "    '$Name' already present - left untouched. Re-run with -Force to replace it." -ForegroundColor Yellow
        $registered = $true
    } else {
        if ($bak) {
            Copy-Item $bak $cfg -Force
            Write-Warning "Verification failed - restored $cfg from the backup. Nothing was changed."
        } else {
            Write-Warning 'Verification failed and there was no backup to restore.'
        }
    }
}

# ----------------------------------------------------------------- report -----
Write-Host ''
if ($registered) {
    Write-Host '  Registered. Restart Claude Code (or run /mcp) to pick it up.' -ForegroundColor Green
    Write-Host '  Tools it gains:' -ForegroundColor Cyan
    Write-Host "    mcp__${Name}__ask_qwen          - ask a local model, get text back"
    Write-Host "    mcp__${Name}__list_qwen_models  - what is installed and what fits in VRAM"
    Write-Host "    mcp__${Name}__qwen_health       - is Ollama up, what is loaded, GPU/CPU split"
    Write-Host ''
    Write-Host "  Verify: claude mcp get $Name" -ForegroundColor DarkGray
} else {
    $exitCode = 1
    Write-Host '  Automatic registration failed. Do it by hand:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "    claude mcp add $Name -s $Scope -e OLLAMA_HOST=$OllamaHost -- ""$node"" ""$server"""
    Write-Host ''
    Write-Host '  Or add this to the mcpServers object in ~/.claude.json:' -ForegroundColor Yellow
    Write-Host ''
    $manual = [ordered]@{
        $Name = [ordered]@{
            type    = 'stdio'
            command = $node
            args    = @($server)
            env     = [ordered]@{ OLLAMA_HOST = $OllamaHost }
        }
    }
    ($manual | ConvertTo-Json -Depth 6) -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
}
Write-Host ''

# 0 = registered (whether merged now or already there), 1 = not registered.
exit $exitCode
