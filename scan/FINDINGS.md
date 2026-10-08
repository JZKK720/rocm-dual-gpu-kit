# Findings — qwen3.8-flash-next:125b on the Strix Halo + RX 7900 XTX box

> **NOT part of the kit.** Ad-hoc investigation scratch, collected 2026-09-17.
> All numbers below are measured on this machine, not estimated.

## The question

> We downloaded `qwen3.8-flash-next:125b-a6b-q4_K_M`. Can we tune ctx + KV cache,
> and redistribute the model to fit in both iGPU and dGPU to accelerate output?

## Short answer

**No to both.** Redistribution cannot help (the two GPUs are *not* additive
memory), and ctx/KV tuning moves ~7% of the footprint while the bottleneck is
disk streaming of the weights themselves.

## 1. What the model actually is

Measured from the GGUF header (`scan/gguf_meta.py`, `scan/gguf_tensors.py`):

| Property | Value |
|---|---|
| Architecture | `qwen4exp` |
| Parameters | 176.9 B (size label `512x56B`) |
| Blocks | 48 |
| Experts | 512 total, **10 active** per token (+ shared expert) |
| Full-attention interval | 4 → only **12** of 48 layers keep a KV cache |
| `head_count` / `head_count_kv` | 24 / **2** (GQA 12:1) |
| `key_length` / `value_length` | 256 / 256 |
| Native context | 262144 |
| On disk | 110.97 GB weights + 0.85 GB projector = **111.81 GB** |

Tensor breakdown: **67.6%** is routed MoE experts, **29.8%** is embeddings
(one `per_layer_token_embd.weight` is 33.5 GiB alone), attention is only 0.8%.

## 2. Redistribution is impossible — the memory is NOT additive

The kit's docs claim "Total VRAM: 111.9 GB (87.9 + 24.0)". That is wrong.

| Source | iGPU | dGPU |
|---|---|---|
| `hipInfo totalGlobalMem` | 99.74 GB | 23.98 GB |
| Ollama Vulkan view | 111.6 GiB total / 106.1 free | 24.0 GiB |
| AMD registry `qwMemorySize` | **exactly 64.00 GiB** | 23.98 GiB |

The iGPU is a **UMA device with no dedicated memory**. It draws from the same
physical RAM the CPU does. Its `qwMemorySize` is 64 GiB — numerically identical
to system RAM:

```
Physical modules populated : 128.0 GiB   (8 x 16 GB)
PhysicalMemoryArray max    :  64.0 GiB
OS TotalVisibleMemory      :  63.6 GiB
iGPU driver qwMemorySize   :  64.0 GiB
```

So the real addressable total is:

```
system RAM (shared with iGPU)  63.65 GiB
dGPU dedicated                 23.98 GiB
                               -----------
real ceiling                   87.63 GiB
model requirement            ~110.46 GiB   -> DOES NOT FIT
```

The requirement is measured, not estimated: Ollama's own buffer accounting is
`79536.97 MiB (host-mapped) + 33569.50 MiB (PLE) = 113,106 MiB`.

The iGPU's advertised "99.7 GiB free" is a WDDM aperture over-report, not
allocatable memory. Proof — forcing the model onto the iGPU alone:

```
HIP_VISIBLE_DEVICES=0, OLLAMA_VULKAN=false
  ROCm0 reported: 102129 MiB total, 101974 MiB free
  ERROR: failed to allocate ROCm0 buffer of size 83582021888
         (77.8 GiB) -- with 99.5 GiB reported "free"
```

It cannot allocate the memory it advertises.

## 3. What Ollama actually does today

```
llama_prepare_model_devices: using device ROCm1 (AMD Radeon RX 7900 XTX)
load_tensors: offloaded 49/49 layers to GPU
load_tensors:        ROCm1 model buffer size = 20408.94 MiB   <- only ~20 GiB on GPU
load_tensors:   CPU_Mapped model buffer size = 79536.97 MiB   <- ~78 GiB host-mapped
load_tensors:   CPU_Mapped model buffer size = 33569.50 MiB   <- PLE embedding
```

- The **dGPU** is chosen; the iGPU is never a candidate.
- ~20 GiB is GPU-resident; the balance is memory-mapped from host and
  backs onto the **pagefile**.

## 4. The real bottleneck: disk

Measured during live generation (`scan/measure-io.ps1`):

| Metric | Value |
|---|---|
| Avg disk read during generation | **294.7 MiB/s** |
| Peak disk read | **507.3 MiB/s** |
| Page reads | up to **9,149 /s** |
| Available RAM (min) | 6.76 GiB |
| Pagefile used | 66.9 GB (peak **88.8 GB**) |
| Generation | 4.9 – 8.4 tok/s |

The model is **streaming off NVMe**, not running from memory. That single
500 MB/s NVMe link is the ceiling, and it is ~8x slower than the iGPU's
LPDDR5X bandwidth (~500 GB/s), which is itself unused.

## 5. Why ctx + KV tuning cannot fix this

The KV cache for this architecture is unusually small because
`full_attention_interval = 4` — only 12 of 48 layers hold KV, and GQA keeps it
at 2 KV heads. Measured from Ollama's own log:

| Context | KV cache total |
|---|---|
| 262144 (max) | 6,144 + 2,304 + 113 = **8,560 MiB** |
| 8192 | 192 + 72 + 113 = **376 MiB** |

Dropping 256K → 8K frees **~8.0 GiB** out of a ~110 GiB footprint = **7.2%**.

But the bottleneck is disk streaming of *weights*, which context does not change.
Expected throughput gain: **~0–2%.** Not the lever.

Enabling `OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0` (currently
both off/empty) would roughly halve KV again — another ~4 GiB at max ctx.
Still marginal for the same reason.

## 6. Why multi-GPU spread cannot help either

Three independent blockers:

1. **Ollama picks one device per model.** `llama_prepare_model_devices: using
   device ROCm1` — singular. Verified with `OLLAMA_SCHED_SPREAD=1` set in both
   the registry *and* the parent session so the child process genuinely
   inherited it: placement was **byte-identical** to `OLLAMA_SCHED_SPREAD=0`
   (`ROCm1 model buffer size = 20951.58 MiB` both runs).

2. **The GPUs are non-peers.** `hipInfo` reports
   `non-peers: device#0 device#1`. Every layer boundary would stage through
   host RAM — the same pool the iGPU already consumes, and the same pool
   backing the pagefile that is currently thrashing.

3. **It would not fit even if it worked.** Perfect 64/24 split still totals
   87.63 GiB against a measured ~110.5 GiB requirement.

## 7. What would actually help

| Option | Effect |
|---|---|
| Smaller quant of the same model (Q3_K_XL / IQ2_M) | Directly shrinks the 110 GB. The only lever that addresses the real constraint. |
| A smaller MoE — e.g. `ornith-1.5:35b` (22 GB), `nemotron-3.5-lightning:30b-a3b` (25 GB) | Both already fit fully in GPU memory. Verified: nemotron-3.5 loads at **100% GPU**. |
| Keep `OLLAMA_CONTEXT_LENGTH=8192`, add `OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0` | Frees ~12 GiB total; helps at the margin by reducing pagefile pressure. |
| Do **not** reduce iGPU VRAM in BIOS | The iGPU carve-out is already capped at 64 GiB; shrinking it further removes the only large pool available. |

## 8. Kit documentation drift found

| Kit claim | Measured reality |
|---|---|
| iGPU "87.9 GB" / "88 GB" | `hipInfo` 99.74 GB; driver 64 GiB; allocatable much less |
| "Total VRAM: 111.9 GB" | Not additive — iGPU is UMA, shares system RAM |
| Ollama 0.30.11 | **0.34.1** |
| HIP SDK 7.1.0 | Both 7.1 and 7.2 present; `HIP_PATH` → **7.2** |
| "`start-split-model.ps1` uses bundled llama-server" | `llama-server.exe` is a 20 KB stub; impl is `libllama-server-impl.dll` |
| "`LLAMA_ARG_DEVICE=0,1` crashes: invalid device" | `LLAMA_ARG_` passthrough **is** present in `ollama.exe` |
| "`OLLAMA_SCHED_SPREAD`" not mentioned | Present in 0.34.1 (but did not change placement here) |

## 9. Side effect of loading this model (action needed)

Loading this model once is not free. The system-managed pagefile grew from
**14.6 GB → 192 GB** to absorb the host-mapped weights:

| | Before tests | After tests |
|---|---|---|
| `pagefile.sys` allocated | 14.6 GB | **192 GB** |
| Total virtual memory | 78.3 GB | 255.6 GB |
| Peak pagefile usage | 13.8 GB | **91.7 GB** |

Windows does **not** shrink a system-managed pagefile automatically. The file
stays large until reboot or an explicit shrink, so ~177 GB of disk is currently
held for a model that is no longer loaded (`ollama ps` is empty).

To reclaim it, either reboot, or set an explicit cap:

```powershell
# 1. Stop the auto-managed pagefile
$cs = Get-WmiObject Win32_ComputerSystem -EnableAllPrivileges
$cs.AutomaticManagedPagefile = $false
$cs.Put()

# 2. Cap it (adjust to taste; 16-32 GB is ample when this model is unloaded)
Set-WmiInstance -Class Win32_PageFileSetting -Arguments @{
    Name = "C:\pagefile.sys"; InitialSize = 16384; MaximumSize = 32768
}

# 3. Reboot, then re-check
Get-CimInstance Win32_PageFileUsage | Select-Object Name, AllocatedBaseSize
```

Leave the pagefile generous if this model is going to be used routinely — the
thrashing in §4 *is* the pagefile doing its job.

## Scripts in this folder

| Script | Purpose |
|---|---|
| `gguf_meta.py` | Parse GGUF header + KV metadata |
| `gguf_tensors.py` | Per-tensor sizes grouped by role |
| `scan_bins.py` | Confirm which env vars a binary honours |
| `collect.ps1` | RAM/GPU/Ollama env evidence dump |
| `probe_vram.ps1` | DXGI + AMD registry memory probe |
| `probe_mem.ps1` | Pagefile / commit-limit / UMA carve-out |
| `bench-ctx.ps1` | Throughput at a given ctx |
| `measure-io.ps1` | **Bottleneck classifier (disk vs RAM vs GPU)** |
| `test-spread-correct.ps1` | `OLLAMA_SCHED_SPREAD` A/B with verified inheritance |
| `force-igpu-real.ps1` | Force iGPU-only; reproduces the allocation failure |

All scripts are read-only except the env-var setters, which each ship a
`-Restore` switch. Environment was returned to its original state after testing.

**Superseded iterations** (kept for the audit trail, do not use):
`experiment-spread.ps1`, `test-spread-fast.ps1`, `test-125b-split.ps1`,
`test-igpu-only.ps1`, `force-igpu.ps1`. Each had a confound that
`test-spread-correct.ps1` / `force-igpu-real.ps1` fixed:

- `SetEnvironmentVariable(...,'User')` writes the registry but does **not**
  update the running session, so child processes never inherited the flag.
  Two runs that appeared to differ were both silently using the default.
- `HIP_VISIBLE_DEVICES=0` alone does **not** hide the dGPU, because
  `OLLAMA_VULKAN=true` (the 0.34.1 default) enumerates both GPUs independently
  of the HIP device list. Vulkan must be disabled too, or Ollama silently
  falls back to the dGPU.
