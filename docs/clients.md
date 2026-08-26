# Client configuration

Three front-ends, all pointed at the same local Ollama server.

| Client | Role | Config location | Automated? |
|---|---|---|---|
| Qwen Code CLI | Terminal agent | `~/.qwen/settings.json` | Yes |
| Continue.dev | Chat + tab autocomplete | `~/.continue/config.yaml` | Yes |
| Cline | IDE agent | VS Code extension state | **No — UI, once** |

`configure-clients.ps1` writes the first two, generating entries only for models
actually installed. Existing files are backed up to `*.bak-<timestamp>` first.

---

## The shared endpoint

Ollama exposes an OpenAI-compatible API:

```
http://localhost:11434/v1
```

Clients demand an API key; Ollama ignores it. Any non-empty string works — this
repo uses `ollama`. **It is not a secret.** Don't treat it as one, and don't ask
anyone to supply a real key for local use.

---

## Qwen Code CLI

The closest analogue to Claude Code: a terminal agent that reads and edits files
and runs commands. Requires **Node ≥ 22**.

```powershell
npm install -g @qwen-code/qwen-code@latest
cd C:\path\to\project
qwen
```

Generated `~/.qwen/settings.json`:

```json
{
  "modelProviders": {
    "openai": [
      {
        "id": "qwen-coder",
        "name": "Qwen3-Coder 30B-A3B (local)",
        "baseUrl": "http://localhost:11434/v1",
        "envKey": "OPENAI_API_KEY"
      }
    ]
  },
  "env": { "OPENAI_API_KEY": "ollama" },
  "security": { "auth": { "selectedType": "openai" } },
  "model": { "name": "qwen-coder" }
}
```

- `modelProviders.openai[]` — every model appears in the `/model` picker.
- `security.auth.selectedType` — skips interactive `/auth` on startup.
- `model.name` — the default; must match an `id` above.

### Approval modes

There is **no `--yolo` flag** in v0.22. Approval is configured via
`tools.approvalMode`:

| Mode | Behaviour |
|---|---|
| `plan` | Read-only; proposes without acting |
| `default` | Asks before every tool call |
| `auto-edit` | Auto-approves file edits, asks for shell commands |
| `auto` | Classifier decides per call |
| `yolo` | Auto-approves everything |

Change it live with `/approval-mode`, or per project — create
`.qwen/settings.json` **in the project directory**:

```json
{ "tools": { "approvalMode": "auto-edit" } }
```

Scoping it per project keeps your global default cautious. `yolo` auto-executes
shell commands at your privilege level; reserve it for throwaway directories, and
combine with `--sandbox` where possible.

### Useful commands

| Command | Effect |
|---|---|
| `/model` | Switch model at runtime |
| `/approval-mode` | Change approval behaviour |
| `qwen -p "..."` | Non-interactive, one-shot |
| `qwen -c` | Resume the most recent session |

---

## Continue.dev

Chat and inline tab-completion inside VS Code. Extension ID `Continue.continue`.

Generated `~/.continue/config.yaml`:

```yaml
name: Local Qwen
version: 1.0.0
schema: v1
models:
  - name: Qwen3-Coder 30B-A3B (local)
    provider: ollama
    model: qwen-coder
    apiBase: http://localhost:11434
    roles:
      - chat
      - edit
      - apply
  - name: Tab autocomplete
    provider: ollama
    model: qwen2.5-coder:1.5b-base
    apiBase: http://localhost:11434
    roles:
      - autocomplete
    autocompleteOptions:
      debounceDelay: 350
      maxPromptTokens: 1024
    defaultCompletionOptions:
      temperature: 0.1
```

Valid roles: `chat`, `autocomplete`, `embed`, `rerank`, `edit`, `apply`,
`summarize`.

> **Autocomplete must use a `-base` model.** Base models are trained for
> fill-in-the-middle. An instruct model will write chat prose into your source
> file. `qwen2.5-coder:1.5b-base` is small enough to co-exist with a loaded agent
> model; use `3b-base` if you have VRAM to spare.

Codebase indexing needs an `embed`-role model — not configured by default to
avoid another download. Add `nomic-embed-text` if you want semantic search.

---

## Cline

The one manual step. Cline stores provider settings in VS Code's extension global
state rather than a config file, so it cannot be scripted safely.

1. Open the Cline sidebar in VS Code
2. Gear icon → **API Provider** → `Ollama`
3. **Base URL**: `http://localhost:11434`
4. **Model ID**: `qwen-coder`

Extension ID: `saoudrizwan.claude-dev`.

Cline is context-hungry — it sends large system prompts and file contents. On a
machine where the model is offloaded, prefer Qwen Code for agent work and keep
Cline for smaller, targeted edits.

---

## Which client for which job

| Task | Use |
|---|---|
| Multi-file refactor, run tests | Qwen Code CLI |
| Single targeted edit with diff review | Cline |
| Writing code, want completions | Continue autocomplete |
| Quick question, no files | `ollama run qwen38-9b` |

---

## Expectation setting

A measured single-file edit through Qwen Code + `qwen-coder` on the reference
machine took **487 seconds**. Local agents on modest hardware suit background
chores — boilerplate, tests, docs, commit messages — not interactive pairing.

On a 24 GB card the same work runs roughly 25× faster and the calculus changes
completely. See [hardware-sizing.md](hardware-sizing.md).
