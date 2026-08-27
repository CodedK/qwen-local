---
name: delegate-to-qwen
description: Offload bulk, low-stakes, verify-by-inspection generation to the local Qwen models via scripts/ask-qwen.ps1 - docstring passes over many files, test scaffolds, commit-message and changelog drafts, log or output summarisation, boilerplate translation, regex/SQL drafting, rename suggestions. Use when the same mechanical output is needed many times over and a slow round trip is acceptable. Do NOT use for ordinary coding, single small edits, multi-turn judgement, architecture, security-sensitive code, or anything on an interactive path.
---

# Delegate to local Qwen

Hand mechanical generation to a local Qwen model over Ollama instead of writing
it yourself. **You stay in charge of the files.** Qwen returns text; you read it,
correct it, and apply it. Nothing here edits anything.

## The call

Run this through PowerShell, not bash. Keep each invocation on ONE line -
backtick continuations are PowerShell-only and break if pasted into a shell.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/ask-qwen.ps1 -Prompt "..." -Model qwen-coder -Files src/a.py,src/b.py
```

| Flag | Use |
|---|---|
| `-Prompt` | Required. The whole task, self-contained. |
| `-Model` | `qwen38-9b` (default), `qwen-coder`, `qwen38-27b`. Name it explicitly. A bare alias resolves to `:latest`; `QWEN_DELEGATE_MODEL` overrides the default. |
| `-Files` | **Comma-separated, one argument**: `-Files a.py,b.py`. `powershell.exe -File` collapses that into a single string, so the script splits on comma when the literal path does not exist. Literal paths only - wildcards are not expanded. Contents are attached, so do not paste them into `-Prompt` as well. |
| `-System` | Role and output-format instruction, kept out of the task text. |
| `-MaxTokens` | Default 2048. On a thinking model this is a **total** budget, spent on reasoning first - see below. |
| `-TimeoutSec` | Default 900. Raise it for the slow models. Lowering it does not make them faster. |
| `-NumCtx` | Context window. Routes the call to `/api/chat`, because `/v1` silently drops `num_ctx`. First dial to turn when a model that "fits" is inexplicably slow. |
| `-Temperature` / `-MaxFileKB` / `-MaxTotalKB` | Defaults 0.2, a 256 KB per-file cap, and a whole-attachment budget of 4x that. A single oversized file is skipped with a warning; busting the total budget is a hard exit `2`, so a silently truncated context never reaches the model. |
| `-Json` | Envelope on stdout: `model`, `content`, `reasoning`, `promptTokens`, `completionTokens`, `wallSeconds`, `tokensPerSec`. |
| `-IncludeReasoning` | Surface the reasoning trace (on stderr, or inside the `-Json` envelope). It never enters the answer. |
| `-OutFile` / `-Force` | Also write the answer to a file (UTF-8, no BOM). An existing file is backed up first unless `-Force`. stdout still carries the answer, so redirect as well if you want it out of the transcript. |

**Stream contract.** stdout carries **only** the answer - only the envelope with
`-Json`. All status, warnings and reasoning go to stderr, so redirecting stdout
to a file yields clean text. **Check the exit code too:** `0` ok, `2` bad input
(including: none of the `-Files` attached), `3` Ollama unreachable, `4` model not
installed, `5` timeout, `6` API error or empty answer.

`scripts/qwen-models.ps1` lists the tags installed on **this** machine - check it
before naming a model; the tier logic installs different sets on different boxes.

### Thinking models bill reasoning against `-MaxTokens`

`qwen38-9b` and `qwen38-27b` are thinking models: reasoning tokens are generated
**before** any content and charged against `-MaxTokens`, so too small a budget
returns empty content with a full reasoning field. Expect **150-300 reasoning
tokens per call even for a one-word answer**. Reasoning returns separately
(`message.reasoning` on `/v1`, `message.thinking` on `/api/chat`) so
`message.content` is clean either way, and the script exits `6` when only
reasoning came back. `qwen-coder` emits none at all (measured `reasoning=null`)
and is the only installed tag with `tools=true`.

---

## 1. The economics - the honest case

A round trip costs **10s to 500s or more**, depending on model, machine, and
output length. Cold load is **per model**: ~7s for `qwen38-9b` while it is still
resident, ~16-17s once evicted, ~50s for `qwen-coder` on a box where it never
stays resident. On an 8 GB card models are evicted between runs constantly, so
most calls pay one. A model too large to stay loaded pays a **full load on every
call** - batch many items into one call rather than making many small ones.

Delegation pays only when **all three** hold:

- The output is **bulk** - the same shape repeated many times.
- It is **low-stakes** - a wrong line is embarrassing, not dangerous.
- It is **verifiable by inspection** - you can tell it is right by reading it,
  without running a build or reasoning about the whole system.

**Worth delegating**

- Docstring or comment passes across many files
- Test scaffolds (arrange/act/assert skeletons you then fill in)
- Commit message drafts from a diff
- Changelog and release-note drafts from a commit list
- Summarising long logs, stack traces, CI output, command output
- Boilerplate translation (config format to config format, DTO to DTO)
- Regex and SQL drafting, where you will test the result anyway
- Rename and naming suggestions across a symbol list

**Not worth delegating**

- Anything needing multi-turn judgement. Qwen has no memory between calls.
- Anything you must re-verify token by token - you paid the latency for nothing.
- A single small edit. Doing it yourself is faster than one round trip.
- Architecture, API design, migration planning.
- Security-sensitive code: auth, crypto, input validation, permissions.
- Anything on a hot interactive path where the user is waiting on you.

Rule of thumb: if the delegated task is smaller than the prompt you would have to
write to explain it, do it yourself.

---

## 2. Model choice

Pick on what the task needs, not on parameter count.

| Model | What it is | Use for |
|---|---|---|
| `qwen38-9b` | 9B dense, fits entirely in VRAM on most cards | **Default.** Prose, summarising, commit messages, changelogs - anything not structurally code-shaped. Fastest by a wide margin, but thinks before it answers. |
| `qwen-coder` | Qwen3-Coder 30B **MoE, 3B active (A3B)** | Code structure, test scaffolds, refactor suggestions, anything needing tool-shaped reasoning. Roughly 3x slower than the 9B on a weak box, clearly better at code, and carries no reasoning overhead. |
| `qwen38-27b` | 28B **dense** | Only sane if it **fits in VRAM** (>=24 GB). On a small card it is ~1.4 tok/s and effectively unusable - do not send it work there. |

**The rule that decides ties:** on any machine where the model will not fit in
VRAM, prefer the MoE (A3B) over a dense model of similar size. Always. A dense
model that spills to system RAM reads its entire weight set per token; the MoE
reads ~1.5 GB. Architecture dominates size.

---

## 3. Check the machine before assuming any number

The reference box in `CLAUDE.md` is **VRAM-starved** (RTX 2060 SUPER, 8 GB). Its
figures are a floor, not a forecast. Do not quote them as if they describe the
machine you are on.

Before the first delegation in a session:

1. Read `hardware-profile.json` at the repo root if it exists - it carries
   `gpu.vramTotalMB`, `usableVramGB`, `tier`, and `recommended`.
2. Read `benchmark-results.json` if it exists - it carries measured
   `generationTps` and `processorSplit` per model.
3. If neither exists - both are gitignored, so a fresh clone has neither - run
   `.\scripts\benchmark.ps1 -Models qwen38-9b,qwen-coder` once. Omitting
   `-Models` benchmarks **every** qwen alias including `qwen38-27b`, which at
   1.39 tok/s costs about two minutes on its own.

On a stronger box a 24 GB card holds the dense 27B entirely in VRAM, taking it
from ~1.4 to roughly 30-45 tok/s. That is a projection, not a measurement, but it
promotes `qwen38-27b` from useless to worth calling. The decision flips on
hardware alone.

Reference-box figures, measured, for calibration only. Divide your budget by the
rate before committing - and divide **total generated tokens**, not answer
tokens: on the Qwen3.8 models the reasoning is generated too and costs the same
wall clock.

| Model | Split | tok/s | A 600-token answer costs |
|---|---|---|---|
| `qwen38-9b` @ ctx 8192 | 100% GPU | 43.4 | ~750-900 tok generated (600 + reasoning), ~17-21s |
| `qwen-coder` @ ctx 32768 | 69% CPU / 31% GPU | 13.5 | 600 tok, no reasoning, ~45s |
| `qwen38-27b` @ ctx 16384 | 65% CPU / 35% GPU | 1.39 | ~750-900 tok, ~9-11 min |

Then add the cold load from section 1. That arithmetic, not a vibe, decides.

---

## 4. The working pattern

**Qwen has no conversation context.** It cannot see this session, the repo, the
task, or anything said earlier. The prompt must carry everything.

1. Decide the task qualifies (section 1).
2. Pick the model (section 2), sized to the machine (section 3).
3. Build a self-contained prompt. Attach files with `-Files` rather than
   describing them.
4. Call the script, then check the exit code.
5. **Read the output before it touches a file.**
6. Apply the edits yourself, correcting whatever drifted.

Worked example - docstrings across four modules, one line, run in PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/ask-qwen.ps1 -Model qwen-coder -Files src/parser.py,src/loader.py,src/emit.py,src/util.py -System "You write Google-style Python docstrings. Output only docstrings." -Prompt "For every public function in the attached files, write a Google-style docstring. Return a list, one entry per function, formatted exactly as FILE::FUNCTION on its own line followed by the docstring in triple quotes. Do not rewrite function bodies. Do not invent functions that are not in the files." -MaxTokens 2000 -TimeoutSec 900 -OutFile .\docstrings.txt
```

Then read `docstrings.txt`, discard anything wrong, and apply the survivors with
Edit.

**Never paste Qwen output into a file unread.** Measured drift on this stack: a
prompt asking for `ValueError` produced `ZeroDivisionError`. Exception names,
symbol names, import paths and argument order are where a model this size slips,
and exactly where a silent error costs the most.

---

## 5. Writing prompts for a small model

- **One task per call.** Two tasks in one prompt gets you one and a half.
- **Name exact identifiers.** Spell out the class, function, exception and module
  names you want. Do not let it infer them.
- **State the output format explicitly**, separator included. It will not invent
  a parseable one.
- **Prefer "return only X".** Small models pad. "Return only the code, no
  explanation" removes a paragraph of preamble you would otherwise strip.
- **Attach files, do not describe them.** `-Files` is cheaper and more accurate
  than a prose summary of what is in them.
- **Keep context tight.** Long context costs throughput and raises the odds of
  spilling out of VRAM. Attach the two files that matter, not the directory.
- **Add negative constraints.** "Do not rename anything", "do not add imports",
  "do not modify function bodies" all measurably help.
- **Size `-MaxTokens` to answer plus reasoning.** A clean latency cap on
  `qwen-coder`; on the Qwen3.8 models setting it low buys an empty answer.

---

## 6. When to escalate

| Need | Go to |
|---|---|
| A native tool surface instead of shelling out per call | `mcp/qwen-mcp` - option B. Zero-dependency MCP server exposing `ask_qwen`, `list_qwen_models` and `qwen_health`. Register it with `scripts\install-qwen-mcp.ps1`. It also works in Cursor, where a raw localhost endpoint does not. |
| Hand Qwen a whole file-touching task, on a strong machine | `scripts\qwen-task.ps1` - option C. Drives the Qwen Code CLI. |

`qwen-task.ps1` is the one place Qwen writes files, so it is wrapped in git
safety rails: it refuses a dirty tree, works on a throwaway branch, never
commits, and prints the diff plus the keep/abandon commands. Its `-ApprovalMode`
(`plan`, `default`, `auto-edit`, `auto`, `yolo`) maps to qwen's real
`--approval-mode` flag, which the CLI validates but omits from `--help`; the
script probes for it at run time and falls back to a workspace
`.qwen/settings.json` only under `-UseSettingsFile`.

Drive it with `qwen-coder`, its default - `qwen38-9b` cannot tool-call on this
stack at all (Ollama rejects the grammar with a 400). And use it only where an
agent loop is tolerable: one small single-file agentic edit measured **487
seconds** on the reference box. Local agents are for background chores, never for
something a person is waiting on.
