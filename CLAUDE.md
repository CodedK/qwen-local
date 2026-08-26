# CLAUDE.md — instructions for Claude Code working in this repo

**Purpose of this file: stop you from re-deriving what was already established.**
Everything below was measured or verified on real hardware. Treat it as fact and
do not re-research it with web searches. Only verify a claim if the user says
something contradicts it, or if a version number matters and may have moved.

---

## What this repo is

A reproducible local-Qwen coding stack for Windows: Ollama as the runtime, three
client front-ends, and models chosen automatically from the machine's hardware.
The goal is to move routine coding work off a metered cloud model.

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
| `update-claude-stack.ps1` | Update Claude Code, marketplaces, npm CLIs, extensions |

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
With ≥24 GB VRAM the dense 27B fits entirely on the GPU and jumps from ~1.4 to
~30-45 tok/s. Re-benchmark rather than quoting the numbers below.

### Status of each script

| Script | Verified |
|---|---|
| `detect-hardware.ps1` | Run, output confirmed correct |
| `pull-models.ps1` | Run, incl. retry path |
| `create-modelfiles.ps1` | Run |
| `configure-clients.ps1` | Run, configs verified |
| `import-local-gguf.ps1` | Run, rescued a real orphaned blob |
| `benchmark.ps1` | Run on all three models |
| `install.ps1` | Run end-to-end (idempotent path) |
| `update-claude-stack.ps1` | Dry-run only — **live run untested** |

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

### Agentic latency, measured

One small single-file edit via Qwen Code + `qwen-coder` (read file, reason, write
file) took **487 seconds**. Local agents are viable for background chores, not
for interactive back-and-forth. Set expectations accordingly — do not promise
Claude-like responsiveness.

Also observed: asked for `ValueError`, the model emitted `ZeroDivisionError`.
Instruction drift on exact identifiers is normal at this size; verify diffs.

---

## Gotchas that cost real debugging time

1. **Windows silently pages VRAM.** Overshoot VRAM and the WDDM driver spills to
   system RAM over PCIe instead of failing. `ollama ps` still reports
   `100% GPU` while throughput drops ~200×. If a model that "fits" is
   inexplicably slow, **lower `num_ctx` first.** This is the #1 trap.
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

- Scripts target **Windows PowerShell 5.1 and PowerShell 7+**. Avoid PS7-only
  syntax (ternary, `??`) so they run on an untouched machine.
- Keep scripts idempotent and re-runnable; back up user config before replacing.
- Never commit `.gguf` files, `hardware-profile.json`, or `logs/`.
- When adding a measurement, put the actual number in the table above. Estimates
  in this file are worse than useless — they get quoted back as fact.
