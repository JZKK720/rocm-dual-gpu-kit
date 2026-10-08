# Strata deep-dive — Niko1221/Strata, applied to this box

> Research scratch, 2026-10-07. Companion to `FINDINGS.md` (2026-09-17).
> All Strata numbers below are the repo's own published measurements (Linux unless noted);
> all local numbers are from `FINDINGS.md` / repo memory, measured on this machine.

## 0. TL;DR

**Strata is a purpose-built engine for exactly the model family we run**
(Qwen3.8-Flash-Next, `qwen4exp`, 48 blocks × 512 experts × 10 active = 24,576
experts total — the same tensor layout `scan/gguf_meta.py` measured in our
Ollama GGUF). It replaces the "load the whole 111 GB GGUF and stream it from
disk" model with a **three-tier memory design**:

| Tier | What lives there | Our equivalent today |
|---|---|---|
| GPU VRAM | dense weights, attention/DeltaNet mixers, routers, shared experts, output head, MTP draft layer, hot expert cache, KV cache | Ollama puts the whole model on ONE GPU and pages the rest from disk |
| RAM (pinned) | **all** experts; CPU computes misses in place, overlapped with GPU | nothing — our RAM is idle while the NVMe streams |
| SSD | 28.8 GB PLE n-gram lookup table, a few rows per token | the entire 111 GB weight file is our "SSD tier" |

**Why this matters for us:** our measured bottleneck (FINDINGS.md §3) is NVMe
weight streaming at ~500 MiB/s. Strata's design makes the SSD hold only a
lookup table, not the weights. On a 64 GB RAM box the right Strata pack is
**IQ2_XS (39.2 GB RAM+VRAM total)** — vs our current 111 GB q4_K_M that
thrashes the pagefile (measured: pagefile grew 14.6 → 192 GB after one load).

**Windows support is real and matches our toolchain:** the ready-made
`strata-windows-x64-hip.zip` ships a HIP engine built on **AMD's TheRock ROCm
10.2.0a20260930** — the same TheRock lineage as this `c:\therock` workspace —
with cubins for **gfx1100 (our RX 7900 XTX) and gfx1151 (our Strix Halo iGPU)**
from release 0.1.40. No ROCm install, no compiler, no admin.

## 1. What Strata actually is (architecture)

### 1.1 The engine

- Single C++ engine, CUDA and HIP backends from the same source
  (`src/` = CUDA, `sycl/` = the HIP port, dpct-style `.dp.cpp` files).
- AMD HIP backend validated on **gfx1100 (RX 7900 XT/XTX)**, gfx1101, gfx1200,
  gfx1201, gfx1030 (RDNA2, community); **gfx1151 (Strix Halo) supported from
  0.1.40, experimental**.
- Uses RDNA2/3/4's signed integer dot instruction (`v_dot4_i32_i8`) for
  quantized kernels — wave32, 64 KiB LDS. Our gfx1100 and gfx1151 are both
  wave32 RDNA3/3.5, so the same kernels apply.
- Native IQ expert kernels (IQ2/IQ3/IQ4 gate+up on matrix cores), MMQ prompt
  experts, hipBLASLt-tuned dense GEMMs, paged KV cache with quantized formats.

### 1.2 The three memory tiers (DETAILS.md)

- **GPU:** attention + DeltaNet mixers, gated-residual weights, routers,
  shared experts, output head, MTP draft layer, KV cache (from 64K context:
  only the most-read part resident, the rest **streams from RAM**), plus an
  **expert cache** that fills remaining VRAM with the most-used experts and
  adapts to the conversation.
- **RAM:** all 24,576 experts, pinned. CPU computes non-cached experts in
  place (AVX-512/AVX2, ggml i-quant kernels) **at the same time** the GPU
  works on cached ones.
- **SSD:** the 28.8 GB n-gram (PLE) table, read unbuffered past the OS cache.

Key sizing rule from the repo: **every extra GB of VRAM holds ~700 more
experts, and every expert on the GPU is one the CPU doesn't compute.** More
VRAM matters more than faster compute.

### 1.3 Speculative decoding (the "eval" accelerator)

- The model's own **MTP draft layer** drafts up to 3 tokens; one pass over all
  48 layers verifies them → **2.4–3.2 tokens per pass**, 1.6–1.8× sooner,
  **bit-identical output** (the big model decides every word).
- **Prompt lookup** drafts up to 5 tokens from earlier context copies where
  measured acceptance says it pays (code edits 6–11% faster).
- Draft acceptance is a first-class metric in their benchmarks (see §3).

### 1.4 KV cache (what we asked about)

- Formats: **int8** (default), **q4_0**, **k8v4** (K int8 + V q4 hybrid).
- Our model's KV is tiny by design: only **12 of 48 layers** keep KV, GQA
  24:2 heads, head_dim 256 → at 32K ctx, fp16 KV ≈ 805 MiB (Strata's own
  layout math for this family). int8 halves it; q4_0 quarters it.
- **KV streaming** (from 64K ctx): only the most-read KV pages stay in VRAM,
  the rest streams from a pinned RAM copy. This is what makes 256K context
  fit a 16 GB card.
- Community matrix (RTX 4070 TiS): IQ2_XS + KV=int8 holds **87–95 tok/s
  decode from 32K to 256K ctx**; IQ3_XXS must drop to q4_0/k8v4 above 64K
  because its 47 GB of resident experts + int8 KV would exceed VRAM.

### 1.5 hipBLASLt tuning (the gfx1100-specific win)

Shipped calibration tables for **RX 7900 XTX**: `gfx1100-hipblaslt-100100 /
100200 / 100401 / 100500.txt`. Measured impact on gfx1100 (repo's own):

- ROCm 10.0.0 + 43-row table: 3,151-token prompt **711 → 938 tok/s (+31.9%)**,
  `fallbacks=0`, decode unchanged.
- ROCm 10.2.0a nightly + 100500 table: 131,071-token prompt **926 → 1,687
  tok/s (+82%)**.
- Without a table the engine falls back to plain hipBLAS; `STRATA_HIPBLASLT_VERBOSE=1`
  must report `fallbacks=0`.

## 2. Fit on THIS box (64 GB RAM, 7900 XTX 24 GB, Strix Halo iGPU)

| Strata pack | RAM+VRAM total | Fits 64 GB? | Notes |
|---|---:|---|---|
| Q2_0 | 37.6 GB | ✅ fastest | general use OK |
| **IQ2_XS** | **39.2 GB** | ✅ **recommended** | repo's default rec for 64 GB |
| IQ3_XXS | 47.0 GB | ⚠️ tight | "with little else open" |
| IQ3_S | 54.8 GB | ❌ | would repeat our pagefile problem |
| Coder (IQ1_M) | 29.6 GB | ✅ | code-only, weak in CJK (#438) |

Download: 66–76 GB per pack + ~6 GB MTP draft layer. Disk: we have one NVMe
(~500 MiB/s) — the download is one-time; runtime SSD traffic is only the PLE
table's few rows/token.

**Windows constraints that apply to us (AMD_HIP.md §Windows):**

- **One card per model** — `--gpus` (layer split) is Linux-only on Windows.
  So Strata here runs on the **RX 7900 XTX alone**; the iGPU cannot join the
  same model. (This is consistent with our own finding that Ollama's scheduler
  is single-GPU-per-model anyway.)
- Setup's WDDM budget correction matters: Windows `hipMemGetInfo` over-reports
  free VRAM (desktop holds some); the engine lowers it by the video-memory
  budget (`STRATA_WDDM_BUDGET=0` to disable). Our FINDINGS.md already
  documented the same over-report class of problem for the iGPU.
- No images on Windows yet; no calibration (`--calibrate` is NVIDIA-only).
- gfx1151 on Windows: code ships in the zip from 0.1.40 but is **untested on a
  Windows Strix Halo** — treat iGPU-side Strata as unvalidated.

**Expected performance (grounded extrapolation, flagged as estimate):**

- Repo's gfx1100 Linux numbers (IQ3_XXS, 7950X3D, 64 GB): prefill ~900–966
  tok/s warmed, decode ~55–59 tok/s.
- Repo's Strix Halo Linux numbers (128 GB, UD-IQ4_XS): prompt ~1,200–1,300
  tok/s, output ~50–54 tok/s.
- Our box: 64 GB RAM (not 128) → IQ2_XS on the 7900 XTX; CPU is the unknown
  (repo used 7950X3D/9800X3D-class AVX-512 parts). **Assumption to verify:
  decode lands somewhere in the 40–60 tok/s band vs Ollama's current
  disk-stream-bound single digits-to-tens.** Must be measured, not assumed.

## 3. The eval methodology (what to adopt)

Strata's benchmark discipline (from `bench/results/2026-10-01-ctx-ladder/matrix.md`
and `AMD_HIP_PERFORMANCE.md`) is directly reusable against Ollama too:

1. **Cold prefill probe**: `POST /unload` (Ollama: `keep_alive=0`), then one
   non-streaming `max_tokens=1` call; read `prompt_per_second`. This is the
   true end-of-prompt throughput, uncontaminated by cache reuse.
2. **Three SSE streaming calls** per row, fixed `max_tokens=192`, `t=0`
   (greedy), reasoning effort minimal; report **avg / peak / engine TPS** and
   **TTFT** separately.
3. **Medians of 3**, and for A/B: **interleaved pairs** (arm A, arm B, arm A,
   arm B...) — never sequential blocks (clock ramping bias; their own note:
   the first timed case of a fresh process reads low while clocks ramp).
4. **Discard the first fresh prompt after model load** — it is cold (their
   measurement: 949 vs 1,423 tok/s spread on identical config).
5. **Zero-reuse enforcement**: fresh prompts must share no tokens with prior
   prompts; cached follow-ups reported separately, never mixed into prefill
   numbers.
6. **Never use cancelled-request timing as throughput evidence.**
7. **Report draft acceptance** (accepted/drafted) as a column — it explains
   decode variance.
8. **Bit-identical output check for A/B of speed-only knobs**: same token ids
   across arms proves a switch changed speed, not answers.
9. **KV choice per context rung**: int8 while it fits; step down (q4_0/k8v4)
   only when resident weights + KV would exceed VRAM.

### Applying it to our Ollama setup today (no new software)

Ollama equivalents, all measurable with the same harness pattern:

| Strata knob | Ollama equivalent | Status on our box |
|---|---|---|
| KV int8/q4_0 | `OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0` (or `q4_0`) | **not set** — quick win, esp. for ctx > 8K |
| context rung ladder | `num_ctx` 8K→32K→64K with KV quant on/off | our Modelfile pins `num_ctx 4096` |
| cold prefill probe | `keep_alive: 0` + 1-token call | adopt |
| 3× SSE, t=0, 192 tokens | `/api/generate` stream | adopt |
| interleaved A/B medians | same | adopt |
| draft acceptance | n/a (Ollama has no MTP for this model) | — |

Caveat from our own FINDINGS.md: for the **111 GB q4_K_M via Ollama**, KV
tuning moves ~7% of footprint while the bottleneck is weight streaming —
KV quant will NOT fix Ollama's throughput on this model. It *is* the right
lever once the model itself fits (i.e., under Strata, or a smaller Ollama
model on the dGPU).

## 4. Application plan (ordered)

### Phase 0 — measure the baseline (Ollama, today)

Write `scan/bench-ollama.ps1` implementing §3 against Ollama's API:
cold prefill probe + 3× SSE at 8K/32K prompts, `num_ctx` ladder with
`OLLAMA_KV_CACHE_TYPE` ∈ {f16, q8_0, q4_0} as interleaved A/B arms.
Deliverable: a `matrix.md` in the same shape as Strata's.

### Phase 1 — install Strata Windows HIP engine

1. Download a Strata release ≥ 0.1.40, run `START-HERE.bat --backend hip`
   (picks AMD directly on a dual-AMD box).
2. Model: **IQ2_XS** (64 GB RAM rec). Context: start 32K, KV **int8**.
3. Verify `engine\strata-device.exe --list-devices` sees the 7900 XTX as a HIP
   device (with an iGPU present it may be device 1, not 0 — #325).
4. The engine ships its own TheRock ROCm libs in `engine\rocm\bin`; do **not**
   let system HIP SDK 7.1/7.2's `amdhip64_7.dll` shadow it (the zip puts its
   own copy next to `strata.exe` precisely because of this; the log line
   `strata generate: HIP runtime ...` names what loaded).
5. gfx1100 hipBLASLt table ships with the zip; confirm the startup line
   reports tuning enabled and (with `STRATA_HIPBLASLT_VERBOSE=1`) `fallbacks=0`.

### Phase 2 — benchmark Strata vs Ollama with the same harness

Same matrix.md shape: cold prefill, 3× SSE, medians, TTFT, draft acceptance.
Arms: Ollama q4_K_M (baseline) vs Strata IQ2_XS @ 8K/32K/64K, KV int8.
Quality spot-check: same prompts, compare answers (Strata's IQ2_XS is a
different quant of the same model — expect near-parity, verify on our prompts).

### Phase 3 — tune

- Context ladder 32K → 64K → 128K with KV streaming (int8 holds per the
  community matrix).
- `--mtp-window 8192`, `--spec 4`, `--lookup-chain 3`, `--mtp-q4 all` (the
  repo's long-context flags; verify bit-identical outputs between arms).
- If a ROCm version mismatch refuses the shipped gfx1100 table, recalibrate
  with `tune_hipblaslt` (few minutes) — but on Windows the zip's bundled
  ROCm should match its own table.

### Phase 4 — the iGPU question (explicitly deferred)

- Strata on Windows cannot split across both cards. The iGPU's role stays
  what the kit already uses it for: a second concurrent model (Ollama) or
  future Linux Strata work (`--gpus` layer split IS supported on Linux AMD,
  and gfx1151+gfx1100 are both supported arches there — a genuine future
  path, but a Linux install is out of scope today).
- Non-peers constraint (spec 001) is irrelevant to Strata's design: it never
  needs P2P; its multi-GPU path routes experts per-card with host staging.

## 5. What Strata does NOT solve for us

- The 111 GB q4_K_M GGUF itself: Strata doesn't consume Ollama GGUFs; it uses
  its own packed formats (GSQ-RCO / Unsloth packs). The 111 GB file remains
  Ollama-only.
- Windows dual-GPU layer split (Linux-only).
- Vision on Windows.
- Any claim about answer quality: the repo's own docs cap throughput claims
  and require independent task-level validation — same discipline we should
  apply.

## 6. Sources

- `docs/AMD_HIP.md` (Windows section, tuning table, build)
- `docs/AMD_HIP_PERFORMANCE.md` (gfx1100 measured config + bench harness rules)
- `docs/STRIX_HALO.md` (gfx1151 defaults, opt-in fast switches, measured table)
- `docs/HOW_IT_WORKS.md`, `docs/DETAILS.md` (tier design, MTP, KV)
- `docs/MODELS.md` (pack sizing by RAM), `docs/MULTI_GPU.md` (split rules)
- `bench/results/2026-10-01-ctx-ladder/matrix.md` (KV-per-context evidence)
- `docs/OLDER_GPUS.md` (support matrix)
