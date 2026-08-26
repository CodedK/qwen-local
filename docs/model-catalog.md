# Model catalog

Verified repos, exact file sizes and architecture facts. Sizes came from the
Hugging Face file tree API, not from memory — trust them.

---

## Architecture cheat sheet

| Model | Total | Active/token | Type | Consequence |
|---|---|---|---|---|
| Qwen3.8-27B | 28B | **28B** | **Dense** | Brutal when offloaded |
| Qwen3.8-9B | 9B | 9B | Dense | Small enough to fit VRAM |
| Qwen3-Coder-30B | 30B | **3B** | **MoE (A3B)** | Fast even at 69% CPU |
| Qwen3-Coder-Next | 80B | **3B** | **MoE (A3B)** | Needs ≥64 GB RAM |
| Qwen3-Coder-480B | 480B | 35B | MoE | Server hardware |

**Qwen3.8-27B being dense is the most important fact in this repo.** It is
counter-intuitive: a *smaller* file (16 GB) runs ~10× slower than a *larger* one
(18 GB MoE) on identical hardware.

Other Qwen3.8 traits:

- **Hybrid attention** — 48 of 64 layers are Gated DeltaNet (linear attention,
  constant recurrent state); only 16 keep a growing KV cache. Long context is
  cheap.
- **Thinking model by default.** Reasoning tokens multiply latency; disable
  thinking or lower `reasoning_effort` on slow setups.
- Released 3 August 2026, alongside Qwen3.8-Max.

---

## Qwen3.8-27B Uncensored — GGUF sizes

Repo: [`JonathanColetti/Qwen3.8-27B-Uncensored-GGUF`](https://huggingface.co/JonathanColetti/Qwen3.8-27B-Uncensored-GGUF)
(~1.46M downloads — the most-used build)

| Quant | Size | Fits 8 GB? | Fits 24 GB? |
|---|---|---|---|
| IQ2_M | 10.62 GB | no | yes |
| IQ3_M | 12.77 GB | no | yes |
| IQ4_XS | 15.31 GB | no | yes |
| **Q4_K_M** | **16.81 GB** | no | yes |
| Q5_K_M | 19.54 GB | no | yes |
| Q6_K | 22.43 GB | no | tight |
| Q8_0 | 29.05 GB | no | no |

`noMTP-*` variants are ~0.25 GB smaller and **preferred for Ollama** — they omit
multi-token-prediction tensors that llama.cpp will not use anyway.

Also in the repo: `draft-Q8_0` (3.16 GB) for speculative decoding under
llama.cpp's `-md` flag, and `vision-f16` (0.93 GB) for image input.

**Alternative:** [`mradermacher/Qwen3.8-27B-Uncensored-i1-GGUF`](https://huggingface.co/mradermacher/Qwen3.8-27B-Uncensored-i1-GGUF)
offers imatrix quants — better quality at the same size, especially below Q4.

---

## Qwen3.8-9B heretic-uncensored — GGUF sizes

Repo: [`mradermacher/Qwen3.8-9B-heretic-uncensored-GGUF`](https://huggingface.co/mradermacher/Qwen3.8-9B-heretic-uncensored-GGUF)

| Quant | Size | Notes |
|---|---|---|
| Q2_K | 3.56 GB | quality falls off sharply |
| Q3_K_M | 4.31 GB | |
| IQ4_XS | 4.87 GB | best fit for ~6 GB usable VRAM |
| Q4_K_S | 4.98 GB | |
| **Q4_K_M** | **5.24 GB** | default here |
| Q5_K_M | 6.02 GB | if you have 8 GB usable |
| Q6_K | 6.86 GB | 12 GB cards |
| Q8_0 | 8.88 GB | |

Ships `mmproj-*` vision projectors, so the 9B handles images too.

---

## Choosing a quantization

- **Q4_K_M** is the default sweet spot — near-Q5 quality at ~55% of f16 size.
- **IQ4_XS** trades ~1.5 GB for a small quality loss; use it to squeeze into VRAM.
- **IQ3_*** is a real but acceptable drop on large models; poor on small ones.
- **Q2_K / IQ2_M** degrade badly for code. Avoid unless nothing else fits.
- **Bigger model at lower quant usually beats smaller model at higher quant** —
  but only if it still fits in VRAM. Once it spills, that rule inverts hard.

---

## Verify a tag before downloading

Ollama resolves `hf.co/{repo}:{tag}` via a registry-style endpoint. One call
confirms the tag exists and reports the real size:

```powershell
$r = Invoke-RestMethod 'https://huggingface.co/v2/mradermacher/Qwen3.8-9B-heretic-uncensored-GGUF/manifests/Q4_K_M'
'{0:N2} GB across {1} layer(s)' -f (($r.layers | Measure-Object size -Sum).Sum/1GB), $r.layers.Count
```

The tag is the quantization portion of the filename:

| Filename | Tag |
|---|---|
| `Qwen3.8-9B-heretic-uncensored.Q4_K_M.gguf` | `Q4_K_M` |
| `Qwen3.8-27B-Uncensored-noMTP-Q4_K_M.gguf` | `noMTP-Q4_K_M` |

A layer count >1 usually means a vision projector ships alongside the weights.

---

## About the uncensored builds

These are **abliterated** models, produced with
[Heretic](https://github.com/p-e-w/heretic). Abliteration is a weight edit, not a
fine-tune: the "refusal direction" in the residual stream is identified and
orthogonalised out, minimising refusals while limiting KL divergence from the
base model.

Practical trade-off: abliteration slightly degrades instruction-following and
tool-calling reliability. That matters most in agent loops, where a missed tool
call wastes a full turn. Hence the unmodified `qwen-coder` is the default agent
model here, with the uncensored builds available alongside it.

Repo quality varies enormously. `mradermacher` and `bartowski` are established
quantizers; many "ULTIMATE"/"AEON" repos are low-effort re-uploads. Prefer known
quantizers, and always verify the manifest.
