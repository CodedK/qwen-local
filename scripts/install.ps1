<#
.SYNOPSIS
    One-shot installer for the local Qwen coding stack.
.DESCRIPTION
    Idempotent. Safe to re-run - every step checks before acting.

    Steps:
      1. Verify prerequisites (winget, Node 22+, VS Code)
      2. Install Ollama
      3. Apply memory-tuning environment variables
      4. Start the Ollama server
      5. Profile hardware and choose a model tier
      6. Pull the tier's models
      7. Build short tuned aliases
      8. Install Qwen Code CLI + VS Code extensions
      9. Point the clients at local Ollama
     10. Benchmark
.EXAMPLE
    .\install.ps1
    .\install.ps1 -SkipModels          # set up tooling only
    .\install.ps1 -All                 # also pull the big uncensored dense model
#>
[CmdletBinding()]
param(
    [switch]$SkipModels,
    [switch]$SkipClients,
    [switch]$SkipBenchmark,
    [switch]$All
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$step = 0
function Write-Step([string]$msg) {
    $script:step++
    Write-Host ''
    Write-Host ("  [{0}] {1}" -f $script:step, $msg) -ForegroundColor Cyan
    Write-Host '  ---------------------------------------------------------------'
}
function Test-Cmd([string]$n) { return [bool](Get-Command $n -ErrorAction Ignore) }

Write-Host ''
Write-Host '  qwen-local installer' -ForegroundColor Green
Write-Host "  target: $root"

# --------------------------------------------------------- 1. prerequisites --
Write-Step 'Checking prerequisites'

if (-not (Test-Cmd 'winget')) {
    throw 'winget not found. Install "App Installer" from the Microsoft Store, then re-run.'
}
Write-Host '    winget    ok'

if (Test-Cmd 'node') {
    $nodeMajor = [int](((& node -v) -replace '^v', '') -split '\.')[0]
    if ($nodeMajor -lt 22) {
        Write-Warning "    Node $nodeMajor found; Qwen Code CLI needs >= 22. Installing current LTS."
        winget install --id OpenJS.NodeJS.LTS --exact --silent --accept-package-agreements --accept-source-agreements | Out-Null
    } else {
        Write-Host "    node      ok (v$nodeMajor)"
    }
} else {
    Write-Host '    node      missing - installing LTS'
    winget install --id OpenJS.NodeJS.LTS --exact --silent --accept-package-agreements --accept-source-agreements | Out-Null
}

if (Test-Cmd 'code') { Write-Host '    vscode    ok' }
else { Write-Warning '    VS Code CLI not found - Cline/Continue steps will be skipped.' }

# ------------------------------------------------------------- 2. ollama -----
Write-Step 'Installing Ollama'

$ollama = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
if (Test-Path $ollama) {
    Write-Host "    already installed ($(& $ollama --version))"
} else {
    winget install --id Ollama.Ollama --exact --silent --accept-package-agreements --accept-source-agreements | Out-Null
    if (-not (Test-Path $ollama)) {
        $c = Get-Command ollama -ErrorAction Ignore
        if ($c) { $ollama = $c.Source } else { throw 'Ollama install finished but ollama.exe was not found.' }
    }
    Write-Host '    installed'
}

# ------------------------------------------------------------ 3. tuning ------
Write-Step 'Applying memory tuning'

# Chosen for GPUs where the model does not comfortably fit in VRAM:
#   flash attention  - smaller, faster attention kernels
#   q8_0 KV cache    - roughly halves KV memory vs f16
#   keep_alive 30m   - reloading a 15 GB model costs ~20 s, so avoid churn
#   1 loaded model   - two models will not co-exist in 8-12 GB of VRAM
#   num_parallel 1   - parallel slots split the context window and VRAM
$tuning = @{
    OLLAMA_FLASH_ATTENTION   = '1'
    OLLAMA_KV_CACHE_TYPE     = 'q8_0'
    OLLAMA_KEEP_ALIVE        = '30m'
    OLLAMA_MAX_LOADED_MODELS = '1'
    OLLAMA_NUM_PARALLEL      = '1'
    OLLAMA_CONTEXT_LENGTH    = '16384'
}
foreach ($k in $tuning.Keys) {
    [Environment]::SetEnvironmentVariable($k, $tuning[$k], 'User')
    Set-Item -Path "env:$k" -Value $tuning[$k]      # so the server we spawn inherits it
    Write-Host ("    {0,-26} = {1}" -f $k, $tuning[$k])
}

# ------------------------------------------------------------- 4. server -----
Write-Step 'Starting Ollama server'

function Test-OllamaUp {
    try { Invoke-RestMethod 'http://127.0.0.1:11434/api/version' -TimeoutSec 5 | Out-Null; return $true }
    catch { return $false }
}

if (Test-OllamaUp) {
    # Running, but possibly without the tuning above. Restart so it picks it up.
    Write-Host '    already running - restarting to apply tuning'
    Get-Process 'ollama', 'ollama app' -ErrorAction Ignore | Stop-Process -Force -ErrorAction Ignore
    Start-Sleep -Seconds 2
}

# The tray app does not reliably spawn the server; start it directly.
Start-Process -FilePath $ollama -ArgumentList 'serve' -WindowStyle Hidden
$deadline = (Get-Date).AddSeconds(30)
while (-not (Test-OllamaUp) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 700 }
if (-not (Test-OllamaUp)) { throw 'Ollama server did not come up on port 11434.' }
Write-Host '    up on http://127.0.0.1:11434'

# ----------------------------------------------------------- 5. hardware -----
Write-Step 'Profiling hardware'
& (Join-Path $PSScriptRoot 'detect-hardware.ps1') | Out-Null
$hw = Get-Content (Join-Path $root 'hardware-profile.json') -Raw | ConvertFrom-Json
Write-Host ("    tier: {0}  ({1} GB usable VRAM, ~{2} GB/s RAM)" -f $hw.tier, $hw.usableVramGB, $hw.ram.usableBandwidth)
Write-Host ("    agent      : {0}" -f $hw.recommended.agent)
Write-Host ("    uncensored : {0}" -f $hw.recommended.uncensored)
foreach ($n in $hw.notes) { Write-Warning "    $n" }

# ------------------------------------------------------------- 6. models -----
if ($SkipModels) {
    Write-Step 'Skipping model downloads (-SkipModels)'
} else {
    Write-Step 'Downloading models (this is the long part)'
    $pullArgs = @{}
    if ($All) { $pullArgs['All'] = $true }
    & (Join-Path $PSScriptRoot 'pull-models.ps1') @pullArgs

    Write-Step 'Building tuned aliases'
    & (Join-Path $PSScriptRoot 'create-modelfiles.ps1')
}

# ------------------------------------------------------------ 7. clients -----
if ($SkipClients) {
    Write-Step 'Skipping client setup (-SkipClients)'
} else {
    Write-Step 'Installing client front-ends'

    Write-Host '    Qwen Code CLI ...'
    & npm install -g '@qwen-code/qwen-code@latest' 2>&1 | Select-Object -Last 1

    if (Test-Cmd 'code') {
        foreach ($ext in @('saoudrizwan.claude-dev', 'Continue.continue')) {
            Write-Host "    $ext ..."
            & code --install-extension $ext --force 2>&1 |
                Where-Object { $_ -match 'successfully installed|already installed' } |
                ForEach-Object { "      $_" }
        }
    }

    if (-not $SkipModels) {
        Write-Step 'Wiring clients to local Ollama'
        & (Join-Path $PSScriptRoot 'configure-clients.ps1')
    }
}

# ---------------------------------------------------------- 8. benchmark -----
if (-not $SkipBenchmark -and -not $SkipModels) {
    Write-Step 'Benchmarking (measures real tok/s - takes a few minutes)'
    try { & (Join-Path $PSScriptRoot 'benchmark.ps1') }
    catch { Write-Warning "    benchmark failed: $($_.Exception.Message)" }
}

# ----------------------------------------------------------------- done ------
Write-Host ''
Write-Host '  ===============================================================' -ForegroundColor Green
Write-Host '   Done.' -ForegroundColor Green
Write-Host ''
Write-Host '   Terminal agent :  cd <project>  then  qwen'
Write-Host '   Direct chat    :  ollama run qwen38-9b'
Write-Host '   Check split    :  ollama ps'
Write-Host ''
Write-Host '   Cline needs one manual step - see docs/clients.md'
Write-Host '  ===============================================================' -ForegroundColor Green
Write-Host ''
