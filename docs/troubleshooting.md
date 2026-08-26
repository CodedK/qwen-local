# Troubleshooting

Every failure below was actually hit while building this stack, with the fix that
worked. Ordered roughly by how likely you are to meet it.

---

## A model that "fits in VRAM" is catastrophically slow

**Symptom.** `ollama ps` reports `100% GPU`, but generation crawls — single-digit
or fractional tokens/sec, while prompt evaluation looks normal.

**Cause.** On Windows, overshooting VRAM does **not** fail. The WDDM driver
silently spills the excess into system RAM and shuttles it over PCIe every token.
Ollama believes it placed everything on the GPU, so it keeps reporting `100% GPU`.

**Measured on an 8 GB RTX 2060 SUPER** with `qwen38-9b`:

| `num_ctx` | Reported split | tok/s |
|---|---|---|
| 8192 | 100% GPU | 43.4 |
| 16384 | 100% GPU | 39.8 |
| 24576 | 100% GPU | **0.2** |
| 32768 | 14% CPU / 86% GPU | 22.7 |

Note 24576 is *slower than* 32768. At 32768 Ollama honestly offloads layers to
CPU; at 24576 it thinks everything fits and the driver thrashes instead.

**Fix.** Lower `num_ctx` until throughput recovers. Leave ~1.5 GB of VRAM free for
the desktop. This is the single most common cause of "why is my local model
useless".

---

## Everything is slow while a download runs

**Symptom.** A model that benchmarked fine now returns a fraction of its speed.

**Measured.** `qwen38-9b` dropped from **22.7 tok/s to 0.3 tok/s** while an 18 GB
`ollama pull` was running.

**Fix.** Finish downloads before benchmarking or working. Check with
`Get-Process ollama` or watch disk activity. Never draw performance conclusions
from a machine that is mid-pull.

---

## `Error: context deadline exceeded` at the end of a large pull

**Symptom.** `ollama pull hf.co/...` reaches 100%, sits on `pulling manifest`,
then fails. Retrying re-downloads and fails identically.

**Cause.** The blob downloads fine; the manifest/commit step times out on a large
file. The blob is left complete and valid on disk with no manifest pointing at it.

**Fix — do not re-download.** Confirm the orphan, then import it:

```powershell
.\scripts\import-local-gguf.ps1 -ListOrphans

.\scripts\import-local-gguf.ps1 `
    -GgufPath "$env:USERPROFILE\.ollama\models\blobs\sha256-<digest>" `
    -Alias qwen38-27b -NumCtx 16384
```

Verify it is a real GGUF first — the first four bytes must be `GGUF`. The import
script checks this before handing anything to Ollama.

**Caveat.** Ollama rewrites metadata during import, producing a *different*
digest, so it does **not** deduplicate — you temporarily hold two copies. Reclaim
the space by deleting the orphan, but only after confirming nothing references it:

```powershell
# List every blob >1 GB and which manifest references it
$mroot = "$env:USERPROFILE\.ollama\models\manifests"
$refs = @{}
Get-ChildItem $mroot -Recurse -File | ForEach-Object {
    $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
    foreach ($d in @($j.layers.digest) + @($j.config.digest)) {
        if ($d) { $refs[($d -replace ':','-')] = $true }
    }
}
Get-ChildItem "$env:USERPROFILE\.ollama\models\blobs" -File |
    Where-Object { $_.Length -gt 1GB -and -not $refs[$_.Name] } |
    Select-Object Name, @{n='GB';e={[math]::Round($_.Length/1GB,2)}}
```

Anything listed is unreferenced and safe to remove. This recovered 15.4 GB here.

---

## `ollama` is not recognized as a command

**Cause.** The installer appends to PATH, but a shell (or agent session) started
*before* the install keeps its original environment block.

**Fix.** Resolve the executable directly instead of relying on PATH:

```powershell
$ollama = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
```

Every script in this repo does this. Open a new terminal to get PATH normally.

---

## Ollama API refuses connections on port 11434

**Cause.** The tray app (`ollama app.exe`) does not always spawn the server.

**Fix.** Start the server directly. Set environment variables *first* — the server
reads its environment at launch, and a child process inherits the parent's block,
not the registry:

```powershell
$env:OLLAMA_FLASH_ATTENTION='1'
$env:OLLAMA_KV_CACHE_TYPE='q8_0'
Start-Process "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" -ArgumentList 'serve' -WindowStyle Hidden
```

Changing a user environment variable does **not** affect an already-running
server. Restart it after any tuning change.

---

## A Hugging Face model tag fails or 404s

**Fix.** Verify before committing to a multi-GB download. Ollama resolves
`hf.co/{repo}:{tag}` through this endpoint:

```powershell
$r = Invoke-RestMethod 'https://huggingface.co/v2/{owner}/{repo}/manifests/{TAG}'
'{0:N2} GB across {1} layer(s)' -f (($r.layers | Measure-Object size -Sum).Sum/1GB), $r.layers.Count
```

Costs one second, catches a typo before 16 GB. Tags match the quantization portion
of the filename — e.g. `Qwen3.8-27B-Uncensored-noMTP-Q4_K_M.gguf` → `noMTP-Q4_K_M`.

---

## Tab autocomplete emits chat prose into the file

**Cause.** An instruct model is configured for the `autocomplete` role. Autocomplete
requires fill-in-the-middle (FIM) training, which only `-base` models have.

**Fix.** Use `qwen2.5-coder:1.5b-base` or `3b-base`. Re-run
`configure-clients.ps1`, which picks a base model automatically.

---

## Qwen Code will not edit files in non-interactive mode

**Cause.** There is no `--yolo` flag in v0.22. Approval is a setting.

**Fix.** Set it per project so global behaviour stays cautious — create
`.qwen/settings.json` **in the project directory**:

```json
{ "tools": { "approvalMode": "yolo" } }
```

Modes: `default` (ask), `auto-edit` (auto-approve edits only), `auto`
(classifier-evaluated), `yolo` (approve everything), `plan` (read-only).

Auto-executing shell commands runs at your privilege level. Prefer `auto-edit`
for day-to-day work; reserve `yolo` for throwaway directories.

---

## `npm` reports `Unknown command: "pm"`

**Cause.** The `npm` PowerShell shim mangles arguments when invoked with `&`.

**Fix.** Call `npm.cmd` explicitly:

```powershell
& npm.cmd list -g --depth=0
```

---

## PSScriptAnalyzer warns about an automatic variable

`$profile`, `$host`, `$error`, `$input`, `$matches` and friends are built-in.
Assigning to them can break unrelated behaviour — and a silent bug: writing
`$profile | ConvertTo-Json` serialises PowerShell's profile path, not your data.
Rename the variable.

---

## The model ignores part of the instruction

Expected at this size. Asked for `ValueError`, `qwen-coder` produced
`ZeroDivisionError` — functionally reasonable, literally wrong.

Mitigations: keep instructions short and single-purpose, prefer `auto-edit` so you
see diffs, and always review changes. A local 30B is not a drop-in replacement for
a frontier model on precision-sensitive edits.
