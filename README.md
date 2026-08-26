# qwen-local

Reproducible **local Qwen coding stack for Windows**. One script detects your
hardware, picks models that will actually run well on it, installs the runtime
and three client front-ends, and wires them together.

Built to move routine coding work — refactors, boilerplate, tests, docs, commit
messages — off a metered cloud model and onto the GPU you already own.

---

## Quick start

```powershell
git clone https://github.com/CodedK/qwen-local.git $env:USERPROFILE\qwen-local
cd $env:USERPROFILE\qwen-local

# One-time, on a fresh machine: allow local scripts to run and clear the
# "downloaded from the internet" flag Windows puts on cloned files.
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
Get-ChildItem -Recurse *.ps1 | Unblock-File

.\scripts\install.ps1 -All
```

That's it. The installer is idempotent — re-run it any time.

`-All` also pulls the large uncensored dense model; omit it for a leaner install.
Without those two one-time commands, PowerShell will refuse to run the scripts
with a security error.

To see what it *would* do without changing anything:

```powershell
.\scripts\detect-hardware.ps1
```

---

## What you get

| Layer | Component | Why |
|---|---|---|
| Runtime | [Ollama](https://ollama.com) | Model management + OpenAI-compatible API on `:11434` |
| Terminal agent | [Qwen Code CLI](https://github.com/QwenLM/qwen-code) | Closest analogue to Claude Code — reads/edits files, runs commands |
| IDE agent | [Cline](https://marketplace.visualstudio.com/items?itemName=saoudrizwan.claude-dev) | Plan/act modes with diff approval inside VS Code |
| Autocomplete | [Continue.dev](https://continue.dev) | Inline tab-completion from a small FIM model |

Plus short, tuned model aliases so you never type a 60-character Hugging Face ref:

| Alias | Backing model | Role |
|---|---|---|
| `qwen-coder` | Qwen3-Coder 30B-A3B | Agentic file editing and tool use |
| `qwen38-9b` | Qwen3.8 9B (uncensored) | Fast general chat, fits fully in VRAM |
| `qwen38-27b` | Qwen3.8 27B (uncensored) | Hardest reasoning, slow unless you have VRAM |

---

## The one thing to understand: dense vs MoE

This drives every model choice in the repo.

A **dense** model activates every parameter for every token. A **Mixture-of-Experts
(MoE)** model activates only a small slice — Qwen3-Coder-30B is "A3B", meaning
**3B active parameters** out of 30B.

Generation speed is bound by memory bandwidth, not compute:

```
tok/s  ≈  usable_RAM_bandwidth  /  GB_of_weights_read_per_token
```

So when a model doesn't fit in VRAM and spills into system RAM, MoE wins enormously.
Measured on the reference machine (RTX 2060 SUPER 8 GB, DDR4-2133, ~25.6 GB/s):

| Model | Size on disk | GPU/CPU split | **tok/s** |
|---|---|---|---|
| Qwen3-Coder 30B **MoE** | 18 GB | 69% CPU / 31% GPU | **13.5** |
| Qwen3.8 27B **dense** | 16 GB | 65% CPU / 35% GPU | **1.39** |

At a nearly identical CPU split, the *bigger* MoE model is **~10× faster** than
the dense one. Both numbers are measured, not estimated.

> **Rule:** if it won't fit in VRAM, prefer MoE. Always.

---

## Hardware tiers

`detect-hardware.ps1` measures usable VRAM (total minus ~1.5 GB desktop reserve)
and maps it to a tier:

| Usable VRAM | Agent model | Uncensored model |
|---|---|---|
| < 1 GB (no GPU) | `qwen3.5:4b` | Qwen3.8-9B Q4_K_S |
| ≤ 6 GB | Qwen3-Coder 30B (hybrid) | Qwen3.8-9B IQ4_XS |
| ≤ 10 GB | Qwen3-Coder 30B (hybrid) | Qwen3.8-9B Q4_K_M |
| ≤ 14 GB | Qwen3-Coder 30B | Qwen3.8-27B IQ2_M |
| ≤ 20 GB | Qwen3-Coder 30B | Qwen3.8-27B IQ4_XS |
| ≤ 32 GB | Qwen3-Coder 30B | Qwen3.8-27B Q4_K_M |
| ≤ 64 GB | Qwen3-Coder-Next 80B-A3B | Qwen3.8-27B Q6_K |
| > 64 GB | Qwen3-Coder-Next Q8_0 | Qwen3.8-27B Q8_0 |

RAM gates the top tiers: Qwen3-Coder-Next needs ≥ 64 GB system RAM and is
automatically downgraded if you don't have it.

---

## Daily use

**Terminal agent** — the Claude Code replacement:

```powershell
cd C:\path\to\your\project
qwen                      # starts with the default model
```

Inside the CLI, `/model` switches between the aliases at runtime.

**VS Code** — open the Cline sidebar, or press Tab for Continue autocomplete.

**Direct chat**:

```powershell
ollama run qwen38-9b
```

**Check what's loaded and where**:

```powershell
ollama ps                 # shows the GPU/CPU split - watch this number
```

**Re-measure speed after any change**:

```powershell
.\scripts\benchmark.ps1
```

---

## If it's slow

Run through these in order — the first one is by far the most common:

1. **Lower `num_ctx`.** On Windows, exceeding VRAM does *not* fail. The driver
   silently pages over PCIe while `ollama ps` still claims `100% GPU`, and
   throughput drops ~200×. Measured: ctx 16384 → 39.8 tok/s, ctx 24576 → **0.2 tok/s**.
2. **Check nothing else is downloading.** A concurrent `ollama pull` took the
   same model from 22.7 → 0.3 tok/s.
3. **Check the split** with `ollama ps`. Lots of CPU% on a *dense* model means
   you need a smaller quant.
4. **Free VRAM.** Browsers hold hundreds of MB. Close them and reload the model.

Full list of failure modes and fixes: [docs/troubleshooting.md](docs/troubleshooting.md).

---

## Companion utility: keeping the AI tooling current

Not Qwen-specific, but useful on every machine this repo lands on —
`update-claude-stack.ps1` updates Claude Code, its plugin marketplaces, related
global npm CLIs and the VS Code extensions in one pass, then prints a
before/after version table.

```powershell
.\scripts\update-claude-stack.ps1 -DryRun     # show what would change
.\scripts\update-claude-stack.ps1             # do it
```

It backs up `installed_plugins.json` and friends to `~/.claude/backups/` before
touching anything. Flags: `-SkipNpm`, `-SkipExtensions`, `-SkipMarketplaces`,
`-NpmPackages`.

---

## Documentation

| Doc | Contents |
|---|---|
| [docs/hardware-sizing.md](docs/hardware-sizing.md) | Bandwidth math, tier logic, how to size a new machine |
| [docs/model-catalog.md](docs/model-catalog.md) | Verified repos, exact file sizes, quant tradeoffs |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Every failure hit during development, with fixes |
| [docs/clients.md](docs/clients.md) | Per-client configuration details |
| [CLAUDE.md](CLAUDE.md) | Context for Claude Code so it doesn't re-derive all this |

---

## Requirements

- Windows 10/11
- PowerShell 5.1+ (7+ recommended)
- Node.js ≥ 22 (for Qwen Code CLI)
- ~45 GB free disk for the full model set
- NVIDIA GPU recommended; CPU-only works but is slow

`winget`, `git`, and VS Code are installed/verified by the installer where possible.

---

## A note on the uncensored models

The `qwen38-*` aliases use community *abliterated* builds — the refusal direction
is orthogonalized out of the weights ([Heretic](https://github.com/p-e-w/heretic)
method). This is a weight edit, not a fine-tune.

Worth knowing: abliteration slightly degrades instruction-following and
tool-calling reliability, which matters most for agent loops. That's why
`qwen-coder` (unmodified) is the default agent model and the uncensored builds
are offered alongside it rather than instead of it.

---

## License

MIT — see [LICENSE](LICENSE).
