# Client configuration

Three front-ends, all pointed at the same local Ollama server.

| Client | Role | Config location | Automated? |
|---|---|---|---|
| Qwen Code CLI | Terminal agent | `~/.qwen/settings.json` | Yes |
| Continue.dev | Chat + tab autocomplete | `~/.continue/config.yaml` | Yes |
| Cline | IDE agent | VS Code extension state | **No — UI, once** |

`configure-clients.ps1` writes the first two, generating entries only for models
actually installed. Existing files are backed up to `*.bak-<timestamp>` first.

Cursor is deliberately not on that list. [Cursor](#cursor) below records why it
cannot reach a local model, and the one route that does work.

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

`--approval-mode` and `--yolo` are real, validated top-level flags in v0.22.1.
They are simply omitted from `--help`, which is why they look like they do not
exist. Proof: `qwen --approval-mode bogus -p hi` exits 1 with `Invalid values:
Argument: approval-mode, Given: "bogus", Choices: "plan", "default",
"auto-edit", "auto", "yolo"`. The flag is consumed ahead of any settings file,
so it is the mechanism to reach for first:

| Mode | Behaviour |
|---|---|
| `plan` | Read-only; proposes without acting |
| `default` | Asks before every tool call |
| `auto-edit` | Auto-approves file edits, asks for shell commands |
| `auto` | Classifier decides per call |
| `yolo` | Auto-approves everything |

```powershell
qwen --approval-mode auto-edit -p 'Add a docstring to every function in src\parse.py'
```

Inside a running session, change it with `/approval-mode`. On an older build
that does not accept the flag, or to pin the setting for a whole project, create
`.qwen/settings.json` **in the project directory** instead:

```json
{ "tools": { "approvalMode": "auto-edit" } }
```

Scoping it per project keeps your global default cautious. `yolo` auto-executes
shell commands at your privilege level; reserve it for throwaway directories, and
combine with `--sandbox` where possible.

`qwen-task.ps1` probes for the flag at run time and prefers it, falling back to a
temporary workspace `.qwen/settings.json` only under `-UseSettingsFile`.

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

## Cursor

Not configured by `configure-clients.ps1`, and the reason is worth writing down
because it looks like it ought to just work.

Cursor's model calls are made by Cursor's backend, not by the editor on your
machine. That backend is sandboxed and cannot reach `localhost:11434`, so
pointing **Override OpenAI Base URL** at the local server fails outright. The
only way to make it connect is to publish Ollama on a public HTTPS tunnel:

```powershell
cloudflared tunnel --url http://localhost:11434/v1
# paste the https://... URL into Settings -> Models -> Override OpenAI Base URL
```

`ngrok http 11434` does the same job. Either way three things stay true:

- Your prompts and your code travel out to Cursor's servers and back down the
  tunnel, which defeats most of the point of running the model locally.
- Tab autocomplete does not change. It is wired to Cursor's proprietary Fusion
  model and ignores the base URL override entirely.
- The tunnel publishes an unauthenticated API to the internet for as long as it
  is up.

For a local model in an IDE, use [Continue.dev](#continuedev) instead. It talks
to `localhost` directly, `configure-clients.ps1` has already written its config,
and it covers chat, edit and autocomplete.

### The exception: MCP

Cursor does speak MCP, and an MCP server runs locally as a child process of the
editor rather than inside the backend. So the `qwen-mcp` server works in Cursor
with no tunnel and nothing leaving the machine. This is the clean way to get
local Qwen into Cursor.

Add the entry to `~/.cursor/mcp.json`, or `.cursor/mcp.json` for one project:

```json
{
  "mcpServers": {
    "qwen": {
      "type": "stdio",
      "command": "C:\\Program Files\\nodejs\\node.exe",
      "args": ["C:\\path\\to\\qwen-local\\mcp\\qwen-mcp\\index.js"],
      "env": { "OLLAMA_HOST": "http://127.0.0.1:11434" }
    }
  }
}
```

`ask_qwen`, `list_qwen_models` and `qwen_health` then show up as tools. Full
details in [mcp/qwen-mcp/README.md](../mcp/qwen-mcp/README.md).

---

## Which client for which job

| Task | Use |
|---|---|
| Multi-file refactor, run tests | Qwen Code CLI |
| Single targeted edit with diff review | Cline |
| Writing code, want completions | Continue autocomplete |
| Quick question, no files | `ollama run qwen38-9b` |
| Local Qwen inside Cursor | the `qwen-mcp` MCP server, never the base URL override |

---

## Expectation setting

A measured single-file edit through Qwen Code + `qwen-coder` on the reference
machine took **487 seconds**. Local agents on modest hardware suit background
chores — boilerplate, tests, docs, commit messages — not interactive pairing.

On a 24 GB card the same work runs roughly 25× faster and the calculus changes
completely. See [hardware-sizing.md](hardware-sizing.md).
