<#
.SYNOPSIS
    Hands an entire file-touching task to the local Qwen Code CLI, behind git safety rails.
.DESCRIPTION
    Every other script in this repo keeps the model on a leash: it returns text and a
    human applies it. This one does not - it lets Qwen edit files directly. So the
    rails, not the feature, are the point:

      - refuses to start on a dirty working tree (the review model is "read the diff
        afterwards", which is worthless if there were already changes mixed in)
      - works on a throwaway branch by default
      - NEVER commits; it prints the diff and the exact keep/abandon commands
      - the review reads index AND worktree, so staged changes cannot hide from it
      - records HEAD before the run and says so if it moved: this script never
        commits, but in -ApprovalMode auto or yolo the MODEL has a shell and can
        commit on its own
      - kills the run at -TimeoutSec and still reports whatever landed

    Be honest about latency. 487 seconds is the measured cost of the SMALLEST useful
    edit on the reference box (RTX 2060 SUPER 8GB, DDR4-2133) - treat it as a floor,
    not an estimate. A real multi-step agentic task on the same box ran past 1500 s
    without finishing and was killed by the timeout having changed nothing. Anything
    beyond a one-file touch-up wants a machine that fits the model in VRAM, which is
    the only condition under which handing over a whole task is comfortable.

    Approval mode: qwen 0.22.1 registers a --approval-mode flag with a validated
    choices list but hides it from --help. This script probes for it at run time and
    prefers it. -UseSettingsFile forces the older mechanism (a workspace-scoped
    .qwen/settings.json), which is backed up and restored around the run.
.EXAMPLE
    .\scripts\qwen-task.ps1 -Task 'Add a docstring to every function in src/parse.py'
.EXAMPLE
    .\scripts\qwen-task.ps1 -Task 'Rename foo to bar everywhere' -WorkDir C:\code\proj -TimeoutSec 900
.EXAMPLE
    .\scripts\qwen-task.ps1 -Task 'Sketch a refactor plan' -ApprovalMode plan
.NOTES
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.

    Works on a repository with no commits yet (a freshly 'git init'ed scratch
    directory is a normal way to use this); there the review lists staged and
    untracked files, because there is nothing to diff against.

    Writes one JSON object to stdout as the last thing it does:
      task, model, approvalMode, mechanism, workDir, branch, branchCreated,
      timedOut, exitCode, changedFiles, newFiles, committed
    changedFiles counts tracked paths git reports as modified, staged or not.
    committed is true only when the repository gained commits during the run,
    which this script never causes - it means the model did it from a shell.

    Exit code: 1 if the run timed out or qwen exited non-zero, otherwise 0.
    Unlike the other scripts here this one can leave a repository half-edited,
    so a wrapper or CI step has to be able to see that the run did not finish.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Task,
    [string]$Model = 'qwen-coder',
    [string]$WorkDir = '.',
    [ValidateSet('plan','default','auto-edit','auto','yolo')][string]$ApprovalMode = 'auto-edit',
    [int]$TimeoutSec = 3600,
    [switch]$NoBranch,
    [string]$Branch,
    [switch]$Force,
    [switch]$KeepSettings,
    # Force the settings-file mechanism even when the CLI flag is available.
    [switch]$UseSettingsFile
)

$ErrorActionPreference = 'Stop'
$api = 'http://127.0.0.1:11434'

$ollama = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
if (-not (Test-Path $ollama)) { $ollama = (Get-Command ollama -ErrorAction Stop).Source }

# ------------------------------------------------------------------ helpers --

function Backup-IfExists([string]$path) {
    if (Test-Path $path) {
        $bak = "$path.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $path $bak -Force
        Write-Host "    backed up existing -> $(Split-Path $bak -Leaf)" -ForegroundColor DarkGray
        return $bak
    }
    return $null
}

# PS 5.1's -Encoding UTF8 emits a BOM and qwen rejects a BOM'd settings file
# outright - it renames it to settings.json.corrupted and carries on with the
# defaults, so the approval mode silently does not apply.
function Write-Utf8NoBom([string]$path, [string]$text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $text, $enc)
}

function ConvertTo-Slug([string]$text, [int]$max = 40) {
    $s = $text.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $s = $s.Trim('-')
    if ($s.Length -gt $max) { $s = $s.Substring(0, $max).TrimEnd('-') }
    if (-not $s) { $s = 'task' }
    return $s
}

# Windows CommandLineToArgvW rules. Node parses its argv with these, so quoting
# here is what stops a task containing quotes from being silently truncated.
function ConvertTo-QuotedArg([string]$value) {
    if ($value -eq '') { return '""' }
    if ($value -notmatch '[\s"]') { return $value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $value.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') {
            [void]$sb.Append(('\' * (($slashes * 2) + 1)))
            [void]$sb.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$sb.Append(('\' * $slashes)); $slashes = 0 }
        [void]$sb.Append($ch)
    }
    if ($slashes -gt 0) { [void]$sb.Append(('\' * ($slashes * 2))) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-Git {
    param([string]$Root, [string[]]$Arguments, [switch]$AllowFail)
    $out = & git -C $Root @Arguments
    if ($LASTEXITCODE -ne 0 -and -not $AllowFail) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
    return $out
}

# Reads bytes appended since the last call. Opened share-ReadWrite so the child
# process can keep writing while we tail it.
#
# The caller passes a Decoder that lives for the whole run rather than a fresh
# Encoding.GetString per chunk. A poll boundary lands wherever the child happened to
# flush, so a multi-byte character is routinely split across two reads; a decoder
# carries the partial sequence forward, GetString turns both halves into U+FFFD.
function Read-Appended {
    param([string]$Path, [ref]$Position, [System.Text.Decoder]$Decoder)
    if (-not (Test-Path $Path)) { return '' }
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        if ($fs.Length -le $Position.Value) { return '' }
        [void]$fs.Seek($Position.Value, [System.IO.SeekOrigin]::Begin)
        $len = [int]($fs.Length - $Position.Value)
        $buf = New-Object byte[] $len
        $n = $fs.Read($buf, 0, $len)
        $Position.Value = $Position.Value + $n
        if ($n -le 0) { return '' }
        # flush:$false - hand any trailing partial sequence to the next call. GetChars
        # must run even when the chunk decodes to nothing, because GetCharCount does
        # not consume: only GetChars moves the leftover bytes into the decoder, and
        # skipping it on a zero-char chunk drops a split character's lead byte.
        $count = $Decoder.GetCharCount($buf, 0, $n, $false)
        $chars = New-Object char[] ($count + 1)
        $got   = $Decoder.GetChars($buf, 0, $n, $chars, 0, $false)
        if ($got -le 0) { return '' }
        return (New-Object string ($chars, 0, $got))
    } finally { $fs.Dispose() }
}

# git is quiet on success here and silent on failure thanks to --quiet, so no stderr
# redirect is needed - and on 5.1 a redirect is exactly what would break it.
function Test-HasCommits([string]$Root) {
    & git -C $Root rev-parse --verify --quiet HEAD | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# --------------------------------------------------------------- preflight ---

Write-Host ''
Write-Host '  qwen-task - preflight' -ForegroundColor Cyan

if (-not (Test-Path $WorkDir)) { throw "WorkDir does not exist: $WorkDir" }
$workPath = (Resolve-Path $WorkDir).Path

if (-not (Get-Command git -ErrorAction Ignore)) {
    throw 'git is not on PATH. This script has no safety net without it.'
}

# No 2>$null. On Windows PowerShell 5.1 redirecting a native command's stderr turns it
# into an ErrorRecord, which $ErrorActionPreference='Stop' promotes to a terminating
# NativeCommandError - so the guidance below would never print and the user would get a
# git stack trace instead. Unredirected, git's own "fatal:" line goes straight to the
# console and $LASTEXITCODE is left for us to test. Invoke-Git works for the same reason.
$repoRoot = & git -C $workPath rev-parse --show-toplevel
if ($LASTEXITCODE -ne 0 -or -not $repoRoot) {
    throw "$workPath is not inside a git repository. Refusing to let a model edit files with no way to undo it. Fix: git init, or point -WorkDir at a repo."
}
$repoRoot = ($repoRoot | Select-Object -First 1).Trim() -replace '/', '\'
Write-Host "    repo       : $repoRoot" -ForegroundColor DarkGray
Write-Host "    workdir    : $workPath" -ForegroundColor DarkGray

# qwen ships as an npm shim. Resolving the node entry point instead of the .cmd
# means the PID we may have to kill IS the model process, not a cmd.exe wrapper.
$qwenCmd = Get-Command qwen -All -ErrorAction Ignore |
           Where-Object { $_.CommandType -eq 'Application' -and $_.Source -like '*.cmd' } |
           Select-Object -First 1
if (-not $qwenCmd) {
    throw 'Qwen Code CLI not found on PATH. Fix: npm install -g @qwen-code/qwen-code (needs Node >= 22).'
}
$entry = Join-Path (Split-Path $qwenCmd.Source -Parent) 'node_modules\@qwen-code\qwen-code\cli-entry.js'
$node  = Get-Command node -ErrorAction Ignore
if ((Test-Path $entry) -and $node) {
    $exePath   = $node.Source
    $argPrefix = ConvertTo-QuotedArg $entry
} else {
    # Fallback: the shim. Works, but a timeout kill has to take out the whole tree.
    $exePath   = $qwenCmd.Source
    $argPrefix = ''
}
Write-Host "    qwen       : $($qwenCmd.Source)" -ForegroundColor DarkGray

try {
    $tags = Invoke-RestMethod -Uri "$api/api/tags" -TimeoutSec 15
} catch {
    throw "Ollama is not answering at $api. Fix: start the server explicitly with '$ollama' serve - the tray app does not always do it."
}
$installed = @($tags.models | ForEach-Object { $_.name })
$wanted    = $Model
if ($wanted -notmatch ':') { $wanted = $Model + ':latest' }
if (($installed -notcontains $wanted) -and ($installed -notcontains $Model)) {
    throw "Model '$Model' is not installed. Installed: $($installed -join ', '). Fix: run scripts\pull-models.ps1 then scripts\create-modelfiles.ps1."
}
Write-Host "    model      : $Model" -ForegroundColor DarkGray

# Folder trust silently downgrades any approval mode back to 'default', which then
# blocks forever waiting for a prompt non-interactive mode cannot answer.
$userSettings = Join-Path $env:USERPROFILE '.qwen\settings.json'
if (Test-Path $userSettings) {
    try {
        $us = Get-Content $userSettings -Raw | ConvertFrom-Json
        if ($us.security -and $us.security.folderTrust -and $us.security.folderTrust.enabled) {
            Write-Host '    WARNING: security.folderTrust is enabled in ~/.qwen/settings.json.' -ForegroundColor Yellow
            Write-Host '             An untrusted folder forces approval mode back to "default" and the run will hang.' -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    note: could not parse $userSettings - $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

# ------------------------------------------------------------- dirty tree ----

$dirty = @(Invoke-Git -Root $repoRoot -Arguments @('status', '--porcelain'))
if ($dirty.Count -gt 0) {
    if (-not $Force) {
        Write-Host ''
        Write-Host '  Refusing to run: the working tree is not clean.' -ForegroundColor Yellow
        Write-Host '  Reviewing this afterwards means reading the diff, and that only works when' -ForegroundColor Yellow
        Write-Host '  the whole diff is the model''s doing.' -ForegroundColor Yellow
        Write-Host ''
        $dirty | ForEach-Object { Write-Host "    $_" }
        Write-Host ''
        Write-Host '  Fix: commit or stash first, or re-run with -Force to accept a mixed diff.' -ForegroundColor Yellow
        throw 'Working tree is dirty.'
    }
    Write-Host "    -Force: proceeding with $($dirty.Count) pre-existing change(s) in the tree" -ForegroundColor Yellow
}

# ------------------------------------------------------------ approval mode --

if ($ApprovalMode -eq 'yolo') {
    Write-Host ''
    Write-Host '  ****************************************************************' -ForegroundColor Yellow
    Write-Host '  *  yolo: EVERY action is auto-approved, including shell        *' -ForegroundColor Yellow
    Write-Host '  *  commands the model decides to run. It is not limited to     *' -ForegroundColor Yellow
    Write-Host '  *  file edits, and git cannot undo what it does outside the    *' -ForegroundColor Yellow
    Write-Host '  *  repo. Use auto-edit unless you have a specific reason.      *' -ForegroundColor Yellow
    Write-Host '  ****************************************************************' -ForegroundColor Yellow
}

# The flag exists in 0.22.1 but is hidden from --help, so probe rather than trust a
# version number. Pairing it with mutually exclusive -p/-i guarantees a parse error
# on both branches, so the probe never starts a model call.
function Test-ApprovalFlag {
    $o = [System.IO.Path]::GetTempFileName()
    $e = [System.IO.Path]::GetTempFileName()
    try {
        $probe = @($argPrefix, '--approval-mode', '__probe__', '-p', 'x', '-i', 'y') |
                 Where-Object { $_ -ne '' }
        Start-Process -FilePath $exePath -ArgumentList ($probe -join ' ') -NoNewWindow -Wait `
                      -RedirectStandardOutput $o -RedirectStandardError $e | Out-Null
        $text = (Get-Content $o -Raw -ErrorAction Ignore) + (Get-Content $e -Raw -ErrorAction Ignore)
        return (($text -match 'approval-mode') -and ($text -match 'Invalid values'))
    } catch {
        return $false
    } finally {
        Remove-Item $o, $e -Force -ErrorAction Ignore
    }
}

$useFlag = $false
if (-not $UseSettingsFile) {
    Write-Host '    probing for --approval-mode support ...' -ForegroundColor DarkGray
    $useFlag = Test-ApprovalFlag
}
if ($useFlag) { $mechanism = 'CLI flag --approval-mode' }
else          { $mechanism = 'workspace .qwen/settings.json (tools.approvalMode)' }
Write-Host "    approval   : $ApprovalMode via $mechanism" -ForegroundColor DarkGray

$wsDir        = Join-Path $workPath '.qwen'
$wsFile       = Join-Path $wsDir 'settings.json'
$wsExisted    = Test-Path $wsFile
$wsDirCreated = $false
$wsBackup     = $null
$wsRestored   = $false

# Idempotent, and called from a finally, so an interrupted run cannot leave the
# workspace pinned in yolo mode.
function Restore-WorkspaceSettings {
    if ($script:useFlag -or $script:wsRestored) { return }
    $script:wsRestored = $true
    if ($KeepSettings) {
        Write-Host "    -KeepSettings: leaving $wsFile in place (approvalMode = $ApprovalMode)" -ForegroundColor Yellow
        return
    }
    # qwen renames a settings file it cannot parse, so clear that too or the
    # workspace keeps a stray file we are responsible for.
    Remove-Item "$wsFile.corrupted" -Force -ErrorAction Ignore
    if ($script:wsExisted -and $script:wsBackup -and (Test-Path $script:wsBackup)) {
        Copy-Item $script:wsBackup $wsFile -Force
        Remove-Item $script:wsBackup -Force -ErrorAction Ignore
        Write-Host '    restored the original workspace .qwen/settings.json' -ForegroundColor DarkGray
    } elseif (-not $script:wsExisted) {
        Remove-Item $wsFile -Force -ErrorAction Ignore
        if ($script:wsDirCreated) {
            $left = @(Get-ChildItem $wsDir -Force -ErrorAction Ignore)
            if ($left.Count -eq 0) { Remove-Item $wsDir -Force -ErrorAction Ignore }
        }
        Write-Host '    removed the temporary workspace .qwen/settings.json' -ForegroundColor DarkGray
    }
}

# The write itself lives inside the guarded block below, so nothing between here
# and the finally can leave a modified settings file behind.
function Set-WorkspaceApprovalMode {
    if ($script:useFlag) { return }
    if (-not (Test-Path $wsDir)) {
        New-Item -ItemType Directory -Force -Path $wsDir | Out-Null
        $script:wsDirCreated = $true
    }
    $script:wsBackup = Backup-IfExists $wsFile
    if ($script:wsExisted) {
        $ws = Get-Content $wsFile -Raw | ConvertFrom-Json
        if (-not $ws.PSObject.Properties['tools']) {
            $ws | Add-Member -NotePropertyName 'tools' -NotePropertyValue ([pscustomobject]@{})
        }
        if ($ws.tools.PSObject.Properties['approvalMode']) {
            $ws.tools.approvalMode = $ApprovalMode
        } else {
            $ws.tools | Add-Member -NotePropertyName 'approvalMode' -NotePropertyValue $ApprovalMode
        }
    } else {
        $ws = [ordered]@{ tools = [ordered]@{ approvalMode = $ApprovalMode } }
    }
    Write-Utf8NoBom $wsFile ($ws | ConvertTo-Json -Depth 12)
    Write-Host "    wrote $wsFile" -ForegroundColor DarkGray
}

# ----------------------------------------------------------------- branch ----

# A freshly 'git init'ed scratch directory handed a scaffolding task is a legitimate
# use of this tool, and there HEAD does not resolve: 'rev-parse --abbrev-ref HEAD'
# dies with "fatal: ambiguous argument 'HEAD'". symbolic-ref reads the branch name
# without needing a commit to point at.
$hasCommits = Test-HasCommits $repoRoot
if ($hasCommits) {
    $origBranch = (Invoke-Git -Root $repoRoot -Arguments @('rev-parse', '--abbrev-ref', 'HEAD') | Select-Object -First 1)
    $origHead   = (Invoke-Git -Root $repoRoot -Arguments @('rev-parse', 'HEAD') | Select-Object -First 1)
} else {
    $origBranch = (Invoke-Git -Root $repoRoot -Arguments @('symbolic-ref', '--short', 'HEAD') | Select-Object -First 1)
    $origHead   = $null
    Write-Host '    note: this repo has no commits yet, so there is nothing to diff against.' -ForegroundColor Yellow
    Write-Host '          The review will list staged and untracked files instead.' -ForegroundColor Yellow
}
$branchMade = $false
$branchName = $null

if ($NoBranch) {
    Write-Host "    branch     : staying on $origBranch (-NoBranch)" -ForegroundColor Yellow
} else {
    if ($Branch) { $branchName = $Branch } else { $branchName = 'qwen/' + (ConvertTo-Slug $Task) }
    $base = $branchName
    $n = 2
    while (@(Invoke-Git -Root $repoRoot -Arguments @('branch', '--list', $branchName) -AllowFail).Count -gt 0) {
        $branchName = "$base-$n"
        $n++
    }
    Invoke-Git -Root $repoRoot -Arguments @('checkout', '-b', $branchName) | Out-Null
    $branchMade = $true
    Write-Host "    branch     : $branchName (from $origBranch)" -ForegroundColor Green
}

# ------------------------------------------------------------- expectation ---

$benchFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'benchmark-results.json'
$tps = 0
if (Test-Path $benchFile) {
    try {
        $bench = Get-Content $benchFile -Raw | ConvertFrom-Json
        $row = $bench | Where-Object { $_.model -eq $Model -or $_.model -eq $wanted } | Select-Object -First 1
        if ($row -and $row.generationTps) { $tps = [double]$row.generationTps }
    } catch { $tps = 0 }
}

Write-Host ''
Write-Host '  Expect this to be slow.' -ForegroundColor Cyan
if ($tps -gt 0) {
    # An agentic edit is several turns of tool calls; ~3000 output tokens is a
    # realistic floor for one small file. A task touching more than one file, or one
    # the model has to explore first, runs many times longer than this.
    $mins = [math]::Round((3000 / $tps) / 60, 1)
    Write-Host "    $Model measured at $tps tok/s here -> $mins min is the FLOOR for one small single-file edit."
} else {
    Write-Host '    No benchmark-results.json yet - run scripts\benchmark.ps1 for a real number.'
    Write-Host '    Reference box (RTX 2060 SUPER 8GB, DDR4-2133): the smallest useful single-file'
    Write-Host '    edit took 487 s, and that is a floor.'
}
Write-Host '    Measured on that box: a real multi-step task ran past 1500 s and was killed by'
Write-Host '    the timeout having changed nothing. Budget accordingly.'
Write-Host '    A machine that fits the model entirely in VRAM is far faster, and that is the'
Write-Host '    only setup where handing over a whole task is comfortable.'
Write-Host "    Hard timeout: $TimeoutSec s."

# -------------------------------------------------------------------- run ----

$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$outFile = Join-Path $env:TEMP "qwen-task-$stamp.out.log"
$errFile = Join-Path $env:TEMP "qwen-task-$stamp.err.log"

$runArgs = @()
if ($argPrefix) { $runArgs += $argPrefix }
$runArgs += @('-m', (ConvertTo-QuotedArg $Model), '-o', 'text')
if ($useFlag) { $runArgs += @('--approval-mode', $ApprovalMode) }
$runArgs += @('-p', (ConvertTo-QuotedArg $Task))

$timedOut = $false
$exitCode = -1

try {
    Set-WorkspaceApprovalMode

    Write-Host ''
    Write-Host "  running qwen ($Model) ..." -ForegroundColor Cyan
    Write-Host ''

    $proc = Start-Process -FilePath $exePath -ArgumentList ($runArgs -join ' ') -WorkingDirectory $workPath `
                          -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    # Touching .Handle makes .NET keep the process handle open. Without it
    # ExitCode reads back empty once the child is gone, and a failed run is
    # indistinguishable from a clean one. WaitForExit() alone does not fix it.
    $null = $proc.Handle

    # One decoder per stream, held for the whole run - see Read-Appended.
    $outDec   = [System.Text.Encoding]::UTF8.GetDecoder()
    $errDec   = [System.Text.Encoding]::UTF8.GetDecoder()
    $outPos   = [long]0
    $errPos   = [long]0
    $started  = Get-Date
    $deadline = $started.AddSeconds($TimeoutSec)
    $lastBeat = $started

    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 400
        $spoke = $false
        $chunk = Read-Appended -Path $outFile -Position ([ref]$outPos) -Decoder $outDec
        if ($chunk) { Write-Host $chunk -NoNewline; $spoke = $true }
        $chunk = Read-Appended -Path $errFile -Position ([ref]$errPos) -Decoder $errDec
        if ($chunk) { Write-Host $chunk -NoNewline -ForegroundColor DarkGray; $spoke = $true }

        # qwen buffers a plain-text run until it finishes, so without a heartbeat
        # a perfectly healthy 8-minute edit is indistinguishable from a hang.
        $now = Get-Date
        if ($spoke) { $lastBeat = $now }
        elseif (($now - $lastBeat).TotalSeconds -ge 15) {
            $lastBeat = $now
            $el = [int]($now - $started).TotalSeconds
            Write-Host "    ... still running, ${el}s elapsed of $TimeoutSec s" -ForegroundColor DarkGray
        }

        if ($now -gt $deadline) {
            $timedOut = $true
            Write-Host ''
            Write-Host "  TIMEOUT after $TimeoutSec s - killing the process tree." -ForegroundColor Yellow
            # /T because the shim fallback path leaves node as a child of cmd.exe.
            & taskkill /PID $proc.Id /T /F 2>&1 | Out-Null
            [void]$proc.WaitForExit(10000)
            break
        }
    }

    # Drain whatever landed between the last poll and exit.
    $chunk = Read-Appended -Path $outFile -Position ([ref]$outPos) -Decoder $outDec
    if ($chunk) { Write-Host $chunk -NoNewline }
    $chunk = Read-Appended -Path $errFile -Position ([ref]$errPos) -Decoder $errDec
    if ($chunk) { Write-Host $chunk -NoNewline -ForegroundColor DarkGray }

    # A process killed through taskkill can come back with a null ExitCode, so
    # leave the sentinel rather than reporting a fake success.
    if ($proc.HasExited -and $null -ne $proc.ExitCode) { $exitCode = [int]$proc.ExitCode }
} finally {
    Write-Host ''
    Restore-WorkspaceSettings
}

if ($timedOut) {
    Write-Host "  qwen was killed at the timeout. What follows is PARTIAL state." -ForegroundColor Yellow
} elseif ($exitCode -lt 0) {
    Write-Host '  qwen exited but the exit code could not be read. What follows may be partial.' -ForegroundColor Yellow
} elseif ($exitCode -ne 0) {
    Write-Host "  qwen exited with code $exitCode. What follows may be partial." -ForegroundColor Yellow
} else {
    Write-Host '  qwen finished.' -ForegroundColor Green
}
Write-Host "  logs: $outFile" -ForegroundColor DarkGray

# ----------------------------------------------------------------- review ----

# This script never commits, but in auto/yolo mode the model has a shell and can.
# Establish that BEFORE the banner, so the banner is never a lie.
$headMoved  = $false
$newHead    = $null
$newCommits = @()
if ($hasCommits) {
    $newHead = (Invoke-Git -Root $repoRoot -Arguments @('rev-parse', 'HEAD') -AllowFail | Select-Object -First 1)
    if ($newHead -and $origHead -and ($newHead -ne $origHead)) {
        $headMoved  = $true
        $newCommits = @(Invoke-Git -Root $repoRoot -Arguments @('log', '--oneline', "$origHead..$newHead") -AllowFail)
    }
} elseif (Test-HasCommits $repoRoot) {
    # Started with no commits and has some now.
    $headMoved  = $true
    $newCommits = @(Invoke-Git -Root $repoRoot -Arguments @('log', '--oneline') -AllowFail)
}

Write-Host ''
Write-Host '  ------------------------------------------------------------------'
if ($headMoved) {
    Write-Host '  THE MODEL COMMITTED DURING THIS RUN. This script never does.' -ForegroundColor Yellow
} else {
    Write-Host '  NOTHING HAS BEEN COMMITTED. Review the diff before you keep it.' -ForegroundColor Cyan
}
Write-Host '  ------------------------------------------------------------------'

if ($headMoved) {
    Write-Host ''
    Write-Host '  commits made during the run:' -ForegroundColor Yellow
    $newCommits | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    if ($origHead) {
        Write-Host "    undo with: git -C '$repoRoot' reset --mixed $origHead" -ForegroundColor Yellow
    }
    Write-Host '    The diff below is what is STILL uncommitted - it does not include those.' -ForegroundColor Yellow
}

# Bare 'git diff' compares the worktree against the INDEX, so anything staged reads
# as no change at all. That is reachable two ways: -Force over a tree that already
# had staged content, and any auto/yolo run where the model itself runs 'git add'.
# Either way the banner above would be printed over an empty review and the "Keep it"
# recipe below would then commit content the user was never shown. status --porcelain
# is the only view that sees index and worktree at once, so it drives the file list.
$status   = @(Invoke-Git -Root $repoRoot -Arguments @('status', '--porcelain') -AllowFail)
$changed  = @($status | Where-Object { $_ -notmatch '^\?\?' })
$newFiles = @(Invoke-Git -Root $repoRoot -Arguments @('ls-files', '--others', '--exclude-standard') -AllowFail)

Write-Host ''
Write-Host '  changed tracked files (staged and unstaged):' -ForegroundColor Cyan
if ($changed.Count -gt 0) { $changed | ForEach-Object { Write-Host "    $_" } }
else { Write-Host '    (none)' -ForegroundColor DarkGray }

# git diff does not show untracked files, so a model that only ADDED files would
# otherwise look like it did nothing at all.
Write-Host ''
Write-Host '  new untracked files:' -ForegroundColor Cyan
if ($newFiles.Count -gt 0) { $newFiles | ForEach-Object { Write-Host "    $_" } }
else { Write-Host '    (none)' -ForegroundColor DarkGray }

# 'diff HEAD' covers staged and unstaged together. With no commits HEAD does not
# resolve, and there nothing can be tracked-but-uncommitted, so --cached is the
# equivalent view.
if ($hasCommits) { $diffArgs = @('diff', 'HEAD') } else { $diffArgs = @('diff', '--cached') }
$diff = @(Invoke-Git -Root $repoRoot -Arguments $diffArgs -AllowFail)
if ($diff.Count -gt 0) {
    Write-Host ''
    Write-Host '  full diff:' -ForegroundColor Cyan
    $diff | ForEach-Object { Write-Host "    $_" }
}

Write-Host ''
Write-Host '  Keep it:' -ForegroundColor Green
Write-Host "    git -C '$repoRoot' add -A"
Write-Host "    git -C '$repoRoot' commit -m '<what it actually did>'"
Write-Host ''
Write-Host '  Abandon it:' -ForegroundColor Yellow
Write-Host "    git -C '$repoRoot' checkout -- ."
Write-Host "    git -C '$repoRoot' clean -fd        # deletes ALL untracked files - check the list above first"
if ($branchMade) {
    Write-Host "    git -C '$repoRoot' checkout $origBranch"
    Write-Host "    git -C '$repoRoot' branch -D $branchName"
}
Write-Host ''

$summary = [ordered]@{
    task          = $Task
    model         = $Model
    approvalMode  = $ApprovalMode
    mechanism     = $mechanism
    workDir       = $workPath
    branch        = $(if ($branchMade) { $branchName } else { $origBranch })
    branchCreated = $branchMade
    timedOut      = $timedOut
    exitCode      = $exitCode
    changedFiles  = $changed.Count
    newFiles      = $newFiles.Count
    # This script never commits, so true here means the model did it from a shell.
    committed     = $headMoved
}
$summary | ConvertTo-Json -Depth 4 | Write-Output

# Every other script here can end silently because the worst it leaves behind is a
# config file. This one can leave a repository half-edited, so a wrapper or CI step
# must be able to see that the model was killed or bailed out.
if ($timedOut -or $exitCode -ne 0) { exit 1 }
