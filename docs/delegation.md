# Delegation

Three ways to hand work from Claude Code to the local Qwen stack, and the rule
that decides which one. All three talk to the same Ollama server the interactive
clients use; nothing leaves the machine.

---

## The design principle

**Claude owns the file edits. Qwen returns text.**

The local models are good enough to draft with and not reliable enough to let
loose on a working tree. Measured on this stack: a prompt asking for `ValueError`
produced `ZeroDivisionError`. Instruction drift on exact identifiers is normal at
this size, so the safe shape is - Qwen generates, Claude reads it, Claude applies
it.

`scripts/qwen-task.ps1` (option C) is the deliberate exception. It lets the model
edit files directly, which is exactly why it is the only one of the three wrapped
in git safety rails: dirty-tree refusal, a throwaway branch, no commits, and a
printed diff. The rails, not the feature, are the point.

---

## The three options

| | A - `ask-qwen.ps1` | B - `mcp/qwen-mcp` | C - `qwen-task.ps1` |
|---|---|---|---|
| **What it is** | A PowerShell script Claude shells out to | A zero-dependency MCP server exposing 3 native tools | A wrapper that drives the Qwen Code CLI |
| **Setup cost** | None. It is already in the repo | One command, then restart the client | Qwen Code CLI installed (Node >= 22) |
| **Who touches files** | Claude. Qwen only reads `-Files` | Claude. The server only reads `files[]` | **Qwen**, inside a git branch |
| **Latency** | One round trip: 10 s to 500 s or more | The same, minus the shell-out overhead | An agent loop: minutes, or never |
| **Best for** | Bulk, low-stakes, verify-by-inspection generation | The same work, when a tool surface beats a command line | Whole file-touching tasks you will review as a diff |
| **Machine** | Any | Any | Only where the model fits in VRAM |

Option A is the default. Option B is the same capability with better ergonomics,
and is the only one that works inside Cursor. Option C needs hardware.

---

## Option A - scripts/ask-qwen.ps1

The delegation primitive, and what the `delegate-to-qwen` skill drives. Qwen
never touches files here: it gets a prompt plus the contents of `-Files`, and
returns text.

### Invocation

Run it through PowerShell, one line per call. These work verbatim from the repo
root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\ask-qwen.ps1 -Prompt "Summarise what this script does in two sentences." -Files scripts\benchmark.ps1
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\ask-qwen.ps1 -Model qwen-coder -Files src\parser.py,src\loader.py -System "You write Google-style Python docstrings. Output only docstrings." -Prompt "For every public function in the attached files, write a Google-style docstring. Return FILE::FUNCTION on its own line followed by the docstring in triple quotes. Do not rewrite function bodies." -MaxTokens 2000 -OutFile .\docstrings.txt
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\ask-qwen.ps1 -Prompt "Explain this stack trace and name the likely cause." -Files logs\crash.txt -Model qwen-coder -NumCtx 16384 -Json > answer.json
```

`-Files` takes literal paths only - no wildcard expansion - as **one
comma-separated argument**. `powershell.exe -File` collapses `a.py,b.py` into a
single string, so the script splits on comma when the literal path does not
exist.

### Flags

| Flag | Default | Notes |
|---|---|---|
| `-Prompt` | required | The whole task, self-contained. Qwen sees no session history. |
| `-Model` | `$env:QWEN_DELEGATE_MODEL`, else `qwen38-9b` | A bare alias resolves to `<alias>:latest`. An unknown tag exits 4 and suggests the closest installed one. |
| `-Files` | none | Attached as fenced blocks ahead of a `--- TASK ---` marker; the prompt goes last. |
| `-System` | built in | A "script, not a chat window" system prompt. Override it to fix the role and output format. |
| `-MaxTokens` | 2048 | On a thinking model this is the **total** budget, and reasoning is spent first. |
| `-Temperature` | 0.2 | |
| `-TimeoutSec` | 900 | Raise it for the slow models. Lowering it does not make them faster. |
| `-MaxFileKB` | 256 | Per-file cap. An oversized file is skipped with a warning. |
| `-MaxTotalKB` | 0, meaning 4x `-MaxFileKB` | Whole-attachment budget. Busting it is a hard exit 2 naming the files that did not fit, never a silent truncation. |
| `-NumCtx` | unset | Unset routes to `/v1/chat/completions`. Any value routes to `/api/chat`, the only endpoint that honours it. |
| `-OllamaHost` | `http://127.0.0.1:11434` | |
| `-OutFile` | none | Also writes the answer to a file, UTF-8 with no BOM. Missing parent directories are created. |
| `-Force` | off | Overwrite `-OutFile` without first copying it to `<path>.bak-<timestamp>`. |
| `-Json` | off | stdout carries the envelope instead of the bare answer: `model`, `content`, `reasoning`, `promptTokens`, `completionTokens`, `wallSeconds`, `tokensPerSec`. |
| `-IncludeReasoning` | off | Reasoning trace on stderr, or in `envelope.reasoning` under `-Json`. It never enters the answer. |

### The stream contract

This is what makes the script scriptable, so it is worth stating exactly:

```
stdout : the answer and nothing else (with -Json, the envelope and nothing else)
stderr : every status line, warning, error and reasoning trace
```

The answer is written as raw UTF-8 **bytes** to the OS stdout handle, bypassing
the PowerShell pipeline. Capture it with OS-level redirection:

```powershell
powershell.exe -NoProfile -File scripts\ask-qwen.ps1 -Prompt "..." > answer.txt
```

`$x = & .\scripts\ask-qwen.ps1 ...` does **not** capture it, and `| Out-Null`
does not suppress it. If the caller is itself PowerShell it re-decodes the
child's stdout through its own `[Console]::OutputEncoding` - set that to UTF-8 in
the caller, or redirect at the OS level.

### Exit codes

Check them. A local model failing is ordinary, not exceptional.

| Code | Meaning |
|---|---|
| 0 | ok |
| 2 | bad input: none of `-Files` attached, `-MaxTotalKB` busted, bad limit combination |
| 3 | Ollama unreachable |
| 4 | model not installed, or rejected by the server |
| 5 | timeout |
| 6 | API error, non-JSON reply, or an empty answer - including a budget spent entirely on reasoning |

### Prompt patterns that survive a small model

These apply equally to `ask_qwen` in option B. A 9B or 30B-A3B model is not a
frontier model, and the prompt shape is what closes most of the gap.

- **One task per call.** Two tasks in one prompt gets you one and a half.
- **Name exact identifiers.** Spell out the class, function, exception and module
  names. Do not let it infer them - that is precisely where it drifts.
- **State the output format explicitly**, separator included. It will not invent
  a parseable one.
- **Prefer "return only X".** Small models pad. "Return only the code, no
  explanation" removes a paragraph you would otherwise strip.
- **Attach files, do not describe them.** `-Files` is cheaper and more accurate
  than a prose summary of what is in them.
- **Keep context tight.** Long context costs throughput and raises the odds of
  spilling out of VRAM. Attach the two files that matter, not the directory.
- **Add negative constraints.** "Do not rename anything", "do not add imports",
  "do not modify function bodies" all measurably help.
- **Size the token budget to answer plus reasoning.** A clean latency cap on
  `qwen-coder`; on the Qwen3.8 models, setting it low buys an empty answer.

Then read the output before it touches a file. Every time.

### The skill

`.claude/skills/delegate-to-qwen/SKILL.md` carries the judgement layer: what is
worth delegating, how to write a prompt for a small model, and the arithmetic
that decides whether a call is worth its latency. Claude Code loads it on its own
when the work matches. This page is the reference; the skill is the policy.

`scripts/qwen-models.ps1` lists the tags installed on **this** machine. The tier
logic installs different sets on different boxes, so check it before naming a
model.

---

## Option B - mcp/qwen-mcp

The same capability as a native tool surface. Instead of shelling out per call
and pasting the output back, the agent calls `ask_qwen` the way it calls `Read`.
Zero dependencies, Node >= 18, newline-delimited JSON-RPC 2.0 over stdio.

### Registering it

```powershell
.\scripts\install-qwen-mcp.ps1
```

That resolves Node, enforces >= 18, syntax-checks `index.js` with `node --check`,
then registers the server through `claude mcp add` in user scope. If the Claude
Code CLI is absent or that call fails, it merges the entry into `~/.claude.json`
instead - backing the file up first and re-parsing the result to prove it
survived. Nothing is ever blindly overwritten.

```powershell
.\scripts\install-qwen-mcp.ps1 -Scope project      # this repo only
.\scripts\install-qwen-mcp.ps1 -Force              # replace an existing entry
.\scripts\install-qwen-mcp.ps1 -Name qwen-local    # register under another name
.\scripts\install-qwen-mcp.ps1 -OllamaHost http://192.168.1.10:11434
```

Re-running is safe: an existing entry is left untouched unless `-Force`. It exits
**0** when the server is registered - whether it registered it now or found it
already there - and **1** when registration failed, the working config was
restored from the backup, and manual instructions were printed instead. A
precondition failure (no Node, Node < 18, missing server file, failed syntax
check) throws and exits non-zero on its own.

Then restart Claude Code, or run `/mcp`, and confirm with `claude mcp get qwen`.

Cursor reads the same entry shape from `~/.cursor/mcp.json`, or `.cursor/mcp.json`
inside a project. **The MCP server is the only sane route into Cursor:** its
backend is sandboxed and cannot reach `localhost:11434` at all, so a raw local
endpoint pasted into its settings will not work. See [clients.md](clients.md).

### The three tools

| Tool | Arguments | Returns |
|---|---|---|
| `ask_qwen` | `prompt` (required), `model`, `files[]`, `system`, `max_tokens`, `temperature`, `num_ctx`, `include_reasoning` | The model's text, plus a footer line carrying model, endpoint, token counts, wall time, rate and finish reason |
| `list_qwen_models` | none | JSON: every installed tag with size, family, architecture, quantization, trained context, estimated VRAM need and whether it fits this machine |
| `qwen_health` | none | JSON: reachability, Ollama version, default model, timeout, sandbox root, and every resident model with its GPU/CPU split |

Limits on `ask_qwen`: 20 files, 256 KB each, 1 MB total, text only. Paths resolve
against `QWEN_MCP_ROOT` - the server's cwd, which Claude Code sets to the project
directory - and are checked both lexically and after symlink resolution. Anything
that escapes is refused.

`num_ctx` routes the call to `/api/chat` for the same reason `ask-qwen.ps1` does:
the OpenAI-compatible endpoint silently drops it. That switch forces Ollama to
reload the model, so do not vary it call to call.

Generations are serialised - one GPU, one generation at a time, so a second
`ask_qwen` queues behind the first. Nothing else queues: `ping`, `tools/list`,
`qwen_health` and `list_qwen_models` answer immediately even mid-generation.
Measured: a `ping` answered at +0.58 s during a 111.78 s generation, so a client's
liveness probe cannot time out and declare the server dead.

### Environment

| Variable | Default | Meaning |
|---|---|---|
| `OLLAMA_HOST` | `http://127.0.0.1:11434` | A bare `host:port` is accepted. |
| `QWEN_MCP_MODEL` | `qwen-coder` | Model used when `ask_qwen` is called without one. |
| `QWEN_MCP_TIMEOUT` | `900` | Seconds before a generation is aborted. |
| `QWEN_MCP_ROOT` | the server's cwd | Root that `files[]` may not escape. |

### Testing it without a client

The server is just a process on stdio, so a pipe proves it. `qwen_health` is the
cheapest real call - it needs Ollama but loads no model:

```powershell
@(
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'
  '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"qwen_health","arguments":{}}}'
) | node mcp\qwen-mcp\index.js
```

Two frames come back: the handshake, then a `content[0].text` holding the health
JSON. Piping works because the server **drains before exiting** - closing stdin
waits for handlers still awaiting Ollama or the filesystem instead of killing
them. A handshake on its own only proves the process starts.

Errors arrive on two channels by design. Bad arguments are a JSON-RPC `-32602`.
Runtime trouble - Ollama down, unknown model, timeout, sandbox escape, empty
completion - comes back as a tool result with `isError: true` and text explaining
what to do, so the calling model can read it and adapt instead of just failing.

---

## Option C - scripts/qwen-task.ps1

The exception to the design principle: Qwen edits the files itself, through the
Qwen Code CLI. Read the rails before using it.

```powershell
.\scripts\qwen-task.ps1 -Task 'Add a docstring to every function in src/parse.py'
.\scripts\qwen-task.ps1 -Task 'Sketch a refactor plan' -ApprovalMode plan
.\scripts\qwen-task.ps1 -Task 'Rename foo to bar everywhere' -WorkDir C:\code\proj -TimeoutSec 900
```

### The git rails

- **Refuses to start on a dirty working tree** unless `-Force`. The review model
  is "read the diff afterwards", which is worthless with pre-existing changes
  mixed in.
- **Works on a throwaway branch** by default: `qwen/<slug-of-task>`, with `-2`,
  `-3` collision suffixes. `-NoBranch` stays put; `-Branch` names it explicitly.
- **Never commits.** The only mutating git call in the whole file is `checkout -b`.
- **The review reads index and worktree**, driven by `git status --porcelain` and
  `git diff HEAD`, so staged changes cannot hide from it.
- **Records HEAD before the run** and says so if it moved. The script never
  commits, so a moved HEAD means the model did it from its own shell - reachable
  in `-ApprovalMode auto` and `yolo`. It then prints the commit list and the exact
  `git -C <repo> reset --mixed <pre-run-sha>` needed to undo it.
- **Kills the process tree at `-TimeoutSec`** and still reports whatever landed.
- Ends by printing the keep recipe and the abandon recipe, including deleting the
  branch it created.

A repository with no commits yet is supported: the branch name comes from
`git symbolic-ref --short HEAD` and the review falls back to `git diff --cached`.

### Approval mode is a real flag

qwen 0.22.1 registers `--approval-mode` as a validated top-level flag and simply
omits it from `--help`. Proof:

```
qwen --approval-mode bogus -p hi
Invalid values: Argument: approval-mode, Given: "bogus", Choices: "plan", "default", "auto-edit", "auto", "yolo"
```

`argv.approvalMode` is consumed ahead of `settings.tools.approvalMode`, so the
flag wins. The script probes for it at run time with a call that cannot start a
model, and prefers it. `-UseSettingsFile` forces the older mechanism - a
workspace-scoped `.qwen/settings.json`, backed up and restored from a `finally`
block, written BOM-free. Whichever route was taken is reported in the summary's
`mechanism` field.

### Parameters

| Flag | Default | Notes |
|---|---|---|
| `-Task` | required, positional | |
| `-Model` | `qwen-coder` | Must be installed. `qwen38-9b` **cannot tool-call on this stack** - Ollama rejects its grammar with a 400. |
| `-WorkDir` | `.` | Must exist and be inside a git repo. |
| `-ApprovalMode` | `auto-edit` | `plan`, `default`, `auto-edit`, `auto`, `yolo` |
| `-TimeoutSec` | 3600 | |
| `-NoBranch` / `-Branch` | a new `qwen/<slug>` branch | Stay on the current branch, or name one explicitly. |
| `-Force` | off | Proceed on a dirty tree. |
| `-KeepSettings` | off | Leave the workspace settings file in place (settings-file mechanism only). |
| `-UseSettingsFile` | off | Force the settings-file mechanism. |

### Output

Human-readable progress on the host streams, then exactly one JSON object as the
final stdout write:

```json
{
  "task": "...", "model": "qwen-coder", "approvalMode": "auto-edit",
  "mechanism": "CLI flag --approval-mode", "workDir": "...",
  "branch": "qwen/add-a-docstring-to-every-function", "branchCreated": true,
  "timedOut": false, "exitCode": 0,
  "changedFiles": 2, "newFiles": 0, "committed": false
}
```

`changedFiles` counts tracked paths, staged and unstaged. `committed` is true
only when the repository gained commits during the run, which this script never
causes. The exit code is **1** if the run timed out, qwen exited non-zero, or the
exit code could not be read; **0** otherwise. Preflight refusals - missing or
non-git `-WorkDir`, unknown model, qwen not on PATH, Ollama unreachable, a dirty
tree without `-Force` - throw and therefore also exit 1.

### When this is a bad idea

Bluntly: on an 8-12 GB card, almost always.

One small single-file agentic edit measured **487 seconds** on the reference box.
That is the floor, not the average. A real multi-step task on the same machine
ran past 1500 s without finishing and was killed by the timeout having changed
nothing at all. You pay the full latency and get an empty diff.

Do not reach for option C for anything a person is waiting on, anything
security-sensitive, anything needing multi-turn judgement, or any task larger
than a one-file touch-up on a machine where the model does not fit in VRAM. Use
option A, read the text, apply it yourself: it is faster, and the failure mode is
a bad paragraph instead of a half-edited repository.

---

## Choosing by hardware

This is the section that actually decides which option to use. The reference box
is VRAM-starved, so its numbers are a floor, not a forecast.

| Usable VRAM | Model to use | Throughput | Which options |
|---|---|---|---|
| **< 8 GB** | `qwen38-9b`, short context only | Collapses as soon as the KV cache pushes it out of VRAM | **A only.** C is impractical. |
| **8-12 GB** | `qwen38-9b` at `num_ctx <= 16384` is the workhorse | **MEASURED:** `qwen38-9b` 43.4 tok/s @ ctx 8192 and 39.8 @ 16384. `qwen-coder` **13.5** @ ctx 32768 (69% CPU). `qwen38-27b` **1.39** @ ctx 16384, effectively unusable | A, plus B for ergonomics. **C costs about 487 s per small edit, MEASURED.** |
| **16-24 GB** | `qwen-coder`, fully resident | **PROJECTED:** a large speedup over 13.5 tok/s once nothing spills to system RAM. Not measured here | A, B, and C becomes reasonable. |
| **>= 24 GB** | the dense `qwen38-27b` fits entirely in VRAM | **PROJECTED:** roughly 30-45 tok/s, against 1.39 offloaded. Not measured here | All three. B and C both become genuinely pleasant. |

At >= 24 GB with **>= 64 GB of system RAM**, consider Qwen3-Coder-Next - 80B
total, 3B active, 52 GB at Q4. `detect-hardware.ps1` selects it automatically at
that tier.

**Only the 8-12 GB row is measured**, on the reference machine: RTX 2060 SUPER
8 GB, i7-7700, 64 GB DDR4-2133 dual-channel. **Every row below it is a projection
from the bandwidth model in [hardware-sizing.md](hardware-sizing.md), not a
measurement.** Do not quote a projection as a result.

Measure your own box instead. Two models, about a minute:

```powershell
.\scripts\benchmark.ps1 -Models qwen38-9b,qwen-coder
```

Omitting `-Models` benchmarks every qwen alias including `qwen38-27b`, which at
1.39 tok/s costs about two minutes on its own. Results land in
`benchmark-results.json`, which the skill reads before quoting any number.

---

## When not to delegate

Delegation pays only when the work is **bulk**, **low-stakes** and **verifiable
by inspection**. If any one of those is false, do it yourself.

- **A single small edit.** One round trip costs more than making the edit.
- **Anything needing multi-turn judgement.** Qwen has no memory between calls;
  the prompt must carry everything.
- **Anything you must re-verify token by token.** You paid the latency for
  nothing.
- **Architecture, API design, migration planning.**
- **Security-sensitive code:** auth, crypto, input validation, permissions.
- **Anything on a hot interactive path** where a person is waiting.

Rule of thumb: if the delegated task is smaller than the prompt you would have to
write to explain it, do it yourself.

---

## Troubleshooting

Failures specific to delegation. The general list is in
[troubleshooting.md](troubleshooting.md).

### Exit 3, or `qwen_health` reports unreachable

Ollama is not running. The tray app does not always spawn the server. Set any
`OLLAMA_*` variable **before** launching it - the server reads its environment at
start:

```powershell
Start-Process "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" -ArgumentList 'serve' -WindowStyle Hidden
curl http://127.0.0.1:11434/api/version
```

### Exit 4, model not found

The alias set differs per hardware tier. List what is actually installed:

```powershell
.\scripts\qwen-models.ps1
```

`ask-qwen.ps1` already names the closest installed tag in its error. A bare alias
resolves to `<alias>:latest`, so `-Model qwen-coder` is enough.

### Exit 5, or a call that never seems to return

Local generation is slow, and cold load is per model: ~7 s for `qwen38-9b` while
it is still resident, ~16-17 s once evicted, ~50 s for `qwen-coder` on a box where
it never stays resident. On an 8 GB card models are evicted between runs
constantly, so most calls pay a cold load. A model too large to stay resident pays
a full load on **every** call - batch many items into one call rather than making
many small ones. Raise `-TimeoutSec` or `QWEN_MCP_TIMEOUT` before assuming
something is broken.

### A model that "fits" is inexplicably slow

Lower `num_ctx` first. On Windows, overshooting VRAM does not fail: the WDDM
driver silently pages the excess over PCIe while `ollama ps` still reports
`100% GPU`. Measured on the reference box, `qwen38-9b` ran 39.8 tok/s at ctx
16384 and **0.2** at ctx 24576 - slower than at 32768, where Ollama honestly
offloads layers instead of thrashing.

`-NumCtx` on `ask-qwen.ps1` and `num_ctx` on `ask_qwen` are the dials. Both route
the call to `/api/chat`, because the OpenAI-compatible `/v1` endpoint **silently
drops the option** - confirmed by unloading the model and watching it reload at
the server default instead of the requested size.

### Never benchmark during a pull

A concurrent `ollama pull` dropped the same model from 22.7 tok/s to 0.3. Finish
downloads first, and never draw a performance conclusion from a machine that is
mid-pull.

### An empty answer, or exit 6

The thinking model spent the budget reasoning. `qwen38-9b` and `qwen38-27b`
generate reasoning tokens **before** any content, charged against `-MaxTokens` or
`max_tokens`, and 150-300 of them is normal even for a one-word answer. Too small
a budget therefore returns empty content with a full reasoning field.

Raise the budget, or switch to `qwen-coder`, which emits no reasoning at all
(measured `reasoning=null`) and is the only installed tag with `tools=true`.
Reasoning comes back separately either way - `message.reasoning` on `/v1`,
`message.thinking` on `/api/chat` - so `message.content` is clean and needs no
`<think>` stripping.

### A config file gets renamed `.corrupted`

`Set-Content -Encoding UTF8` emits a BOM on Windows PowerShell 5.1, and qwen
rejects a BOM'd `settings.json` outright: it renames the file
`settings.json.corrupted` and replaces it with defaults, silently dropping every
local provider. Confirmed in both directions on this machine.

Every script here writes JSON with
`[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))`
for exactly this reason. Do the same if you hand-edit a config - and check
`~/.qwen/` for a `.corrupted` file if your providers vanish.

---

| Also see | |
|---|---|
| [clients.md](clients.md) | The three interactive front-ends, and why Cursor needs the MCP server |
| [hardware-sizing.md](hardware-sizing.md) | The bandwidth math behind the projections above |
| [model-catalog.md](model-catalog.md) | Why the dense 27B is slower than the larger MoE |
| [troubleshooting.md](troubleshooting.md) | Every other failure hit while building this |
