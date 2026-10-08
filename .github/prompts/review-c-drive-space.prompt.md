---
name: "Review C Drive Space"
description: "Inspect C:\\ disk usage on Windows and rank low-risk cleanup candidates, especially ROCm/TheRock caches and generated artifacts. Use when the user asks to review C:\\, reclaim space, or clear useless caches."
argument-hint: "Optional scope, for example: C:\\, C:\\rocm-sdk, or user-profile caches"
agent: "agent"
---
Review disk usage for the provided Windows path, defaulting to `C:\`, and produce a cautious cleanup plan.

Requirements:
- Start read-only. Measure large directories before suggesting deletions.
- Distinguish disposable caches and logs from installed runtimes, SDKs, active virtual environments, and rollback assets.
- For this repo and kit, treat `C:\rocm-sdk\cache` as the first reclaim candidate after a successful install if offline reinstall is not needed.
- Treat generated diagnostics and test outputs under `C:\rocm-sdk-dgpu\` and repo log files as disposable unless the user wants to keep them.
- Do not recommend deleting `C:\rocm-sdk\.venv` or `C:\Program Files\AMD\ROCm\...` unless the user explicitly asks to uninstall or rebuild.
- Keep `C:\rocm-sdk\env-backup.xml` and `C:\rocm-sdk\env-backup-machine.xml` until rollback is no longer needed.
- For machine-wide cleanup beyond the kit, prefer Windows-native or user-cache candidates next: temp files, Delivery Optimization cache, pip cache, NuGet cache, npm cache, browser caches, stale installers, and old virtual environments.
- When archiving a large folder before deletion, default to a sibling path on `C:\` if no separate data drive exists; do not assume `D:\` is available.
- After removing a TheRock venv, clear any dangling user-scope `HIP_PATH` / `LLVM_PATH` variables that pointed into it.
- For reboot-driven Windows reclaim, surface `C:\hiberfil.sys` (disable hibernation), `C:\pagefile.sys` (shrink to fixed size), and `C:\Windows\WinSxS` (`dism /Online /Cleanup-Image /StartComponentCleanup`) as high-value, reversible targets.

Report:
1. Candidate path and estimated savings.
2. Why the candidate is safe, cautionary, or risky.
3. Exact cleanup command only after confirming the deletion is optional and reversible enough for the user's goal.

Reference [AGENTS.md](../../AGENTS.md) for repo guardrails and [README.md](../../README.md) for disk budget and setup context.