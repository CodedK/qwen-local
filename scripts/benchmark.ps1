<#
.SYNOPSIS
    Measures real generation speed and GPU/CPU split for installed Qwen models.
.DESCRIPTION
    Estimates from spec sheets are unreliable - actual throughput depends on how
    many layers Ollama managed to fit on the GPU. This runs a fixed prompt through
    each model and reports:

      - prompt eval rate (how fast it ingests context)
      - generation rate  (tokens/sec of output - the number you feel)
      - processor split  (what % ended up on GPU vs spilled to CPU)

    Results land in benchmark-results.json.
#>
[CmdletBinding()]
param(
    [string[]]$Models,
    [int]$MaxTokens = 160,
    [string]$Prompt = 'Write a Python function that merges two sorted lists into one sorted list. Return only the code.'
)

$ErrorActionPreference = 'Stop'
$api = 'http://127.0.0.1:11434'

$ollama = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
if (-not (Test-Path $ollama)) { $ollama = (Get-Command ollama -ErrorAction Stop).Source }

if (-not $Models -or $Models.Count -eq 0) {
    $Models = (& $ollama list) -split "`n" |
              ForEach-Object { ($_ -split '\s+')[0] } |
              Where-Object { $_ -match '^(qwen-coder|qwen38-)' }
}
if (-not $Models -or $Models.Count -eq 0) { throw 'No qwen aliases found. Run create-modelfiles.ps1 first.' }

$results = @()

foreach ($m in $Models) {
    Write-Host ""
    Write-Host "  benchmarking $m ..." -ForegroundColor Cyan

    $body = @{
        model  = $m
        prompt = $Prompt
        stream = $false
        options = @{ num_predict = $MaxTokens }
    } | ConvertTo-Json -Depth 5

    try {
        # First call also pays the model-load cost; that is intentional and reported.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r  = Invoke-RestMethod -Uri "$api/api/generate" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 1800
        $sw.Stop()
    } catch {
        Write-Warning "  $m failed: $($_.Exception.Message)"
        $results += [ordered]@{ model = $m; error = $_.Exception.Message }
        continue
    }

    # Ollama returns durations in nanoseconds.
    $genRate    = if ($r.eval_count       -and $r.eval_duration)        { [math]::Round($r.eval_count        / ($r.eval_duration        / 1e9), 1) } else { 0 }
    $promptRate = if ($r.prompt_eval_count -and $r.prompt_eval_duration) { [math]::Round($r.prompt_eval_count / ($r.prompt_eval_duration / 1e9), 1) } else { 0 }
    $loadSec    = if ($r.load_duration)  { [math]::Round($r.load_duration / 1e9, 1) } else { 0 }

    # `ollama ps` is the only place the GPU/CPU split is exposed.
    $psLine = (& $ollama ps) -split "`n" | Where-Object { $_ -match [regex]::Escape($m) } | Select-Object -First 1
    $split  = if ($psLine -match '(\d+%\s*/\s*\d+%\s*CPU/GPU|\d+%\s*(GPU|CPU))') { $matches[0] } else { 'unknown' }

    $results += [ordered]@{
        model          = $m
        generationTps  = $genRate
        promptTps      = $promptRate
        loadSeconds    = $loadSec
        tokensOut      = $r.eval_count
        processorSplit = $split
        wallSeconds    = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }

    Write-Host ("    generation : {0} tok/s" -f $genRate) -ForegroundColor Green
    Write-Host ("    prompt     : {0} tok/s" -f $promptRate)
    Write-Host ("    load       : {0} s" -f $loadSec)
    Write-Host ("    split      : {0}" -f $split)
}

$out = Join-Path (Split-Path $PSScriptRoot -Parent) 'benchmark-results.json'
$results | ConvertTo-Json -Depth 5 | Set-Content -Path $out -Encoding UTF8

Write-Host ""
Write-Host "  Saved to $out" -ForegroundColor DarkGray
$results | ForEach-Object { [pscustomobject]$_ } | Format-Table -AutoSize
