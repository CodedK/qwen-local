<#
.SYNOPSIS
    Creates short, tuned aliases for whichever Qwen models are installed.
.DESCRIPTION
    Raw Hugging Face refs like
      hf.co/mradermacher/Qwen3.8-9B-heretic-uncensored-GGUF:Q4_K_M
    are miserable to type and to put in config files. This wraps each installed
    base model in a stable alias with sampling parameters and a context length
    that suit the model family.

    Aliases created (only for models actually present):
      qwen-coder      -> qwen3-coder:30b         (MoE agentic workhorse)
      qwen38-9b       -> Qwen3.8-9B uncensored   (fits fully in VRAM)
      qwen38-27b      -> Qwen3.8-27B uncensored  (dense, hybrid offload)
      qwen-coder-next -> Qwen3-Coder-Next 80B    (MoE, needs >= 64 GB RAM)

    Context lengths are derived from hardware-profile.json unless overridden.

    Re-running is safe - `ollama create` overwrites the alias in place and does
    not re-download anything.
#>
[CmdletBinding()]
param(
    # All three default to 0, meaning "derive from hardware-profile.json". Pass a
    # positive number to pin one explicitly.
    #
    # Context length for the big dense model.
    [int]$DenseContext = 0,
    # MoE models stream experts from RAM, so context is cheap for them.
    [int]$MoeContext   = 0,
    # Context for models meant to sit ENTIRELY in VRAM. Kept conservative on small
    # cards: on Windows, overshooting VRAM does not fail - the WDDM driver silently
    # pages over PCIe and throughput drops ~200x while `ollama ps` still says
    # "100% GPU". Measured on an 8 GB RTX 2060S:
    # 8192->43 tok/s, 16384->40 tok/s, 24576->0.2 tok/s.
    [int]$VramFitContext = 0,
    # Autocomplete context. NOT derived from VRAM - it is bounded by what the
    # client sends, and Continue caps its prompt at 1024 tokens. Left at the
    # server default the 3B FIM model costs 2943 MB of VRAM; at 4096 it costs
    # 2261 MB. Both measured on the RTX 3090. That 682 MB is pure waste on a card
    # already holding a 20 GB agent model.
    [int]$FimContext = 4096
)

$ErrorActionPreference = 'Stop'

$ollama = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
if (-not (Test-Path $ollama)) {
    $c = Get-Command ollama -ErrorAction Ignore
    if ($c) { $ollama = $c.Source } else { throw "ollama.exe not found. Run install.ps1 first." }
}

# ---- context defaults, scaled to the card ------------------------------------
# A 24 GB card holds a 17 GB MoE plus a 32k KV cache with room to spare; an 8 GB
# card does not. Reading the profile keeps one script from being tuned for one box.
$profilePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'hardware-profile.json'
$vramGB = 0.0
if (Test-Path $profilePath) {
    $vramGB = [double](Get-Content $profilePath -Raw | ConvertFrom-Json).usableVramGB
} else {
    Write-Host '  hardware-profile.json missing - assuming a small card' -ForegroundColor Yellow
}

if ($vramGB -ge 20) {
    $dDense = 32768; $dMoe = 32768; $dVramFit = 32768
} elseif ($vramGB -ge 10) {
    $dDense = 16384; $dMoe = 32768; $dVramFit = 16384
} else {
    $dDense = 16384; $dMoe = 32768; $dVramFit = 16384
}
if ($DenseContext   -le 0) { $DenseContext   = $dDense }
if ($MoeContext     -le 0) { $MoeContext     = $dMoe }
if ($VramFitContext -le 0) { $VramFitContext = $dVramFit }
Write-Host ("  contexts: dense={0} moe={1} vram-fit={2}  (usable VRAM {3} GB)" -f `
            $DenseContext, $MoeContext, $VramFitContext, $vramGB) -ForegroundColor DarkGray

$installed = (& $ollama list) -split "`n" | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ -and $_ -ne 'NAME' }

# `ollama list` always prints an explicit tag, so a base referenced without one
# ('qwen3-coder-next') has to be matched against 'qwen3-coder-next:latest'.
function Test-InstalledBase([string]$base) {
    if ($installed -contains $base) { return $true }
    if ($base -notmatch ':') { return ($installed -contains "${base}:latest") }
    return ($installed -contains ($base -replace ':latest$', ''))
}

# Qwen's published sampling recommendations for the Qwen3 family. Greedy decoding
# on these models causes repetition loops, so temperature stays > 0.
$commonParams = @'
PARAMETER temperature 0.7
PARAMETER top_p 0.8
PARAMETER top_k 20
PARAMETER repeat_penalty 1.05
'@

$aliases = @(
    @{
        alias = 'qwen-coder'
        base  = 'qwen3-coder:30b'
        ctx   = $MoeContext
        desc  = 'MoE agentic coder, 3B active params'
    }
    @{
        alias = 'qwen38-9b'
        base  = 'hf.co/mradermacher/Qwen3.8-9B-heretic-uncensored-GGUF:Q4_K_M'
        ctx   = $VramFitContext
        desc  = 'Qwen3.8 9B uncensored, sized to stay entirely in VRAM'
    }
    @{
        alias = 'qwen38-27b'
        base  = 'hf.co/JonathanColetti/Qwen3.8-27B-Uncensored-GGUF:noMTP-Q4_K_M'
        ctx   = $DenseContext
        desc  = 'Qwen3.8 27B uncensored, dense - slow if it spills out of VRAM'
    }
    @{
        # 80B total / 3B active. Too big for any consumer card, but only ~1.5 GB of
        # weights move per token, so the RAM-resident half is not the disaster it
        # would be for a dense model of this size. Needs >= 64 GB system RAM.
        alias = 'qwen-coder-next'
        base  = 'qwen3-coder-next:latest'
        ctx   = $MoeContext
        desc  = 'Qwen3-Coder-Next 80B-A3B MoE - strongest local agent, hybrid VRAM/RAM'
    }
)

# Autocomplete alias. Without this the FIM model inherits OLLAMA_CONTEXT_LENGTH -
# 32768 on a big card - and sits in VRAM three-quarters empty next to the agent.
$fimBase = @('qwen2.5-coder:3b-base', 'qwen2.5-coder:1.5b-base') |
           Where-Object { Test-InstalledBase $_ } | Select-Object -First 1
if ($fimBase) {
    $aliases += @{
        alias = 'qwen-fim'
        base  = $fimBase
        ctx   = $FimContext
        desc  = 'Fill-in-the-middle autocomplete, context capped to what the client actually sends'
    }
}

$tmpDir = Join-Path $env:TEMP 'qwen-modelfiles'
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

foreach ($a in $aliases) {
    if (-not (Test-InstalledBase $a.base)) {
        Write-Host ("  skip  {0,-12} - base not installed ({1})" -f $a.alias, $a.base) -ForegroundColor DarkGray
        continue
    }

    $content = @"
# $($a.desc)
# Generated by create-modelfiles.ps1 - edit the script, not this file.
FROM $($a.base)

PARAMETER num_ctx $($a.ctx)
$commonParams
"@

    $mf = Join-Path $tmpDir "$($a.alias).Modelfile"
    Set-Content -Path $mf -Value $content -Encoding UTF8

    Write-Host ("  build {0,-12} <- {1}" -f $a.alias, $a.base) -ForegroundColor Cyan
    & $ollama create $a.alias -f $mf 2>&1 | Where-Object { $_ -match 'error|success' } | ForEach-Object { "        $_" }
    if ($LASTEXITCODE -ne 0) { Write-Warning "failed to create $($a.alias)" }
}

Write-Host ""
Write-Host "  Aliases now available:" -ForegroundColor Green
(& $ollama list) -split "`n" | Where-Object { $_ -match '^(qwen-coder|qwen38-|qwen-fim|NAME)' } | ForEach-Object { "    $_" }
