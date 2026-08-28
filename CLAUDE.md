# CLAUDE.md — instructions for Claude Code working in this repo

**Purpose of this file: stop you from re-deriving what was already established.**
Everything below was measured or verified on real hardware. Treat it as fact and
do not re-research it with web searches. Only verify a claim if the user says
something contradicts it, or if a version number matters and may have moved.

---

## What this repo is

A reproducible local-Qwen coding stack for Windows: Ollama as the runtime, three
client front-ends, and models chosen automatically from the machine's hardware.
The goal is to move routine coding work off a metered cloud model. It also carries
the delegation layer Claude Code uses to hand bulk work to those models - see
"Delegating to Qwen from Claude Code" below.

## The fast path (do this first)

```powershell
git clone <this repo> $env:USERPROFILE\qwen-local
cd $env:USERPROFILE\qwen-local
.\scripts\install.ps1        # detects hardware, installs, pulls, configures
```

`install.ps1` is idempotent. If a user reports a problem, prefer re-running the
relevant single script over hand-rolling commands:

| Script | Job |
|---|---|
| `detect-hardware.ps1` | Profile the box, pick a tier, write `hardware-profile.json` |
| `pull-models.ps1` | Download the tier's models (has retries) |
| `create-modelfiles.ps1` | Build short tuned aliases |
| `configure-clients.ps1` | Write Qwen Code + Continue configs |
| `import-local-gguf.ps1` | Rescue a downloaded-but-uncommitted GGUF |
| `benchmark.ps1` | Measure real tok/s and GPU split |
| `ask-qwen.ps1` | The delegation primitive: prompt (+ files) in, answer text out |
| `qwen-models.ps1` | List the tags `ask-qwen.ps1 -Model` can target on THIS box |
| `qwen-task.ps1` | Hand a whole file-touching task to Qwen Code, behind git rails |
| `install-qwen-mcp.ps1` | Register `mcp/qwen-mcp` with Claude Code / Cursor |

`install.ps1` does **not** register the MCP server; that is a separate, explicit
step. The server itself is `mcp/qwen-mcp/index.js` - zero dependencies, Node 18+,
so there is nothing to `npm install`.

The Claude Code toolchain updater that used to live here
(`update-claude-stack.ps1`) has moved to its own repo, **claude-updater**, as a
cross-platform Python tool. It was never Qwen-specific. Don't re-add it here.

---

## Running this on a NEW machine

This is the common case: the user clones the repo on another PC and asks for the
same setup. Do this:

```powershell
cd <repo>

# Required once on a fresh machine, or every script fails with a security error:
# cloned files carry Windows' Mark of the Web and the default policy blocks them.
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
Get-ChildItem -Recurse *.ps1 | Unblock-File

.\scripts\install.ps1 -All      # -All also pulls the big uncensored dense model
```

Then confirm three things and report them:

1. `ollama list` shows the aliases (`qwen-coder`, `qwen38-9b`, and `qwen38-27b`
   if `-All` was used).
2. `.\scripts\benchmark.ps1` — report **measured** tok/s, never estimates.
3. Cline's one manual UI step (see below) — it cannot be scripted.

**Do not re-derive model choices.** `detect-hardware.ps1` picks the tier. If the
user wants both uncensored sizes (a common request), pass `-All`; the tier logic
only selects one.

**On a stronger machine, expectations change.** The reference box is VRAM-starved.
With >=24 GB VRAM the dense 27B fits entirely on the GPU and jumps from ~1.4 to
**41.2 tok/s - now MEASURED** on the RTX 3090 box below, landing inside the
30-45 band the bandwidth model predicted. The model is sound; still re-benchmark
on any new box rather than quoting either number.

### Status of each script

| Script | Verified |
|---|---|
| `detect-hardware.ps1` | Run, output confirmed correct |
| `pull-models.ps1` | Run, incl. retry path |
| `create-modelfiles.ps1` | Run on both boxes; `qwen-coder-next`, `qwen-fim` and the profile-derived contexts all built on the 3090 |
| `configure-clients.ps1` | Run on both boxes, configs verified BOM-less and parsing |
| `import-local-gguf.ps1` | Run twice, rescued a real orphaned blob on each box |
| `benchmark.ps1` | Run on all models on both boxes |
| `install.ps1` | Run end-to-end on both boxes, including the reordered steps and the `>=20 GB` tuning branch. **Unverified:** the `10-20 GB` branch, which no box here has |
| `ask-qwen.ps1` | Run live; all six exit codes fired, UTF-8 round-trip proved |
| `qwen-models.ps1` | Run |
| `qwen-task.ps1` | Run; findings reproduced first, fixed, then re-run |
| `install-qwen-mcp.ps1` | Run; both registration routes and the exit codes checked |
| `mcp/qwen-mcp/index.js` | Run over stdio; concurrency and stdin drain measured |

---

## Delegating to Qwen from Claude Code

**Design principle: Claude keeps control of file edits.** Qwen returns TEXT;
Claude reviews it and applies it. `qwen-task.ps1` is the one deliberate exception,
which is exactly why it is wrapped in git safety rails.

Three surfaces over the same models:

| Option | Surface | Reach for it when |
|---|---|---|
| A | `scripts/ask-qwen.ps1`, driven by the `delegate-to-qwen` skill | Default. Nothing to install, shelling out is fine |
| B | `mcp/qwen-mcp` - tools `ask_qwen`, `list_qwen_models`, `qwen_health` | You want native tool calls; register with `install-qwen-mcp.ps1` |
| C | `scripts/qwen-task.ps1` | Qwen has to touch the files itself. Throwaway branch, refuses a dirty tree, never commits |

**Delegation only pays for bulk, low-stakes, verify-by-inspection work** - a
docstring pass over many files, test scaffolds, log summarisation, boilerplate
translation. On one small edit the round trip plus the review Claude must do
anyway costs more than writing it directly. Never delegate on an interactive path.

`ask-qwen.ps1` writes the answer to the raw stdout handle rather than the
PowerShell pipeline, so capture it with OS-level redirection (`> file`,
`Start-Process -RedirectStandardOutput`), not `$x = & ask-qwen.ps1`.

Full detail on all three - flags, stream contract, exit codes, the git rails and
when each option is the wrong one: `docs/delegation.md`.

---

## Established facts — do NOT re-research these

### Architecture matters more than parameter count

- **Qwen3.8-27B is DENSE** (28B params, all active per token). It is *not* MoE.
  This is the single most important fact here. A dense model that does not fit
  in VRAM is bandwidth-bound and collapses to a few tok/s.
- **Qwen3-Coder-30B is MoE with 3B active** (A3B). It is *bigger on disk* than
  the dense 27B yet **runs ~5× faster** when both spill to RAM, because only
  ~1.5 GB of weights move per token.
- **Qwen3-Coder-Next is 80B total / 3B active**, 52 GB at Q4 — needs ≥64 GB RAM.
- Qwen3.8 uses **hybrid attention**: 48 of 64 layers are Gated DeltaNet (linear,
  constant recurrent state). Consequence: the KV cache stays small at long
  context, so context length is cheaper than on a normal transformer.
- Qwen3.8 is a **thinking model by default**. Reasoning tokens multiply latency;
  on a slow setup, disable thinking or lower `reasoning_effort`.

**Rule of thumb:** on any machine where the model won't fit in VRAM, prefer MoE
(A3B) over a dense model of similar size. Always.

### The speed formula

Generation is bandwidth-bound, not compute-bound:

```
tok/s  ≈  usable_RAM_bandwidth_GBs  /  GB_of_weights_read_per_token
```

- Dense model → weights read per token = the whole offloaded portion.
- MoE model → only the active experts (~3B params ≈ 1.5 GB at Q4).
- Usable bandwidth ≈ `channels × MT/s × 8 bytes × 0.75`.
- **Populated DIMM count is not channel count.** Consumer desktops run 4 sticks
  on 2 channels. `detect-hardware.ps1` parses `Win32_PhysicalMemory.DeviceLocator`
  for `ChannelX` labels instead of counting sticks.

### Measured on the reference machine

RTX 2060 SUPER (8 GB), i7-7700, 64 GB DDR4-2133 dual-channel (~25.6 GB/s usable):

| Model | Split | tok/s |
|---|---|---|
| `qwen38-9b` @ ctx 8192 | 100% GPU | **43.4** |
| `qwen38-9b` @ ctx 16384 | 100% GPU | **39.8** |
| `qwen38-9b` @ ctx 24576 | "100% GPU" (lying) | **0.2** |
| `qwen38-9b` @ ctx 32768 | 14% CPU / 86% GPU | 22.7 |
| `qwen-coder` (30B MoE) @ ctx 32768 | 69% CPU / 31% GPU | **13.5** |
| `qwen38-27b` (28B dense) @ ctx 16384 | 65% CPU / 35% GPU | **1.39** |

Two things to take from this table:

- The 30B **MoE** beats the 9B at ctx 32768 despite being 3× bigger and 69% on CPU.
- The 30B MoE is **~10× faster than the 28B dense** model at a nearly identical
  CPU split (69% vs 65%). Architecture dominates size.

**Pure bandwidth math underestimates the penalty.** Predicted 2.3 tok/s for the
dense 27B; measured 1.39. Apply a ~1.5-1.7× overhead factor for PCIe transfer and
sync when a model is heavily offloaded.

### Measured on the 24 GB machine

RTX 3090 (24 GB), Core Ultra 9 285K (24c/24t), 128 GB DDR5-4400 dual-channel
(~52.8 GB/s usable). Ollama 0.33.1, flash attention on, q8_0 KV cache.
**Desktop is drawn by the 3090** and holds 1.5 GB idle, up to ~4.3 GB busy.

| Model | Split | gen tok/s | prompt tok/s | load |
|---|---|---|---|---|
| `qwen-coder` (30B MoE) @ ctx 32768 | 100% GPU | **166.4** | 177.1 | 11.7 s |
| `qwen38-27b` (28B dense) @ ctx 32768 | 100% GPU | **41.2** | 331.5 | 7.9 s |
| `qwen-coder-next` (80B MoE) @ ctx 32768 | 57% CPU / 43% GPU | **41.1** | 5.6 | 41.1 s |

Against the 8 GB box: the 30B MoE went 13.5 -> 166.4 (12x), the dense 27B went
1.39 -> 41.2 (30x). Architecture stops mattering once everything fits: the dense
27B and the 80B MoE both land at ~41 tok/s by completely different routes.

**`qwen-coder-next`'s prompt eval is 5.6 tok/s** - 30x slower than the 30B's.
Prompt processing is compute-bound, so the 57% sitting on CPU dominates it. It is
fine for a short prompt and a long answer; it is painful for a long prompt. Reach
for it when you want the strongest local reasoning, not for bulk file context.

**Context is free on this card, VRAM headroom is not.** Measured on `qwen-coder`,
all 100% GPU: ctx 8192 -> 162.3 tok/s / 20990 MB, 16384 -> 167.6 / 21406,
24576 -> 164.3 / 21822, 32768 -> 165.4 / 22319. Throughput is flat across the
whole range, so there is no reason to run a short context - but each step costs
~450 MB of VRAM, and VRAM is what runs out.

**The paging trap was reproduced here, and the tell is PROMPT eval.** The very
first benchmark on this box returned **13.1 tok/s generation and 1.8 tok/s
prompt** for `qwen-coder`, while `ollama ps` cheerfully reported `100% GPU` at
ctx 32768. Nothing was wrong with the context: the desktop happened to be holding
~4.3 GB at that moment, pushing 22.3 GB of model past the 24.5 GB card. Re-run
with an idle desktop, the identical config gave 166 tok/s. Note the ratio -
generation fell 12x but prompt eval fell **98x** (177 -> 1.8). Generation is
bandwidth-bound so PCIe partly keeps up; prompt eval is compute-bound and
collapses completely. **If `ollama ps` says 100% GPU but prompt eval is in single
digits, you are paging - close things holding VRAM, do not touch num_ctx.**

The budget on a 24 GB card, measured: `qwen-coder` at ctx 32768 needs 20.4 GB and
`qwen-fim` at ctx 4096 needs 2.2 GB, so both resident leaves only ~1.9 GB for the
desktop. That works idle (1.5 GB) and pages when busy. `OLLAMA_MAX_LOADED_MODELS`
is set to 2 because keeping the FIM model resident avoids a ~12 s reload of the
agent on every autocomplete, and with both loaded the agent still measured
**169.9 tok/s / 823 tok/s prompt**. The real fix for the headroom, not applied
here because it is a hardware change: drive the displays from the Core Ultra's
integrated GPU and leave the 3090 entirely to compute.

### Agentic latency, measured

One small single-file edit via Qwen Code + `qwen-coder` (read file, reason, write
file) took **487 seconds**. Local agents are viable for background chores, not
for interactive back-and-forth. Set expectations accordingly — do not promise
Claude-like responsiveness.

Also observed: asked for `ValueError`, the model emitted `ZeroDivisionError`.
Instruction drift on exact identifiers is normal at this size; verify diffs.

### The Ollama API surface (verified on Ollama 0.32.15)

- **`/v1/chat/completions` silently drops `options.num_ctx`.** Confirmed by
  unloading the model and watching it reload at the server default 16384 after a
  request that asked for 4096 - no error, no warning. Honouring an explicit
  context size REQUIRES the native `/api/chat` endpoint. `ask-qwen.ps1 -NumCtx`
  and the MCP server's `num_ctx` both switch endpoint for this reason. Keep it
  that way; the OpenAI shim is fine only when you do not care about context size.
- Reasoning arrives in a **different field per endpoint**: `message.reasoning` on
  `/v1`, `message.thinking` on `/api/chat`. `message.content` is clean on both,
  so **no `<think>` stripping is ever needed.** Do not add any.

### Which tags think, and which can hold tools

- `qwen38-9b` and `qwen38-27b` are thinking models, and reasoning tokens are
  charged against `max_tokens` **before** any content is produced. Too small a
  budget therefore returns **empty content with a full reasoning field**, which
  looks like a broken API and is not. Budget 150-300 reasoning tokens per call
  even for a one-word answer.
- `qwen-coder` (30B MoE) emits none at all (measured `reasoning=null`) and is the
  **only installed tag with `tools=true`**.
- `qwen38-9b` **cannot do agentic tool-calling on this stack.** Ollama answers
  Qwen Code's tool grammar with
  `400 ... Failed to initialize samplers: failed to parse grammar`. `qwen-coder`
  is unaffected. **Use `qwen-coder` for anything agentic.**

### Cold load is per model, not a constant

~7s for `qwen38-9b` while it is still resident, ~16-17s once it has been evicted,
~50s for `qwen-coder`, which does not stay resident on an 8 GB card. Models get
evicted between calls here, so most calls pay a cold load on top of generation.
Batch delegated work into ONE call carrying several files instead of many small
calls; the load cost is paid per call, not per token.

### Qwen Code CLI: `--approval-mode` is real, just hidden

`--approval-mode` and `--yolo` are validated top-level flags in qwen 0.22.1 and
are merely OMITTED FROM `--help`. Proof: `qwen --approval-mode bogus -p hi` exits
1 with `Invalid values: Argument: approval-mode, Given: "bogus", Choices: "plan",
"default", "auto-edit", "auto", "yolo"`. `argv.approvalMode` is consumed AHEAD of
`settings.tools.approvalMode`, so the flag beats the settings key - it is the
primary mechanism, not a fallback. `qwen-task.ps1` probes for the flag at run time
and keeps the workspace-settings route behind `-UseSettingsFile` for older builds.
Working non-interactive form: `qwen -m <model> -p "<task>" [-o text]`.

---

## Gotchas that cost real debugging time

1. **Windows silently pages VRAM.** Overshoot VRAM and the WDDM driver spills to
   system RAM over PCIe instead of failing. `ollama ps` still reports
   `100% GPU` while throughput drops ~200×. If a model that "fits" is
   inexplicably slow, **lower `num_ctx` first.** This is the #1 trap. Lower it on
   `/api/chat` or in the Modelfile - a `num_ctx` sent to `/v1` is discarded.

   **`OLLAMA_GPU_OVERHEAD` is NOT the fix for this, on 0.33.1.** It looks like it
   should be, and the scheduler does honour it - the log prints
   `gpu memory available="2.3 GiB" free="22.8 GiB" overhead="20.0 GiB"`. But the
   llama.cpp auto-fit pass that runs afterwards (`LLAMA_ARG_FIT`, on by default)
   re-reads real device memory and overrides the decision: a 20 GiB reserve on a
   24 GiB card still offloaded 33/33 layers and reported 100% GPU. Measured on
   the RTX 3090 box. Worse, that fit pass sees ~2.6 GB MORE free VRAM than
   nvidia-smi reports and defaults to only a 1024 MiB margin, so it can end up
   with a negative real margin - which is the paging trap itself. Do not set
   `OLLAMA_GPU_OVERHEAD` from `vramFreeMB` either: that reading counts every
   consumer on the card, so it is not reproducible between runs (3840 MB and
   5120 MB on the same idle box, minutes apart). `LLAMA_ARG_FIT_TARGET` is the
   knob the fit pass actually reads - untested here, measure before trusting it.
2. **Never benchmark during a download.** A concurrent `ollama pull` dropped the
   same model from 22.7 tok/s to 0.3 tok/s. Always finish pulls first.
3. **`ollama` is not on PATH** in shells started before the installer ran.
   Scripts must resolve `$env:LOCALAPPDATA\Programs\Ollama\ollama.exe` directly.
4. **The Ollama tray app doesn't always start the server.** If
   `http://127.0.0.1:11434` refuses connections, launch `ollama.exe serve`
   explicitly. Set env vars *before* starting it — the server reads its
   environment at launch, and child processes inherit the parent's block, not
   the registry.
5. **Large HF pulls can die with `context deadline exceeded`** after reaching
   100%. The blob is complete and valid on disk; only the manifest is missing.
   Do **not** re-download — use `import-local-gguf.ps1`. Ollama dedupes by digest.
6. **Verify an HF tag before a long download:**
   `https://huggingface.co/v2/{repo}/manifests/{tag}` returns layer sizes. Costs
   one second and catches typos before 16 GB.
7. **Autocomplete needs a `-base` model**, not an instruct model. Base models are
   trained for fill-in-the-middle; instruct models emit chat prose into your file.
8. **`$profile` is a PowerShell automatic variable.** Never use it as a name.
9. **Windows PowerShell 5.1 corrupts text in three separate places.** All three
   bit a script in this repo, so treat them as defaults to override, not risks:
   - `Set-Content -Encoding UTF8` **emits a BOM** on 5.1. qwen rejects a BOM'd
     `settings.json` outright: it renames the file to `settings.json.corrupted`,
     writes 2 bytes of defaults in its place, and every local provider vanishes.
     Reproduced deliberately and restored from backup. Always write with
     `[System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding $false))`.
   - `Invoke-RestMethod` decodes a response as **latin-1** when the server sends
     `Content-Type: application/json` with no charset - which Ollama's shim does.
     Use `Invoke-WebRequest -UseBasicParsing` and decode `RawContentStream` as
     UTF-8 by hand. A `-Body` string is likewise encoded as latin-1 on the way
     out, so send request bodies as UTF-8 **bytes**.
   - `[Console]::Out.Write` encodes through `[Console]::OutputEncoding`, which is
     **IBM437** here, destroying anything outside that code page. Write the answer
     to the raw stdout handle as UTF-8 bytes instead.
10. **Cursor cannot reach `localhost:11434`.** Its backend is sandboxed, so a
    local model there needs a public HTTPS tunnel (cloudflared/ngrok) pasted into
    "Override OpenAI Base URL", Tab autocomplete stays locked to Cursor's
    proprietary Fusion model, and code transits Cursor's servers. Prefer
    Continue.dev, which talks to localhost directly and is already written by
    `configure-clients.ps1`. The **MCP server does work in Cursor** - that is the
    supported way to use these models there.

---

## Client configuration reference

| Client | Config location | Automatable? |
|---|---|---|
| Qwen Code CLI | `~/.qwen/settings.json` | Yes |
| Continue.dev | `~/.continue/config.yaml` | Yes |
| Cline | VS Code extension global state | **No** — UI only, one time |

- Ollama's OpenAI-compatible endpoint is `http://localhost:11434/v1`.
- The API key is required by clients but ignored by Ollama — any non-empty
  string works. Do not treat it as a secret and do not ask the user for one.
- Qwen Code schema: `modelProviders.openai[]`, `security.auth.selectedType`,
  `model.name`. Requires Node ≥ 22.
- VS Code extension IDs: Cline = `saoudrizwan.claude-dev`,
  Continue = `Continue.continue`.

## Working style in this repo

- Scripts target **Windows PowerShell 5.1 and PowerShell 7+** (5.1.19041.5794 is
  the machine default). Avoid PS7-only syntax so they run on an untouched box: no
  ternary, no `??`, no `?.`, no `-Parallel`, no `-AsHashtable`, no `$PSStyle`, no
  `Join-String`, no `Get-Error`. Every `.ps1` here is ASCII-only - keep it so.
- House shape for a script: comment-based help header (`.SYNOPSIS`,
  `.DESCRIPTION`, `.EXAMPLE`), then `[CmdletBinding()] param(...)`, then
  `$ErrorActionPreference = 'Stop'`. Status output is two-space-indented
  `Write-Host` in Cyan/Green/Yellow/DarkGray. Resolve ollama as
  `"$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"` with a `Get-Command` fallback.
  Read `benchmark.ps1` and `configure-clients.ps1` before adding a new one.
- Keep scripts idempotent and re-runnable; back up user config before replacing.
- Never commit `.gguf` files, `hardware-profile.json`, `logs/`, `.qwen/`, a
  `*.bak-*` backup, or `.claude-flow/`. The last one is plugin state that has
  already caused one accidental multi-thousand-line commit here; .gitignore now
  covers all of them.
- When adding a measurement, put the actual number in the table above. Estimates
  in this file are worse than useless — they get quoted back as fact.
