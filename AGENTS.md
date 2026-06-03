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
    │
    └── 7. If anything fails, see [README.md "Known issues" section](README.md).
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

## Related skills

If you're running this in an environment with agent skills (e.g. `~/.agents/skills/`), see [SKILL.md](SKILL.md) in this kit for the structured skill format. The two files are complementary:
- `AGENTS.md` — quick reference, expected to be skimmed by any agent
- `SKILL.md` — step-by-step recipe for the `rocm-dual-gpu-kit` skill, with frontmatter
