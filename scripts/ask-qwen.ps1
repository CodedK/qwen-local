<#
.SYNOPSIS
    Sends a prompt, optionally with file context, to a local Qwen model and prints the answer.
.DESCRIPTION
    The delegation primitive. Claude Code shells out to this script, Qwen does the
    bulk generation locally, Claude reviews the text and applies any edit itself.
    Qwen never touches files here.

    STREAM CONTRACT - the reason this script is shaped the way it is:
      stdout : the answer and nothing else (with -Json, the envelope and nothing else)
      stderr : every status line, warning and error
    Write-Host would land on stdout when a caller redirects the process, so status
    goes through Write-Status instead. It keeps the repo's two-space coloured style
    but writes to the error stream. So this is safe:
      powershell.exe -NoProfile -File ask-qwen.ps1 -Prompt '...' > answer.txt

    ENCODING - Windows PowerShell 5.1 corrupts non-ASCII in three separate
    places, so all three are handled explicitly rather than left to defaults:
      1. Ollama answers with "Content-Type: application/json" and NO charset, and
         PS 5.1 then decodes the body as latin-1. Invoke-WebRequest is used and
         the raw response bytes are decoded as UTF-8 by hand.
      2. A -Body string is encoded as latin-1 on the way out, so the request is
         sent as UTF-8 bytes.
      3. [Console]::Out encodes through [Console]::OutputEncoding, which is
         IBM437 on a default box. The answer goes to the raw stdout handle as
         UTF-8 bytes, and -OutFile is written with UTF8Encoding($false) because
         Set-Content -Encoding UTF8 emits a BOM.

    Qwen3.8 is a thinking model. The OpenAI-compatible shim puts reasoning in a
    separate message.reasoning field, so message.content is already clean and no
    <think> stripping is needed. Reasoning tokens are still billed against
    -MaxTokens, which is the most common cause of an empty answer.

    -Files accepts either a real array or one comma-joined string, because
    powershell.exe -File collapses "a.py,b.py" into a single argument. Each file
    is capped at -MaxFileKB and the whole attachment set at -MaxTotalKB.

    Exit codes: 0 ok | 2 bad input | 3 Ollama unreachable | 4 model not found
                5 timeout | 6 API error or empty answer
.EXAMPLE
    .\ask-qwen.ps1 -Prompt 'Summarise what this script does in two sentences.' -Files scripts\benchmark.ps1
.EXAMPLE
    .\ask-qwen.ps1 -Prompt 'Draft NumPy docstrings for every function.' -Files a.py,b.py -Json
.EXAMPLE
    .\ask-qwen.ps1 -Prompt 'Explain this trace.' -Model qwen-coder -NumCtx 8192 -OutFile out.md
.EXAMPLE
    .\ask-qwen.ps1 -Prompt 'Review these.' -Files a.py,b.py,c.py -MaxTotalKB 2048 -OutFile review.md -Force
.NOTES
    Windows PowerShell 5.1 and PowerShell 7+.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Prompt,
    [string]$Model,
    [string[]]$Files,
    [string]$System,
    [int]$MaxTokens = 2048,
    [double]$Temperature = 0.2,
    [int]$TimeoutSec = 900,
    [int]$MaxFileKB = 256,
    [int]$MaxTotalKB = 0,
    [int]$NumCtx,
    [string]$OllamaHost = 'http://127.0.0.1:11434',
    [string]$OutFile,
    [switch]$Force,
    [switch]$Json,
    [switch]$IncludeReasoning
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # the progress bar renders to stdout

# The console encoder is IBM437 on a default Windows box, so a non-redirected run
# would render the answer as mojibake even though the bytes leaving stdout are
# UTF-8 (see Write-StdOut). Flipping it also flips the console code page, which
# outlives this process, so the original is put back before every exit.
$script:origOutEnc = $null
try {
    $script:origOutEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
} catch { $script:origOutEnc = $null }

function Restore-ConsoleEncoding {
    if ($script:origOutEnc) {
        try { [Console]::OutputEncoding = $script:origOutEnc } catch { }
        $script:origOutEnc = $null
    }
}

# -------------------------------------------------------------- plumbing -----
function Write-Status {
    param([string]$Text, [string]$Color = 'DarkGray')
    # Colour is set on the console directly and no-ops when stderr is redirected.
    try { [Console]::ForegroundColor = [ConsoleColor]$Color } catch { }
    [Console]::Error.WriteLine($Text)
    try { [Console]::ResetColor() } catch { }
}

$script:stdout = $null
function Write-StdOut {
    param([string]$Text)
    # Solves two problems at once. PowerShell's formatter hard-wraps long lines at
    # the host width and would mangle code, and [Console]::Out re-encodes through
    # the console code page. Raw UTF-8 bytes on the stdout handle dodge both. The
    # stream is cached because disposing it would close the handle.
    if (-not $script:stdout) { $script:stdout = [Console]::OpenStandardOutput() }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $script:stdout.Write($bytes, 0, $bytes.Length)
    $script:stdout.Flush()
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    # Set-Content -Encoding UTF8 emits a BOM on PS 5.1, which breaks a generated
    # shebang, a Python encoding line or anything else parsed from byte zero.
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Backup-IfExists {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $bak = "$Path.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $Path -Destination $bak -Force
        return $bak
    }
    return $null
}

function Get-Utf8Body {
    param($Response)
    # Ollama sends "Content-Type: application/json" with no charset, so PS 5.1
    # falls back to latin-1 and every non-ASCII character in the answer is lost
    # before we ever see it. The raw bytes are the only trustworthy copy.
    $stream = $Response.RawContentStream
    if ($stream) {
        $ms = New-Object System.IO.MemoryStream
        $stream.Position = 0
        $stream.CopyTo($ms)
        return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    }
    return [string]$Response.Content
}

function Stop-WithError {
    param([int]$Code, [string]$Message, [string[]]$Hints)
    Write-Status ''
    Write-Status "  ask-qwen: $Message" 'Red'
    foreach ($h in $Hints) { Write-Status "    $h" 'Yellow' }
    Write-Status ''
    Restore-ConsoleEncoding
    exit $Code
}

function Get-HttpErrorBody {
    param($Exception)
    # PS 5.1 does not surface the response body on a failed Invoke-RestMethod.
    try {
        $resp = $Exception.Response
        if (-not $resp) { return '' }
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $text   = $reader.ReadToEnd()
        $reader.Dispose()
        return $text
    } catch { return '' }
}

function Get-ClosestTag {
    param([string]$Want, [string[]]$Tags)
    # Longest common prefix plus a containment bonus. Crude, but a typo like
    # "qwen38-9" only ever needs one obvious suggestion.
    $w = $Want.ToLower()
    $best = $null
    $bestScore = 0
    foreach ($t in $Tags) {
        $c = $t.ToLower()
        $n = [math]::Min($w.Length, $c.Length)
        $i = 0
        while ($i -lt $n -and $w[$i] -eq $c[$i]) { $i++ }
        $score = $i
        if ($c.Contains($w)) { $score += 4 }
        if ($score -gt $bestScore) { $bestScore = $score; $best = $t }
    }
    if ($bestScore -ge 4) { return $best }
    return $null
}

# ollama.exe is only needed to enrich a "model not found" message, so a missing
# binary is not fatal here - the server may be on another host entirely.
$ollama = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
if (-not (Test-Path $ollama)) {
    $cmd = Get-Command ollama -ErrorAction Ignore
    if ($cmd) { $ollama = $cmd.Source } else { $ollama = $null }
}

# ----------------------------------------------------------------- model -----
if (-not $Model) { $Model = $env:QWEN_DELEGATE_MODEL }
if (-not $Model) { $Model = 'qwen38-9b' }

try {
    $tagResp = Invoke-RestMethod -Uri "$OllamaHost/api/tags" -Method Get -TimeoutSec 15
} catch {
    Stop-WithError 3 "cannot reach Ollama at $OllamaHost - $($_.Exception.Message)" @(
        'The tray app does not always start the server (CLAUDE.md gotcha 4).'
        'Start it explicitly:  & "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" serve'
        'Then confirm:         curl http://127.0.0.1:11434/api/version'
        'Set any OLLAMA_* env var BEFORE launching - the server reads them at start.'
    )
}

$tags = @($tagResp.models | ForEach-Object { $_.name })
$resolved = $null
if ($tags -contains $Model) {
    $resolved = $Model
} elseif ($tags -contains "${Model}:latest") {
    # Bare aliases are the ergonomic form; Ollama stores them tagged.
    $resolved = "${Model}:latest"
}

if (-not $resolved) {
    $listing = $tags
    if ($ollama) {
        # Shell out so the message shows exactly what `ollama list` would show.
        $listing = (& $ollama list) -split "`n" |
                   ForEach-Object { ($_ -split '\s+')[0] } |
                   Where-Object { $_ -and $_ -ne 'NAME' }
    }
    $hints = @()
    $near = Get-ClosestTag -Want $Model -Tags $tags
    if ($near) { $hints += "Closest installed tag: $near" }
    $hints += 'Installed tags:'
    foreach ($t in $listing) { $hints += "  - $t" }
    $hints += "Pull it with:  ollama pull $Model"
    Stop-WithError 4 "model '$Model' is not installed" $hints
}

# ----------------------------------------------------------------- files -----
$fence   = '```'
$langMap = @{
    '.ps1'  = 'powershell'; '.psm1' = 'powershell'; '.psd1' = 'powershell'
    '.py'   = 'python';     '.js'   = 'javascript'; '.mjs'  = 'javascript'
    '.ts'   = 'typescript'; '.tsx'  = 'tsx';        '.jsx'  = 'jsx'
    '.json' = 'json';       '.yml'  = 'yaml';       '.yaml' = 'yaml'
    '.md'   = 'markdown';   '.cs'   = 'csharp';     '.go'   = 'go'
    '.rs'   = 'rust';       '.java' = 'java';       '.kt'   = 'kotlin'
    '.c'    = 'c';          '.h'    = 'c';          '.cpp'  = 'cpp'
    '.hpp'  = 'cpp';        '.sh'   = 'bash';       '.bash' = 'bash'
    '.sql'  = 'sql';        '.html' = 'html';       '.css'  = 'css'
    '.scss' = 'scss';       '.xml'  = 'xml';        '.toml' = 'toml'
    '.ini'  = 'ini';        '.cfg'  = 'ini';        '.rb'   = 'ruby'
    '.php'  = 'php';        '.r'    = 'r';          '.lua'  = 'lua'
    '.tf'   = 'hcl';        '.cmd'  = 'bat';        '.bat'  = 'bat'
}

function Test-IsBinary {
    param([string]$Path)
    # A NUL byte in the head is the cheapest reliable tell for binary content.
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $n = [int][math]::Min(4096, $fs.Length)
        if ($n -le 0) { return $false }
        $buf = New-Object byte[] $n
        [void]$fs.Read($buf, 0, $n)
    } finally { $fs.Dispose() }
    return ($buf -contains 0)
}

# A per-file cap does not stop fifty small files from burying the instruction at
# the end of the prompt, so the set has its own budget. Left unset it tracks
# -MaxFileKB, which keeps one dial to turn for the common case.
if ($MaxTotalKB -le 0) { $MaxTotalKB = $MaxFileKB * 4 }
if ($MaxTotalKB -lt $MaxFileKB) {
    Stop-WithError 2 "-MaxTotalKB $MaxTotalKB is smaller than -MaxFileKB $MaxFileKB" @(
        'No single file could ever be attached under those limits.'
    )
}

$context    = New-Object System.Text.StringBuilder
$attached   = @()
$skipped    = @()
$overBudget = @()
$totalBytes = 0

# powershell.exe -File hands a comma-joined argument over as ONE string instead of
# an array, and -File is how a caller shells in. Split it back apart, but only when
# the literal path does not exist - a real path may legitimately contain a comma.
$requested = @()
foreach ($f in $Files) {
    if (-not $f) { continue }
    if ($f -match ',' -and -not (Test-Path -LiteralPath $f)) {
        $requested += ($f -split ',' | Where-Object { $_ })
    } else {
        $requested += $f
    }
}

foreach ($f in $requested) {
    $item = Get-Item -LiteralPath $f -ErrorAction Ignore
    if (-not $item) {
        $skipped += "$f (not found)"
        continue
    }
    if ($item.PSIsContainer) {
        $skipped += "$f (is a directory)"
        continue
    }
    $kb = [math]::Round($item.Length / 1KB, 1)
    if ($item.Length -gt ($MaxFileKB * 1KB)) {
        $skipped += "$f ($kb KB, over -MaxFileKB $MaxFileKB)"
        continue
    }
    if (Test-IsBinary $item.FullName) {
        # Tested before the budget so a binary blob is reported as binary rather
        # than blamed for busting a limit it was never going to count against.
        $skipped += "$f (binary)"
        continue
    }
    if (($totalBytes + $item.Length) -gt ($MaxTotalKB * 1KB)) {
        # Dropping this silently would hand the model a truncated context and get
        # a confident answer to a question it was never actually shown, so the
        # offenders are collected and the run fails below.
        $overBudget += "$f ($kb KB)"
        continue
    }

    # ReadAllText honours a BOM and falls back to UTF-8, which is what source is.
    $text = [System.IO.File]::ReadAllText($item.FullName)
    $lang = $langMap[$item.Extension.ToLower()]
    if (-not $lang) { $lang = '' }

    [void]$context.AppendLine("### File: $($item.FullName)")
    [void]$context.AppendLine("$fence$lang")
    [void]$context.AppendLine($text.TrimEnd())
    [void]$context.AppendLine($fence)
    [void]$context.AppendLine('')

    $attached   += $item.FullName
    $totalBytes += $item.Length
}

foreach ($s in $skipped) { Write-Status "  ! skipped $s" 'Yellow' }

if ($overBudget.Count -gt 0) {
    $hints = @("Budget is $MaxTotalKB KB and $([math]::Round($totalBytes/1KB,1)) KB was already attached.")
    $hints += 'Did not fit:'
    foreach ($o in $overBudget) { $hints += "  - $o" }
    $hints += 'Attach fewer files, or raise -MaxTotalKB.'
    Stop-WithError 2 "the attached files exceed -MaxTotalKB ($MaxTotalKB KB)" $hints
}

if ($Files -and $Files.Count -gt 0 -and $attached.Count -eq 0) {
    # Answering without the context that was explicitly asked for is a silent trap.
    Stop-WithError 2 'none of the -Files could be attached' @(
        'Every path was missing, a directory, binary, or over -MaxFileKB.'
        'Fix the paths or raise -MaxFileKB, then re-run.'
    )
}

if ($attached.Count -gt 0) {
    Write-Status ''
    Write-Status ("  attached {0} file(s), {1} KB of {2} KB budget" -f $attached.Count, [math]::Round($totalBytes/1KB,1), $MaxTotalKB) 'Cyan'
    foreach ($a in $attached) { Write-Status "    - $a" }
}

# --------------------------------------------------------------- request -----
$defaultSystem = @'
You are a local coding assistant invoked from a script, not a chat window.
- Return ONLY what was asked for. No preamble, no restatement, no sign-off.
- When asked for code, emit code and nothing else.
- Match the existing language, style and indentation of any file you are given.
- If the request cannot be answered from the given context, say so in one line.
'@
$sys = $System
if (-not $sys) { $sys = $defaultSystem }

$userContent = $Prompt
if ($attached.Count -gt 0) {
    # Context first, instruction last - the task is what the model should be
    # holding when it starts generating.
    $userContent = $context.ToString() + "--- TASK ---`n" + $Prompt
}

# Always two messages: ConvertTo-Json collapses a single-element array into a bare
# object in PS 5.1, which the API rejects.
$messages = @(
    [ordered]@{ role = 'system'; content = $sys },
    [ordered]@{ role = 'user';   content = $userContent }
)

if ($NumCtx -gt 0) {
    # Verified on Ollama 0.32.15: /v1/chat/completions silently DROPS num_ctx, so
    # offering it there would be a lie. The native endpoint is the only one that
    # honours it, and num_ctx is the first dial to turn when a model that "fits"
    # is slow (CLAUDE.md gotcha 1 - Windows pages VRAM instead of failing).
    $uri  = "$OllamaHost/api/chat"
    $body = [ordered]@{
        model    = $resolved
        messages = $messages
        stream   = $false
        options  = [ordered]@{
            num_ctx     = $NumCtx
            num_predict = $MaxTokens
            temperature = $Temperature
        }
    }
} else {
    $uri  = "$OllamaHost/v1/chat/completions"
    $body = [ordered]@{
        model       = $resolved
        messages    = $messages
        stream      = $false
        max_tokens  = $MaxTokens
        temperature = $Temperature
    }
}

$payload = $body | ConvertTo-Json -Depth 8
# PS 5.1 encodes a -Body string as latin-1, which corrupts any non-ASCII source
# file that was attached. Send bytes instead.
$payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)

Write-Status ''
Write-Status "  model $resolved  ->  $uri" 'Cyan'
Write-Status ("    max_tokens {0}  temp {1}  timeout {2}s" -f $MaxTokens, $Temperature, $TimeoutSec)
Write-Status '    waiting (a cold model pays its load time on the first call) ...'

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    # Invoke-RestMethod would parse the body for us but only after decoding it as
    # latin-1 (see Get-Utf8Body), and there is no way to talk it out of that. Take
    # the raw response instead. -UseBasicParsing keeps PS 5.1 off the IE parser,
    # which is not needed for JSON and is not always present.
    $resp = Invoke-WebRequest -Uri $uri -Method Post -Body $payloadBytes -ContentType 'application/json; charset=utf-8' -TimeoutSec $TimeoutSec -UseBasicParsing
    $sw.Stop()
} catch {
    $sw.Stop()
    $ex   = $_.Exception
    $msg  = $ex.Message
    $wall = [math]::Round($sw.Elapsed.TotalSeconds, 1)

    $isTimeout = $false
    if ($ex -is [System.Net.WebException] -and $ex.Status -eq [System.Net.WebExceptionStatus]::Timeout) { $isTimeout = $true }
    if ($msg -match 'timed out|timeout|canceled|cancelled') { $isTimeout = $true }

    if ($isTimeout) {
        $ctxHint = 'Lower -NumCtx (try -NumCtx 8192).'
        if ($NumCtx -le 0) { $ctxHint = 'Pass -NumCtx 8192 - the server default context may be forcing a spill.' }
        Stop-WithError 5 "timed out after ${wall}s on $resolved" @(
            'Expected on a dense model that does not fit in VRAM (28B dense measures ~1.4 tok/s on the reference box).'
            'Try -Model qwen38-9b (fastest) or -Model qwen-coder (MoE, still fast when offloaded).'
            $ctxHint
            'Overshooting VRAM makes Windows page over PCIe while ollama ps still claims 100% GPU.'
            'Raise -TimeoutSec only if the job is genuinely long.'
        )
    }

    $status = 0
    if ($ex.Response) { try { $status = [int]$ex.Response.StatusCode } catch { } }
    $detail = Get-HttpErrorBody $ex

    if ($status -eq 404 -or $detail -match 'not found' -or $msg -match 'not found') {
        Stop-WithError 4 "model '$resolved' was rejected by the server" @(
            "Server reported: $detail"
            'Run scripts\qwen-models.ps1 to see the installed tags.'
        )
    }

    Stop-WithError 6 "request failed after ${wall}s - $msg" @(
        "HTTP status: $status"
        "Server said: $detail"
    )
}

# -------------------------------------------------------------- response -----
try {
    $r = ConvertFrom-Json (Get-Utf8Body $resp)
} catch {
    Stop-WithError 6 "the reply from $uri was not valid JSON - $($_.Exception.Message)" @(
        'Something other than Ollama may be answering on that port.'
        "Confirm with:  curl $OllamaHost/api/version"
    )
}

if ($NumCtx -gt 0) {
    # Native shape: thinking lands in message.thinking, counts are *_count fields.
    $content    = $r.message.content
    $reasoning  = $r.message.thinking
    $promptTok  = [int]$r.prompt_eval_count
    $completTok = [int]$r.eval_count
    $finish     = $r.done_reason
} else {
    $choice     = $r.choices[0]
    $content    = $choice.message.content
    $reasoning  = $choice.message.reasoning
    $promptTok  = [int]$r.usage.prompt_tokens
    $completTok = [int]$r.usage.completion_tokens
    $finish     = $choice.finish_reason
}

$wall = [math]::Round($sw.Elapsed.TotalSeconds, 1)
$tps  = 0
if ($completTok -gt 0 -and $sw.Elapsed.TotalSeconds -gt 0) {
    # Wall clock, so a cold start drags this down. That is honest - it is what the
    # caller waited. benchmark.ps1 is the place for load-excluded numbers.
    $tps = [math]::Round($completTok / $sw.Elapsed.TotalSeconds, 1)
}

if (-not $content -or $content.Trim().Length -eq 0) {
    if ($reasoning -and $reasoning.Trim().Length -gt 0) {
        Stop-WithError 6 "the model spent its whole $MaxTokens-token budget thinking and returned no answer" @(
            'Qwen3.8 reasons before answering and reasoning counts against -MaxTokens.'
            "Raise -MaxTokens (try -MaxTokens $($MaxTokens * 4))."
            'Or use -Model qwen-coder, which emits no reasoning tokens.'
        )
    }
    Stop-WithError 6 "the model returned an empty answer (finish reason: $finish)" @(
        'Re-run with -IncludeReasoning to see what it was doing.'
        'A prompt with no actionable instruction is the usual cause.'
    )
}

if ($finish -eq 'length') {
    Write-Status "  ! truncated at $MaxTokens tokens - raise -MaxTokens for the full answer" 'Yellow'
}

if ($OutFile) {
    # .NET resolves a relative path against the process working directory, which is
    # not PowerShell's current location. Anchor it before handing it to WriteAllText.
    $outPath = $OutFile
    if (-not [System.IO.Path]::IsPathRooted($outPath)) {
        $outPath = Join-Path (Get-Location).ProviderPath $outPath
    }
    $outPath = [System.IO.Path]::GetFullPath($outPath)

    $dir = Split-Path $outPath -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    # A mistyped -OutFile must not silently destroy a file. -Force skips the copy.
    if (-not $Force) {
        $bak = Backup-IfExists $outPath
        if ($bak) { Write-Status "  backed up existing -> $(Split-Path $bak -Leaf)" }
    }

    # Set-Content -Encoding UTF8 emits a BOM on PS 5.1. This file is model output a
    # caller hands to a compiler or a JSON parser, both of which choke on one.
    $fileText = $content
    if (-not $fileText.EndsWith("`n")) { $fileText += [Environment]::NewLine }  # Set-Content used to add this
    Write-Utf8NoBom $outPath $fileText
    Write-Status "  wrote $outPath" 'Green'
}

Write-Status ''
Write-Status ("  {0} tok in / {1} tok out in {2}s  ({3} tok/s)" -f $promptTok, $completTok, $wall, $tps) 'Green'
Write-Status ''

if ($IncludeReasoning -and -not $Json -and $reasoning) {
    # Reasoning is commentary, not the answer, so it must not enter stdout.
    Write-Status '  --- reasoning ---' 'DarkCyan'
    foreach ($line in ($reasoning -split "`n")) { Write-Status "  $($line.TrimEnd())" }
    Write-Status ''
}

# Write-StdOut, not Write-Output and not [Console]::Out - see the function. The
# answer leaves as UTF-8 bytes, unwrapped, on the raw stdout handle.
if ($Json) {
    $shownReasoning = $null
    if ($IncludeReasoning) { $shownReasoning = $reasoning }
    $envelope = [ordered]@{
        model            = $resolved
        content          = $content
        reasoning        = $shownReasoning
        promptTokens     = $promptTok
        completionTokens = $completTok
        wallSeconds      = $wall
        tokensPerSec     = $tps
    }
    Write-StdOut (($envelope | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
} else {
    Write-StdOut ($content + [Environment]::NewLine)
}

Restore-ConsoleEncoding
exit 0
