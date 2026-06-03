---
name: rocm-dual-gpu-kit
description: "Reproducible AMD dual-GPU ROCm setup: TheRock pip wheels for the iGPU + HIP SDK 7.1.0 for the dGPU. Detects hardware (Strix Halo, Strix Point, Phoenix, Rembrandt, Van Gogh, RDNA 3/4) and adapts. Use when the user wants to set up, validate, or troubleshoot a dual-GPU ROCm box on Windows. Triggers: 'set up ROCm on this box', 'make my dGPU work', 'install AMD HIP', 'reproduce the cubecloud dual-GPU setup', 'gfx1151 / gfx1100 / gfx1201 setup', 'TheRock pip install', 'Strix Halo GPU setup', 'RX 7900 XTX ROCm', 'rebuild iGPU venv'."
license: Apache-2.0
metadata:
  author: cubecloud Limited
  homepage: https://cubecloud.io
  repository: https://github.com/JZKK720/rocm-dual-gpu-kit
  version: "1.0.0"
  applies_to: Windows 11
  python: "3.12.x"
  amd_driver: "Adrenalin 32.0.31019.2002 (or later)"
argument-hint: "[skip-to-step N] | [validate-only] | [rollback]"
---

# ROCm Dual-GPU Kit (Skill)

This skill walks the user through reproducing the **cubecloud Option 2** dual-GPU ROCm setup on a Windows machine. The pattern was developed on AMD Strix Halo (gfx1151 iGPU) + RX 7900 XTX (gfx1100 dGPU) and is portable to other AMD iGPU/dGPU combinations.

> **Argument hint:**
> - `skip-to-step N` — resume from a specific step (1-6)
> - `validate-only` — skip install, just run the validation
> - `rollback` — restore the env from the snapshot taken during step 4 (rewire)

## When to use

- User has a Windows box with an AMD APU iGPU + AMD dGPU and wants both functional in ROCm
- User has a working setup and wants to validate it
- User wants to roll back a previous rewiring
- User has a different AMD GPU pair and wants the method adapted

## When NOT to use

- Linux / macOS (kit is Windows-specific)
- NVIDIA-only systems
- Single-GPU boxes (use TheRock pip wheels directly without the dGPU phase)
- Apple Silicon

## Quick reference

| Property | Value |
|---|---|
| Method | Option 2: iGPU = TheRock venv, dGPU = HIP SDK |
| Disk | ~25 GB (iGPU venv 22 GB + HIP SDK 3 GB) |
| Languages | README in EN / zh-CN / ja-JP / ko-KR |
| License | Apache 2.0 (cubecloud Limited) |
| Verified on | Strix Halo + RX 7900 XTX, Adrenalin 32.0.31019.2002, HIP SDK 7.1.0, TheRock 7.13.0 |

## Steps

Follow each step in sequence unless the user provides `skip-to-step N`.

### Step 1 — Pre-flight: verify prerequisites

Ask or check:
- [ ] AMD Adrenalin / Adrenalin PRO driver installed (enumerates both GPUs)
- [ ] AMD HIP SDK 7.1.0+ installed (default path: `C:\Program Files\AMD\ROCm\7.1\`)
- [ ] Python 3.12.x installed (default: `C:\Program Files\Python312\python.exe`)
- [ ] VS 2022 BuildTools with C++ workload + Windows SDK (optional, for dGPU C++ compile)
- [ ] ~30 GB free disk on C:

If any are missing, instruct the user to install before continuing. **Do not proceed with installation if HIP SDK is missing — the dGPU side will not work.**

Then run `hipInfo.exe` from the HIP SDK and **record** each device's `gcnArchName`. This is what determines the iGPU vs dGPU targets.

### Step 2 — Detect hardware and pick the right targets

Run `detect-hardware.ps1` from this kit. It auto-detects:
- iGPU arch (heuristic: name contains "Graphics" but not "RX" → iGPU)
- dGPU arch (everything else)
- HIP SDK install path
- MSVC v14.44 path
- Windows SDK 10.0.26100 path
- Python 3.12 path

It sets env vars `DETECT_IGPU_ARCH`, `DETECT_DGPU_ARCH`, `DETECT_HIP_SDK`, `DETECT_MSVC_INC`, `DETECT_SDK_INC`.

If detection fails, ask the user to run `hipInfo` manually and report both `gcnArchName`s.

### Step 3 — Install the iGPU TheRock venv

Run `install-igpu-venv.ps1`. It:
1. Creates `C:\rocm-sdk\.venv` with Python 3.12
2. Pre-downloads `rocm_bootstrap`, `rocm-sdk-core`, `rocm-sdk-devel`, `rocm-sdk-libraries-<iGPU-target>`, `rocm` to a local cache
3. Installs the 3 wheels first, then the `rocm` meta sdist
4. Runs `rocm-sdk version`, `targets`, `test` to verify

**Important install order** — install the 3 wheel packages first, then the `rocm` meta sdist. Skipping the meta leaves `rocm_sdk` module unimportable.

Expected output: `rocm-sdk version` = 7.13.0 (or current), `rocm-sdk test` = 26/26 with 1 Linux-only skip.

### Step 4 — Rewire env (machine scope, UAC)

Run `rewire-igpu.ps1`. It:
1. Snapshots user + machine env to `C:\rocm-sdk\env-backup.xml` and `env-backup-machine.xml`
2. Sets `HIP_PATH` = iGPU venv's `_rocm_sdk_core` dir (user scope)
3. Sets `LLVM_PATH` = iGPU venv's `_rocm_sdk_devel\lib\llvm` (user scope)
4. Prepends venv's `bin` and `llvm/bin` to user PATH
5. Re-runs (1)-(4) at machine scope via UAC (Start-Process -Verb RunAs)

After this step, **the iGPU venv wins globally**. Open a fresh PowerShell and verify:
```powershell
Get-Command hipconfig, hipcc, rocm-sdk, clang | Select-Object Name, Source
```
All four should resolve to `C:\rocm-sdk\.venv\...`.

To undo: `rollback-rewire.ps1`.

### Step 5 — Set up the dGPU activation helper

Drop `activate-dgpu.ps1` and `deactivate-dgpu.ps1` in any directory (e.g. `C:\rocm-sdk-dgpu\`). These:
- On activation: snapshot the current env, clear `HIP_PATH`/`ROCM_PATH`, set them to the HIP SDK dir, prepend HIP SDK `bin` and `lib` to PATH.
- On deactivation: restore the snapshotted env (iGPU venv wins again).

**No global rewire for dGPU.** Activation-based only.

The user can then `HIP_VISIBLE_DEVICES=1` to pin a process to the dGPU.

### Step 6 — Validate

Run `validate.ps1`. It exercises both stacks end-to-end:

**iGPU side (default shell):**
- `rocm-sdk version` should be 7.13.0
- `rocm-sdk targets` should be the iGPU arch
- `rocm-sdk test` should report 26 tests run, 1 skipped (Linux only), 0 failed

**dGPU side (after activation):**
- `hipconfig --version` should be 7.1.51803-d3a86bd04 (or current HIP SDK)
- `hipconfig --rocmpath` should be `C:\Program Files\AMD\ROCm\7.1\`
- If `vector_add.cpp` is present, `dgpu-build-template.ps1` builds it for the dGPU arch and runs on the dGPU. Expected: `dGPU HIP smoke test: PASS` with `gcnArchName: gfx1100` (or whatever dGPU arch).

If anything fails, the `Known issues` section in README.md covers:
- `testCLIUsesDevelRootPath` failure (now resolved by Option 2; should not occur)
- `device kernel image is invalid` (forgot `--offload-arch`)
- `cmath` not found (MSVC include paths wrong)
- iGPU not enumerated (driver / Adrenalin issue)

## Adapting to other hardware

| Hardware | Edit |
|---|---|
| Strix Point (HX 370/470, gfx1155) | `$INDEX = 'https://repo.amd.com/rocm/whl/gfx1151/'` (try first); may need to wait for gfx1155 wheel index |
| Rembrandt / Phoenix (gfx1103) | `$INDEX = 'https://repo.amd.com/rocm/whl/gfx110X-all/'`; `-libraries-gfx110x-all` |
| RX 7600 XT (gfx1100) | HIP SDK 7.1.0 supports it; no edit needed |
| RX 9070 / 9070 XT (gfx1201) | Verify HIP SDK supports gfx1201; may need HIP SDK upgrade |
| RX 6600 (gfx1031) | Check HIP SDK support; `--offload-arch=gfx1031` |

## Critical constraints (read once, obey always)

1. **iGPU = TheRock; dGPU = HIP SDK.** Never reverse.
2. **Install order**: 3 wheels FIRST, `rocm` meta sdist LAST. Skipping the meta leaves the importable `rocm_sdk` module missing.
3. **`HIP_PATH` shadowing**: HIP SDK 7.1.0's `hipconfig` reads `HIP_PATH` from env. The iGPU venv's `HIP_PATH` shadows the dGPU's. Activation MUST clear and re-set.
4. **`hipcc.bat` mishandles paths with spaces**. Always invoke `clang.exe` directly with `--driver-mode=g++ --hip-link`.
5. **`--offload-arch=<dGPU-arch>` is mandatory** for HIP SDK compile. Default `gfx906` will fail at runtime on a different dGPU.
6. **Driver-level `non-peers`**: most iGPU+dGPU pairs are non-peers. No direct GPU-GPU copy.
7. **Driver is the source of truth for `gcnArchName`**. Always confirm with `hipInfo` from each ROCm install.

## See also

- [README.md](README.md) — full method (English)
- [README.zh-CN.md](README.zh-CN.md) — 简体中文
- [README.ja-JP.md](README.ja-JP.md) — 日本語
- [README.ko-KR.md](README.ko-KR.md) — 한국어
- [AGENTS.md](AGENTS.md) — quick-start contract for any coding agent
- [LICENSE](LICENSE) — Apache 2.0 full text
- [NOTICE](NOTICE) — copyright + attribution
- [kit.json](kit.json) — machine-readable metadata

## Recovery

If anything goes wrong, the kit ships with `rollback-rewire.ps1` (restores the env from the snapshot at `C:\rocm-sdk\env-backup.xml` and `env-backup-machine.xml`).
