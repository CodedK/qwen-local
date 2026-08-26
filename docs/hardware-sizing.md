# Hardware sizing

How to predict what a machine can run, before downloading 40 GB to find out.

---

## The only formula that matters

Token generation is **memory-bandwidth-bound**, not compute-bound. Each token
requires reading the weights it activates. So:

```
tok/s  ≈  bandwidth_where_weights_live  /  GB_of_weights_read_per_token
```

Two consequences:

- **Weights in VRAM are ~15-25× faster to read than weights in system RAM.**
  An RTX 2060 SUPER has ~448 GB/s; DDR4-2133 dual-channel has ~25 GB/s usable.
- **What "weights read per token" means depends on architecture**, not file size.

| Architecture | Weights read per token |
|---|---|
| Dense | the entire model |
| MoE (A3B) | only the active experts — ~3B params ≈ 1.5 GB at Q4 |

This is why a 30 GB MoE model can beat a 16 GB dense model by 10×.

### Apply an overhead factor

Pure math is optimistic. For the dense 27B here it predicted 2.3 tok/s; measured
**1.39**. PCIe transfers and synchronisation cost roughly **1.5–1.7×** when a
model is heavily offloaded. Multiply your estimate by ~0.6 for a realistic figure.

---

## Estimating usable RAM bandwidth

```
peak_GBs  = channels × MT/s × 8 bytes / 1000
usable    ≈ peak × 0.75
```

**Populated DIMM count is not channel count.** The reference machine has four
DDR4-2133 sticks but the i7-7700 is **dual-channel** — 4 sticks share 2 channels:

```
2 × 2133 × 8 / 1000 = 34.1 GB/s peak  →  ~25.6 GB/s usable
```

Counting sticks would have doubled the estimate and predicted twice the real
speed. `detect-hardware.ps1` parses `Win32_PhysicalMemory.DeviceLocator` for
`ChannelX` labels, falling back to slot-count heuristics.

If auto-detection is wrong, override it:

```powershell
.\scripts\detect-hardware.ps1 -ForceMemoryChannels 4
```

Rough reference points:

| Memory | Channels | Usable |
|---|---|---|
| DDR4-2133 | 2 | ~26 GB/s |
| DDR4-3200 | 2 | ~38 GB/s |
| DDR5-6000 | 2 | ~72 GB/s |
| DDR5-6000 | 4 | ~144 GB/s |

A DDR5-6000 machine runs offloaded models ~3× faster than the reference box.
That changes which tier is comfortable, which is why sizing is automated.

---

## Usable VRAM, not total VRAM

Reserve **~1.5 GB** for the Windows desktop, browsers and other GPU consumers.
On the reference machine, 2.0 GB of 8 GB was already in use at idle.

```
usable_vram = total_vram − 1.5 GB
```

Then budget: **model weights + KV cache + a safety margin** must fit inside that.
Exceeding it does not error — it silently thrashes (see
[troubleshooting](troubleshooting.md)).

### Context length is part of the budget

KV cache grows with context. Two things shrink it:

- `OLLAMA_KV_CACHE_TYPE=q8_0` — roughly halves it versus f16.
- **Qwen3.8's hybrid attention** — 48 of its 64 layers use Gated DeltaNet (linear
  attention with a constant-size recurrent state), so only 16 layers hold a
  growing KV cache. Long context is unusually cheap on this family.

Even so, context was the deciding factor on an 8 GB card: 16384 ran at 39.8 tok/s,
24576 collapsed to 0.2.

---

## Tier table

`detect-hardware.ps1` maps usable VRAM to a plan:

| Usable VRAM | Agent | Uncensored | Notes |
|---|---|---|---|
| < 1 GB | `qwen3.5:4b` | Qwen3.8-9B Q4_K_S | CPU only; expect <5 tok/s |
| ≤ 6 GB | Qwen3-Coder 30B | Qwen3.8-9B IQ4_XS | MoE hybrid offload |
| ≤ 10 GB | Qwen3-Coder 30B | Qwen3.8-9B Q4_K_M | **reference machine** |
| ≤ 14 GB | Qwen3-Coder 30B | Qwen3.8-27B IQ2_M | 27B starts to be viable |
| ≤ 20 GB | Qwen3-Coder 30B | Qwen3.8-27B IQ4_XS | 27B mostly on GPU |
| ≤ 32 GB | Qwen3-Coder 30B | Qwen3.8-27B Q4_K_M | 27B fully on GPU — big jump |
| ≤ 64 GB | Qwen3-Coder-Next 80B-A3B | Qwen3.8-27B Q6_K | needs ≥64 GB RAM |
| > 64 GB | Qwen3-Coder-Next Q8_0 | Qwen3.8-27B Q8_0 | |

RAM gates the top tiers independently: Qwen3-Coder-Next is 52 GB at Q4 and is
auto-downgraded below 64 GB of system RAM.

---

## Sizing a better machine

The interesting threshold is **where the dense 27B fits entirely in VRAM**.

- **24 GB card (RTX 3090/4090/5090).** Qwen3.8-27B Q4_K_M (~16 GB) fits with room
  for a large context. Expect **30–45 tok/s** instead of 1.39 — a ~25× improvement
  purely from eliminating offload. The 27B stops being a curiosity and becomes
  usable interactively.
- **16 GB card.** IQ4_XS (~15.3 GB) *nearly* fits; you will be fighting the
  context budget. Prefer IQ3_M or stay on the MoE.
- **12 GB card.** Qwen3.8-9B at Q6_K fully resident, plus the MoE for agent work.

Faster system RAM helps only the offloaded portion. Going DDR4-2133 → DDR5-6000
roughly triples throughput for spilled models — meaningful for MoE hybrid, but
never competitive with fitting in VRAM.

**Priority order when upgrading:** more VRAM ≫ faster RAM ≫ faster CPU.
