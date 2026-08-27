# qwen-mcp

An MCP server that exposes the local Ollama Qwen models to Claude Code, Cursor,
or any other MCP client as **native tools**. Instead of shelling out to a script
and pasting the output back, the agent calls `ask_qwen` the same way it calls
`Read` or `Bash`.

Nothing leaves the machine: the server only ever talks to `127.0.0.1:11434`.

## Why it has no dependencies

The MCP stdio transport is newline-delimited JSON-RPC 2.0, which is small enough
to implement directly. The official `@modelcontextprotocol/sdk` would work too,
but it would put an `npm install` between cloning this repo and having a working
server. That trade is not worth it for ~120 lines of protocol, so `index.js`
depends on nothing but Node 18+ (for global `fetch`).

## Tools

| Tool | Arguments | Returns |
|---|---|---|
| `ask_qwen` | `prompt` (required), `model`, `files[]`, `system`, `max_tokens`, `temperature`, `num_ctx`, `include_reasoning` | The model's text, plus a one-line footer with model, token counts and speed |
| `list_qwen_models` | none | Every installed tag with size, family, MoE-vs-dense, and whether it fits this machine's VRAM |
| `qwen_health` | none | Whether Ollama is reachable, its version, which model is resident and its GPU/CPU split |

`ask_qwen` **never writes files.** It reads the paths in `files[]` and returns
text; applying anything is the caller's job. That is deliberate - the local model
is good enough to draft with and not reliable enough to let loose on a working
tree.

## Registering it

```powershell
.\scripts\install-qwen-mcp.ps1
```

That resolves Node, syntax-checks the server, and registers it with the Claude
Code CLI in user scope so it is available in every project. It is idempotent:
an existing `qwen` entry is left alone unless you pass `-Force`.

```powershell
.\scripts\install-qwen-mcp.ps1 -Scope project      # only this repo
.\scripts\install-qwen-mcp.ps1 -Force              # replace an existing entry
.\scripts\install-qwen-mcp.ps1 -OllamaHost http://192.168.1.10:11434
```

Then restart Claude Code (or run `/mcp`) and check with `claude mcp get qwen`.

It exits **0** when the server is registered - whether it registered it now or
found it already there - and **1** when registration failed and the manual
instructions were printed instead, so a wrapper script can branch on it.

### By hand

```powershell
claude mcp add qwen -s user -e OLLAMA_HOST=http://127.0.0.1:11434 -- "C:\Program Files\nodejs\node.exe" "<repo>\mcp\qwen-mcp\index.js"
```

### Cursor

Cursor reads the same entry shape from `~/.cursor/mcp.json` (or `.cursor/mcp.json`
inside a project):

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

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `OLLAMA_HOST` | `http://127.0.0.1:11434` | Where Ollama listens. A bare `host:port` is accepted. |
| `QWEN_MCP_MODEL` | `qwen-coder` | Model used when `ask_qwen` is called without one. |
| `QWEN_MCP_TIMEOUT` | `900` | Seconds before a generation is aborted. Raise it for a big model on a slow box. |
| `QWEN_MCP_ROOT` | the server's cwd | Root that `files[]` paths may not escape. |

## Testing it without a client

The server is just a process on stdio, so one line proves it is alive:

```powershell
'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' | node mcp\qwen-mcp\index.js
```

```json
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"qwen-mcp","version":"1.0.0"}}}
```

A handshake only proves the process starts. To prove the tools actually run,
pipe in a real `tools/call` - `qwen_health` is the cheapest one, since it needs
Ollama but loads no model:

```powershell
@(
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'
  '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"qwen_health","arguments":{}}}'
) | node mcp\qwen-mcp\index.js
```

Two frames come back: the handshake, then a `content[0].text` holding the health
JSON. Swap in `{"name":"ask_qwen","arguments":{"prompt":"Reply with exactly one
word: pineapple","model":"qwen38-9b","max_tokens":800}}` to exercise generation -
just budget for the model load, which dominates a single call.

Piping like this is safe because the server **drains before exiting**: closing
stdin waits for handlers that are still awaiting Ollama or the filesystem
instead of killing them. Send `{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}`
on its own line for the full tool schemas.

## Things that will bite you

- **It is slow, by design of the hardware.** A cold call pays the model load
  first: a trivial prompt against `qwen38-9b` measured 17.6 s cold and 2.6 s
  warm on the reference box. Delegate background chores to it, not anything on
  an interactive path.
- **Thinking models spend `max_tokens` on reasoning first.** Qwen3.8 puts its
  chain of thought in a separate `reasoning` field, so `content` arrives clean -
  but with a small budget the reasoning consumes all of it and `content` comes
  back empty. The server detects that and returns an explicit error saying to
  raise `max_tokens` or switch to `qwen-coder`, which does not think.
- **`num_ctx` is routed differently on purpose.** Ollama's OpenAI-compatible
  endpoint silently drops `num_ctx` (verified against 0.32.15), so when you pass
  it the server uses the native `/api/chat` endpoint instead. That change forces
  Ollama to reload the model, so do not vary it call to call.
- **`files[]` is sandboxed to the server's working directory.** Claude Code
  starts the server with the project directory as cwd. Paths are checked before
  and after symlink resolution; anything that escapes is refused. Caps: 20 files,
  256 KB each, 1 MB total.
- **Generations are serialised; everything else is not.** One GPU means one
  generation at a time, so a second `ask_qwen` queues behind the first. Only
  `ask_qwen` queues: `ping`, `tools/list`, `qwen_health` and `list_qwen_models`
  answer immediately even mid-generation, so a client's liveness probe cannot
  time out and declare the server dead during a long run.
- **Errors come back two ways.** Bad arguments are JSON-RPC `-32602`. Runtime
  trouble - Ollama down, unknown model, timeout - comes back as a tool result
  with `isError: true` and text explaining what to do, so the calling model can
  read it and adapt instead of just failing.
