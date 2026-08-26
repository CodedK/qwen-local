<#
.SYNOPSIS
    Downloads the Qwen model set chosen for this machine's tier.
.DESCRIPTION
    Reads hardware-profile.json (produced by detect-hardware.ps1) and pulls the
    recommended models. Pass -All to also grab the big uncensored dense model
    regardless of tier.

    Pulls are retried: Hugging Face intermittently hangs on the manifest fetch,
    which surfaces as a non-zero exit after a long "pulling manifest" spin.
.EXAMPLE
    .\pull-models.ps1
    .\pull-models.ps1 -Only 'hf.co/JonathanColetti/Qwen3.8-27B-Uncensored-GGUF:noMTP-Q4_K_M'
#>
[CmdletBinding()]
param(
    [string[]]$Only,
    [switch]$All,
    [int]$MaxAttempts = 3
)

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$log  = Join-Path $root 'logs\pull.log'
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null

# ollama.exe is NOT on PATH in shells that started before the installer ran.
$ollama = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
if (-not (Test-Path $ollama)) {
    $c = Get-Command ollama -ErrorAction Ignore
    if ($c) { $ollama = $c.Source } else { throw 'ollama.exe not found. Run install.ps1 first.' }
}

# ---- decide what to pull -----------------------------------------------------
$targets = @()
if ($Only) {
    $targets = $Only
} else {
    $profilePath = Join-Path $root 'hardware-profile.json'
    if (-not (Test-Path $profilePath)) {
        Write-Host '  hardware-profile.json missing - running detect-hardware.ps1' -ForegroundColor Yellow
        & (Join-Path $PSScriptRoot 'detect-hardware.ps1') -Quiet | Out-Null
    }
    $hw = Get-Content $profilePath -Raw | ConvertFrom-Json
    $targets = @($hw.recommended.agent, $hw.recommended.uncensored, $hw.recommended.autocomplete)

    if ($All) {
        $big = 'hf.co/JonathanColetti/Qwen3.8-27B-Uncensored-GGUF:noMTP-Q4_K_M'
        if ($targets -notcontains $big) { $targets += $big }
    }
}
$targets = $targets | Where-Object { $_ } | Select-Object -Unique

Write-Host ''
Write-Host '  Pulling:' -ForegroundColor Cyan
$targets | ForEach-Object { Write-Host "    - $_" }
Write-Host ''

# ---- pull with retries -------------------------------------------------------
$failed = @()
$index  = 0
foreach ($t in $targets) {
    $index++
    $ok = $false
    for ($attempt = 1; $attempt -le $MaxAttempts -and -not $ok; $attempt++) {
        "=== PULL START (attempt $attempt/$MaxAttempts) $t ===" | Tee-Object -FilePath $log -Append | Out-Null
        # item index first, then retry number only when actually retrying
        $suffix = if ($attempt -gt 1) { " (retry $($attempt - 1)/$($MaxAttempts - 1))" } else { '' }
        Write-Host ("  [{0}/{1}] {2}{3}" -f $index, $targets.Count, $t, $suffix) -ForegroundColor DarkCyan

        & $ollama pull $t 2>&1 | Tee-Object -FilePath $log -Append | Out-Null
        $code = $LASTEXITCODE

        if ($code -eq 0) {
            $ok = $true
            "=== PULL OK $t ===" | Tee-Object -FilePath $log -Append | Out-Null
            Write-Host "        ok" -ForegroundColor Green
        } else {
            "=== PULL FAILED (exit $code) $t ===" | Tee-Object -FilePath $log -Append | Out-Null
            Write-Host "        failed (exit $code)" -ForegroundColor Yellow
            if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds (5 * $attempt) }
        }
    }
    if (-not $ok) { $failed += $t }
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host '  FAILED after retries:' -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    Write-Host '  Re-run with -Only to retry just these.' -ForegroundColor DarkGray
} else {
    Write-Host '  All pulls succeeded.' -ForegroundColor Green
}

Write-Host ''
& $ollama list
