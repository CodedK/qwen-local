<#
.SYNOPSIS
    Lists the local models ask-qwen.ps1 can target, with size and architecture family.
.DESCRIPTION
    Any tag printed here is valid for `ask-qwen.ps1 -Model`. Run it first on an
    unfamiliar machine - the alias set differs per hardware tier.

    Family matters more than size. qwen3moe activates ~3B params per token and
    stays usable even when most of it sits in system RAM; a dense family (qwen35,
    qwen2) collapses to a few tok/s the moment it spills out of VRAM.

    Size, family and context come from GET /api/tags. The human-readable MODIFIED
    column only exists in `ollama list`, so it is joined in when the binary is there.
.EXAMPLE
    .\qwen-models.ps1
.EXAMPLE
    .\qwen-models.ps1 -All -Json
#>
[CmdletBinding()]
param(
    [switch]$All,
    [switch]$Json,
    [string]$OllamaHost = 'http://127.0.0.1:11434'
)

$ErrorActionPreference = 'Stop'

$ollama = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
if (-not (Test-Path $ollama)) {
    $cmd = Get-Command ollama -ErrorAction Ignore
    if ($cmd) { $ollama = $cmd.Source } else { $ollama = $null }
}

try {
    $tags = Invoke-RestMethod -Uri "$OllamaHost/api/tags" -Method Get -TimeoutSec 15
} catch {
    Write-Host ''
    Write-Host "  Cannot reach Ollama at $OllamaHost" -ForegroundColor Red
    Write-Host '    The tray app does not always start the server (CLAUDE.md gotcha 4).' -ForegroundColor Yellow
    Write-Host '    Start it explicitly:  & "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" serve' -ForegroundColor Yellow
    Write-Host ''
    exit 3
}

# MODIFIED is rendered relative ("2 hours ago") only by the CLI, so join it in.
$modified = @{}
if ($ollama) {
    (& $ollama list) -split "`n" | Select-Object -Skip 1 | ForEach-Object {
        $col = $_ -split '\s{2,}'
        if ($col.Count -ge 4) { $modified[$col[0].Trim()] = $col[3].Trim() }
    }
}

$rows = @()
foreach ($m in $tags.models) {
    if (-not $All -and $m.name -notmatch 'qwen') { continue }
    $rows += [ordered]@{
        name     = $m.name
        sizeGB   = [math]::Round($m.size / 1GB, 1)
        family   = $m.details.family
        params   = $m.details.parameter_size
        quant    = $m.details.quantization_level
        maxCtx   = $m.details.context_length
        tools    = ($m.capabilities -contains 'tools')
        modified = $modified[$m.name]
    }
}
$rows = $rows | Sort-Object { $_.name }

if ($Json) {
    $rows | ConvertTo-Json -Depth 4
    exit 0
}

Write-Host ''
Write-Host "  Local models at $OllamaHost" -ForegroundColor Cyan
if ($rows.Count -eq 0) {
    Write-Host '    none matched. Run pull-models.ps1, or pass -All to see every tag.' -ForegroundColor Yellow
    Write-Host ''
    exit 0
}
$rows | ForEach-Object { [pscustomobject]$_ } | Format-Table -AutoSize
Write-Host '  tools=True is required for agentic file editing; MoE (qwen3moe) survives offloading.' -ForegroundColor DarkGray
Write-Host ''
