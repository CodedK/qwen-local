<#
.SYNOPSIS
    Registers an already-downloaded GGUF file as an Ollama model.
.DESCRIPTION
    Works around a real failure mode: `ollama pull hf.co/...` on a large model can
    download the blob to 100% and then die with "Error: context deadline exceeded"
    during the manifest/commit step. The blob is left complete and valid in
    ~/.ollama/models/blobs - only the manifest is missing.

    Rather than re-downloading 15+ GB, point this at the orphaned blob. Ollama
    hashes it, finds the digest already present, and deduplicates instead of
    copying, so this costs disk read time but no extra space.

    Also works for any GGUF you downloaded by hand from Hugging Face.
.EXAMPLE
    .\import-local-gguf.ps1 -GgufPath "$env:USERPROFILE\.ollama\models\blobs\sha256-dfd8..." -Alias qwen38-27b -NumCtx 16384
.EXAMPLE
    # Find orphaned blobs (downloaded but with no model pointing at them):
    .\import-local-gguf.ps1 -ListOrphans
#>
[CmdletBinding(DefaultParameterSetName = 'Import')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Import')][string]$GgufPath,
    [Parameter(Mandatory, ParameterSetName = 'Import')][string]$Alias,
    [Parameter(ParameterSetName = 'Import')][int]$NumCtx = 16384,
    [Parameter(ParameterSetName = 'Orphans')][switch]$ListOrphans
)

$ErrorActionPreference = 'Stop'

$ollama = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
if (-not (Test-Path $ollama)) { $ollama = (Get-Command ollama -ErrorAction Stop).Source }

if ($ListOrphans) {
    $blobDir = "$env:USERPROFILE\.ollama\models\blobs"
    Write-Host ''
    Write-Host '  Large blobs on disk (>1 GB):' -ForegroundColor Cyan
    Get-ChildItem $blobDir -File | Where-Object { $_.Length -gt 1GB } | ForEach-Object {
        $isGguf = $false
        try {
            $fs = [IO.File]::OpenRead($_.FullName); $b = New-Object byte[] 4
            $fs.Read($b, 0, 4) | Out-Null; $fs.Close()
            $isGguf = ([System.Text.Encoding]::ASCII.GetString($b) -eq 'GGUF')
        } catch { }
        [pscustomobject]@{
            Name = $_.Name.Substring(0, 24) + '...'
            GB   = [math]::Round($_.Length / 1GB, 2)
            GGUF = $isGguf
            Path = $_.FullName
        }
    } | Format-Table -AutoSize
    Write-Host '  Cross-check against `ollama list`; anything unaccounted for is importable.' -ForegroundColor DarkGray
    return
}

if (-not (Test-Path $GgufPath)) { throw "File not found: $GgufPath" }

# Confirm it really is a GGUF before handing it to Ollama - a truncated download
# has a plausible size but garbage magic bytes.
$fs = [IO.File]::OpenRead($GgufPath)
$magic = New-Object byte[] 4
$fs.Read($magic, 0, 4) | Out-Null
$fs.Close()
if ([System.Text.Encoding]::ASCII.GetString($magic) -ne 'GGUF') {
    throw "Not a GGUF file (bad magic bytes): $GgufPath"
}

$sizeGB = [math]::Round((Get-Item $GgufPath).Length / 1GB, 2)
Write-Host ("  Importing {0} GB -> alias '{1}' (num_ctx {2})" -f $sizeGB, $Alias, $NumCtx) -ForegroundColor Cyan
Write-Host '  Ollama must hash the file; on a slow disk this takes several minutes.' -ForegroundColor DarkGray

# Forward slashes avoid backslash-escaping ambiguity in the Modelfile parser.
$fromPath = $GgufPath -replace '\\', '/'

$modelfile = @"
# Imported from a local GGUF by import-local-gguf.ps1
FROM $fromPath

PARAMETER num_ctx $NumCtx
PARAMETER temperature 0.7
PARAMETER top_p 0.8
PARAMETER top_k 20
PARAMETER repeat_penalty 1.05
"@

$tmp = Join-Path $env:TEMP "$Alias.import.Modelfile"
Set-Content -Path $tmp -Value $modelfile -Encoding UTF8

& $ollama create $Alias -f $tmp
if ($LASTEXITCODE -ne 0) { throw "ollama create failed with exit $LASTEXITCODE" }

Write-Host ''
Write-Host "  Created '$Alias'." -ForegroundColor Green
& $ollama list | Select-String -Pattern "^($Alias|NAME)"
