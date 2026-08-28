<#
.SYNOPSIS
    One-shot installer for the local Qwen coding stack.
.DESCRIPTION
    Idempotent. Safe to re-run - every step checks before acting.

    Steps:
      1. Verify prerequisites (winget, Node 22+, VS Code)
      2. Install Ollama
      3. Profile hardware and choose a model tier
      4. Apply memory tuning derived from that profile
      5. Start the Ollama server
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

# ----------------------------------------------------------- 3. hardware -----
# Profiled BEFORE the tuning step, because the tuning is derived from it, and
# before the server starts, because the server reads its environment at launch.
Write-Step 'Profiling hardware'
& (Join-Path $PSScriptRoot 'detect-hardware.ps1') | Out-Null
$hw = Get-Content (Join-Path $root 'hardware-profile.json') -Raw | ConvertFrom-Json
Write-Host ("    tier: {0}  ({1} GB usable VRAM, ~{2} GB/s RAM)" -f $hw.tier, $hw.usableVramGB, $hw.ram.usableBandwidth)
Write-Host ("    agent      : {0}" -f $hw.recommended.agent)
Write-Host ("    uncensored : {0}" -f $hw.recommended.uncensored)
foreach ($n in $hw.notes) { Write-Warning "    $n" }

# ------------------------------------------------------------ 4. tuning ------
Write-Step 'Applying memory tuning'

# Scaled off the profile above. An 8 GB card and a 24 GB card want different
# numbers, and hardcoding the 8 GB ones leaves a big card idling.
#   flash attention  - smaller, faster attention kernels, always worth it
#   q8_0 KV cache    - roughly halves KV memory vs f16, so context gets cheaper
#   num_parallel 1   - parallel slots split the context window AND the VRAM
$vramGB = [double]$hw.usableVramGB
if ($vramGB -ge 20) {
    # Weights and KV both fit on the card. Afford a long context, keep a second
    # small model (the FIM autocomplete) resident so it stops evicting the agent,
    # and reload rarely - a cold load of a 17 GB model is ~50 s.
    #
    # CAUTION, UNVERIFIED: on a 24 GB card maxLoaded 2 is tight, and the sum is
    # only just under the line - ~17.3 GB agent + ~1.7 GB KV at 32768/q8_0 +
    # ~1.8 GB FIM model + whatever the desktop compositor holds. There is no
    # working way to reserve VRAM for the compositor (see the OLLAMA_GPU_OVERHEAD
    # note below), so this relies on llama.cpp's fit pass offloading honestly.
    # After the first benchmark on a new card, check `ollama ps`: if the agent
    # shows a CPU split, or reports 100% GPU while tok/s is an order of magnitude
    # low, drop maxLoaded to 1 before touching anything else.
    $ctxLen = 32768; $maxLoaded = 2; $keepAlive = '60m'
} elseif ($vramGB -ge 10) {
    $ctxLen = 32768; $maxLoaded = 1; $keepAlive = '30m'
} else {
    # Reference-box territory: anything larger silently pages over PCIe.
    $ctxLen = 16384; $maxLoaded = 1; $keepAlive = '30m'
}

$tuning = [ordered]@{
    OLLAMA_FLASH_ATTENTION   = '1'
    OLLAMA_KV_CACHE_TYPE     = 'q8_0'
    OLLAMA_KEEP_ALIVE        = $keepAlive
    OLLAMA_MAX_LOADED_MODELS = "$maxLoaded"
    OLLAMA_NUM_PARALLEL      = '1'
    OLLAMA_CONTEXT_LENGTH    = "$ctxLen"
}

# OLLAMA_GPU_OVERHEAD is deliberately NOT set here. Three measured reasons:
#
#   1. It does nothing on Ollama 0.33.1. The scheduler does subtract it - the log
#      shows `gpu memory available="2.3 GiB" free="22.8 GiB" overhead="20.0 GiB"` -
#      but the llama.cpp auto-fit pass that runs next (LLAMA_ARG_FIT, on by
#      default) re-reads real device memory and overrides the result. A 20 GiB
#      reserve on a 24 GiB card still offloaded 33/33 layers at 100% GPU.
#   2. On older builds that DO honour it, a reserve big enough to matter pushes
#      qwen38-9b off an 8 GB card - a regression on the reference machine.
#   3. Anything derived from nvidia-smi's FREE VRAM is non-deterministic: it
#      measures every consumer on the card, not the compositor. Two runs minutes
#      apart on the same idle box produced 3840 MB and 5120 MB.
#
# Clear any value an earlier run of this script persisted, so that the block
# below fully determines the environment rather than layering onto old state.
# [NullString]::Value, not $null: PowerShell coerces $null to '' when binding to
# a [string] parameter, which DELETES NOTHING - it leaves the variable behind set
# to an empty string. Verified in HKCU:\Environment.
[Environment]::SetEnvironmentVariable('OLLAMA_GPU_OVERHEAD', [NullString]::Value, 'User')
Remove-Item env:OLLAMA_GPU_OVERHEAD -ErrorAction Ignore

foreach ($k in $tuning.Keys) {
    [Environment]::SetEnvironmentVariable($k, $tuning[$k], 'User')
    Set-Item -Path "env:$k" -Value $tuning[$k]      # so the server we spawn inherits it
    Write-Host ("    {0,-26} = {1}" -f $k, $tuning[$k])
}

# ------------------------------------------------------------- 5. server -----
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
    # MUST be npm.cmd: the `npm` PowerShell shim mangles arguments when invoked
    # with & and fails with 'Unknown command: "pm"'.
    $npmExe = if (Get-Command 'npm.cmd' -ErrorAction Ignore) { 'npm.cmd' } else { 'npm' }
    & $npmExe install -g '@qwen-code/qwen-code@latest' 2>&1 |
        Where-Object { $_ -match 'added|changed|up to date|npm error' } |
        ForEach-Object { "      $_" }
    if (-not (Get-Command 'qwen' -ErrorAction Ignore)) {
        Write-Warning '      qwen CLI still not on PATH - open a new terminal, or install manually:'
        Write-Warning '        npm.cmd install -g @qwen-code/qwen-code@latest'
    } else {
        Write-Host ("      qwen {0} ok" -f ((& qwen --version 2>$null) | Select-Object -First 1)) -ForegroundColor Green
    }

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
