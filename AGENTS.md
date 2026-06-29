<!--
  rocm-dual-gpu-kit
  Copyright 2026 cubecloud Limited (https://cubecloud.io)
  SPDX-License-Identifier: Apache-2.0
-->

# AGENTS.md — Agent Quick-Start Contract

> **Read this file FIRST if you are a coding agent helping someone set up dual-GPU ROCm using this kit.**

This file is the **fast-path contract for AI agents** (GitHub Copilot, Claude, etc.). For the full method, see [README.md](README.md).

## Purpose

The `rocm-dual-gpu-kit` reproduces a working dual-GPU ROCm setup on any AMD box with:
- An AMD **iGPU** (integrated in the AMD APU) — pinned to a TheRock Python venv
- An AMD **dGPU** (discrete GPU) — pinned to the system AMD HIP SDK

The user has a similar machine. Your job is to detect what they have and apply the same method, then validate.

## Non-negotiable invariants

Read these before doing anything else. Violating any of them will break the setup.

1. **iGPU uses TheRock pip wheels; dGPU uses HIP SDK system install.** Never swap these targets.
2. **Install order**: 3 wheel packages FIRST (`rocm_bootstrap`, `rocm-sdk-core`, `rocm-sdk-devel`, `rocm-sdk-libraries-<target>`), THEN the `rocm` meta sdist. The meta provides the importable `rocm_sdk` module — without it, `python -m rocm_sdk` errors with "No module named rocm_sdk".
3. **`HIP_PATH` shadowing**: HIP SDK 7.1.0's `hipconfig` reads `HIP_PATH` from env. The iGPU venv's `HIP_PATH` will shadow the dGPU's. Activation scripts MUST clear and re-set `HIP_PATH` to the HIP SDK dir.
4. **`hipcc.bat` mishandles paths with spaces**. Always invoke `clang.exe` directly with `--driver-mode=g++ --hip-link`. Never use `& hipcc ...` for paths with spaces.
5. **`--offload-arch=<dGPU-arch>` is mandatory** for HIP SDK compile. Default is `gfx906`, which will produce "device kernel image is invalid" at runtime if the dGPU is different.
6. **Driver-level `non-peers`**: most iGPU+dGPU pairs are non-peers. Direct GPU-GPU copy doesn't work. Use host-memory staging.
7. **Driver is the source of truth for `gcnArchName`**. Always run `hipInfo` from each ROCm install and confirm the targets before committing to a setup.

## Quick decision tree

```
User wants dual-GPU ROCm setup
    │
    ├── 1. Run detect-hardware.ps1 from this kit (auto-detects iGPU/dGPU arch, paths, MSVC, SDK, HIP SDK)
    │      → outputs DETECT_IGPU_ARCH, DETECT_DGPU_ARCH, DETECT_HIP_SDK, DETECT_MSVC_INC, etc.
    │
    ├── 2. Ask the user (or detect):
    │      a. Is HIP SDK 7.1.0+ already installed?  If NO → instruct to install first.
    │      b. Is VS 2022 BuildTools installed?       If NO → dGPU C++ compile won't work; runtime only.
    │      c. Is Python 3.12.x installed?            If NO → install from python.org first.
    │      d. Is AMD Adrenalin driver installed?     If NO → install first.
    │
    ├── 3. Run install-igpu-venv.ps1 — auto-installs the iGPU TheRock venv.
    │
    ├── 4. Run rewire-igpu.ps1 — user-scope rewire (no UAC), then machine-scope rewire (UAC).
    │      Snapshots env to env-backup.xml and env-backup-machine.xml for rollback.
    │
    ├── 5. Drop activate-dgpu.ps1 / deactivate-dgpu.ps1 in any convenient dir.
    │      No global rewire for dGPU — activation only.
    │
    ├── 6. Run validate.ps1 — end-to-end smoke test.
    │      Expected: iGPU rocm-sdk test 26/26 (1 Linux-only skip), dGPU vector_add PASS.
    │      If dGPU side fails, validate.ps1 auto-invokes diagnose-connection.ps1 and prints a
    │      per-layer verdict (form factor, USB4/TB4 topology, PCIe, AMD driver, HIP runtime, venv).
    │
    ├── 7. Run diagnose-connection.ps1 on demand — same verdict table, no driver / firmware change.
    │      Use this when the dGPU or USB4 dock is "not recognized", or to scan a new machine
    │      before committing to the install. Read-only: it never mutates registry, drivers, or env.
    │      Suggested next block in the output points to the most relevant kit command.
    │
    └── 8. If anything fails, see [README.md "Known issues" section](README.md).
```

## Per-hardware adaptation

If the user's hardware differs from the verified Strix Halo + RX 7900 XTX, edit the right script(s) before running. The README's "Adapting to other hardware" table covers most cases. Common changes:

| If user has | Edit |
|---|---|
| Strix Point iGPU (gfx1155) | `install-igpu-venv.ps1` → `$INDEX = 'https://repo.amd.com/rocm/whl/gfx1151/'` (try first) |
| Rembrandt / Phoenix iGPU (gfx1103) | `$INDEX = 'https://repo.amd.com/rocm/whl/gfx110X-all/'` |
| RX 7600 XT dGPU (gfx1100) | Already supported by HIP SDK 7.1.0; no edit needed |
| RX 9070 dGPU (gfx1201) | Verify HIP SDK supports gfx1201; may need HIP SDK upgrade |
| Visual Studio BuildTools missing | dGPU C++ compile step will fail; runtime only |

## Disk budget

- iGPU TheRock venv: ~22 GB
- HIP SDK 7.1.0: ~3 GB
- dGPU C++ toolchain uses HIP SDK + MSVC; no extra disk

If the user has < 30 GB free on C:, warn them before installing.

## Disk reclaim guidance

Use a read-first triage for any "free space on C:\" request. The kit itself is not a cleanup tool, so separate disposable artifacts from runtime dependencies before suggesting deletions.

- Safest large reclaim target: `C:\rocm-sdk\cache` after a successful install, if the user does not need an offline reinstall cache.
- Usually safe: generated test outputs or logs under `C:\rocm-sdk-dgpu\`, plus repo-local diagnostic logs such as `validate.log`, `diagnose-connection.log`, and `dgpu-probe.log`.
- Keep by default: `C:\rocm-sdk\.venv` and `C:\Program Files\AMD\ROCm\...` unless the user explicitly wants to uninstall or rebuild the setup.
- Keep until rollback is no longer needed: `C:\rocm-sdk\env-backup.xml` and `C:\rocm-sdk\env-backup-machine.xml`.
- After removing `C:\rocm-sdk\.venv`, clear the dangling user-scope `HIP_PATH` and `LLVM_PATH` env vars so they don't point at a deleted path.
- Always measure size first, then report candidate path, estimated savings, and risk level before deleting anything.
- For whole-drive Windows cleanup beyond the kit, also consider: `C:\hiberfil.sys` (disable hibernation), `C:\pagefile.sys` (shrink after reboot), `C:\Windows\WinSxS` (`dism /Online /Cleanup-Image /StartComponentCleanup`), user-profile browser/VS Code caches, and `C:\Windows\Logs`.

## When NOT to use this kit

- macOS or Linux (kit is Windows-specific)
- NVIDIA-only systems (ROCm doesn't apply)
- AMD APU with no dGPU (use just the TheRock venv part)
- APU + dGPU from the same RDNA generation where the iGPU arch matches the dGPU's, e.g. RDNA3-only box (likely simpler: single TheRock venv covers both)

## Files you should never edit by hand

- The 8 `.ps1` scripts — they have a cubecloud Apache 2.0 copyright header. If you need to customize, copy to a new name first.
- `LICENSE` and `NOTICE` — these are the legal text. Don't modify.
- `kit.json` — read-only metadata; if you need to record a new verified-hardware combo, append to the JSON, don't replace.

## What to report back to the user

After running the kit:
1. `validate.ps1` output (iGPU rocm-sdk test count, dGPU vector_add PASS/FAIL)
2. `rocm-sdk version` (should be 7.13.0 or whatever current is)
3. `rocm-sdk targets` (should be the iGPU arch)
4. `hipconfig --version` and `hipconfig --rocmpath` after `activate-dgpu.ps1` (should report HIP SDK 7.x)
5. Disk free before and after (the kit doesn't reclaim disk; it consumes ~25 GB)
6. Any deviations from the README (e.g. "I had to use gfx12-generic because gfx1151 doesn't have wheels yet")

## Ollama dual-GPU acceleration (v1.2.0)

The kit now includes tools to accelerate local LLM inference using both GPUs simultaneously.

### Non-peers VRAM constraint (verified)

`hipInfo` reports both devices as `non-peers` on Strix Halo + RX 7900 XTX:
- `hipDeviceCanAccessPeer(0→1)`: 0 (no direct peer access)
- `hipDeviceCanAccessPeer(1→0)`: 0 (no direct peer access)
- `hipDeviceEnablePeerAccess`: fails with err=101
- `hipMemcpyPeer`: **works** — HIP SDK 7.1.0 transparently falls back to host-memory staging

Run `test-peer-vram.ps1` to verify on any box. Expected: `PEER COPY: PASS (transparent host staging)` and `STAGING COPY: PASS`.

### Ollama scheduler behavior (verified)

Ollama's scheduler is **architecturally single-GPU-per-model**:
- `NO_PEER_COPY=1` is set by llama.cpp when non-peers are detected
- The scheduler picks one GPU per model load (`sched.go:1024 "selecting single GPU"`)
- When a model exceeds one GPU's VRAM, it overflows to **system RAM (CPU)**, not the other GPU
- `LLAMA_ARG_SPLIT_MODE=layer` env var is inherited by llama-server but doesn't work because the runner doesn't pass `--device 0,1`
- `LLAMA_ARG_DEVICE=0,1` env var crashes: `invalid device: 0` (bundled llama-server has no GPU support compiled in)

### Working: two models, two GPUs (Option 1)

`configure-ollama-dual-gpu.ps1` sets user-level env vars and restarts the Ollama tray app:
- `OLLAMA_MAX_LOADED_MODELS=2` — allow 2 models in VRAM simultaneously
- `OLLAMA_IGPU_ENABLE=1` — enable the iGPU (87 GB VRAM)
- `HIP_VISIBLE_DEVICES=0,1` — both GPUs visible

After running it, load two models:
- Large model (e.g., gemma4:26b, ~28 GB) → lands on iGPU (87 GB)
- Small model (e.g., gemma4:12b, ~12 GB) → lands on dGPU (24 GB)

Concurrent requests to different models run in parallel on different GPUs.

Revert: `.\configure-ollama-dual-gpu.ps1 -Revert`

### Not working: forced layer split (Option 2)

`start-split-model.ps1` attempts `--split-mode layer --tensor-split 0.78,0.22` via the bundled llama-server, but Ollama's `llama-server.exe` is compiled without GPU support. The actual GPU offload happens through Ollama's runner which dynamically loads `ggml-hip.dll`. The standalone binary cannot use `--split-mode` or `--tensor-split` with GPU.

### Recommendation

| Workload | Best approach |
|---|---|
| Single large model (≤ 87 GB) | Use iGPU alone (87 GB VRAM fits most models) |
| Multiple users / models | Option 1: two models, two GPUs (`configure-ollama-dual-gpu.ps1`) |
| Model too large for iGPU alone | Reduce context size or use Q4 quantization |

**Do not reduce iGPU VRAM to add more system RAM.** The iGPU's 87 GB unified memory is the single biggest advantage of this box. CPU overflow is 10-50x slower than GPU. The NPU (XDNA) is not used by Ollama/llama.cpp.

## Related skills

If you're running this in an environment with agent skills (e.g. `~/.agents/skills/`), see [SKILL.md](SKILL.md) in this kit for the structured skill format. The two files are complementary:
- `AGENTS.md` — quick reference, expected to be skimmed by any agent
- `SKILL.md` — step-by-step recipe for the `rocm-dual-gpu-kit` skill, with frontmatter
