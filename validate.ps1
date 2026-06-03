# =============================================================================
# rocm-dual-gpu-kit
# Copyright 2026 cubecloud Limited (https://cubecloud.io)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# =============================================================================
# validate.ps1
# End-to-end validation of the dual-GPU setup. Runs in a fresh pwsh subprocess
# so it tests the real rewired env, not the parent shell's cached one.

$ErrorActionPreference = 'Stop'
$log = 'C:\rocm-sdk-dgpu\validate.log'
Remove-Item -Force $log -ErrorAction SilentlyContinue

# Detect hardware
. "$PSScriptRoot\detect-hardware.ps1" *> $null

# Auto-find a tiny HIP C++ file to compile for the dGPU
$SRC = $null
foreach ($c in @('C:\rocm-sdk-dgpu\vector_add.cpp',"$PSScriptRoot\..\rocm-sdk-dgpu\vector_add.cpp",'C:\rocm-sdk-dgpu\vector_add.cpp')) {
    if (Test-Path $c) { $SRC = $c; break }
}

if (-not $env:DETECT_IGPU_ARCH) { throw "iGPU not detected - is detect-hardware.ps1 working?" }
if (-not $env:DETECT_DGPU_ARCH) { throw "dGPU not detected" }

# 1. iGPU side
"" | Write-Host
"=== 1. iGPU venv test ===" | Write-Host
$igpuPy = 'C:\rocm-sdk\.venv\Scripts\python.exe'
if (-not (Test-Path $igpuPy)) { throw "iGPU venv not installed at C:\rocm-sdk\.venv" }
"  version: $((& $igpuPy -m rocm_sdk version 2>&1).Trim())" | Write-Host
"  targets: $((& $igpuPy -m rocm_sdk targets 2>&1).Trim())" | Write-Host
$testOut = & $igpuPy -m rocm_sdk test 2>&1 | Out-String
if ($testOut -match 'Ran 26 tests in [\d.]+s\s*$' -or $testOut -match 'OK \(skipped=\d+\)') {
    "  tests: PASS (Ran 26 tests; expected)" | Write-Host -ForegroundColor Green
} else {
    "  tests: see log" | Write-Host -ForegroundColor Yellow
}

# 2. dGPU side (only if HIP SDK is installed)
if ($env:DETECT_HIP_SDK -and (Test-Path $env:DETECT_HIP_SDK)) {
    "" | Write-Host
    "=== 2. dGPU HIP SDK test ===" | Write-Host
    . "$PSScriptRoot\activate-dgpu.ps1"
    $ver = (hipconfig --version 2>&1 | Out-String).Trim()
    $rcm = (hipconfig --rocmpath 2>&1 | Out-String).Trim()
    "  hipconfig --version:  $ver"  | Write-Host
    "  hipconfig --rocmpath: $rcm" | Write-Host
    "  --rocmpath matches HIP SDK: $($rcm -like '*AMD\ROCm*')" | Write-Host

    # 3. End-to-end compile + run, if source is available
    if ($SRC) {
        "" | Write-Host
        "=== 3. dGPU end-to-end compile + run (vector_add) ===" | Write-Host
        $arch = $env:DETECT_DGPU_ARCH
        . "$PSScriptRoot\dgpu-build-template.ps1"
    } else {
        "  (no vector_add.cpp found; skipping compile test)" | Write-Host -ForegroundColor Yellow
    }

    . "$PSScriptRoot\deactivate-dgpu.ps1"
} else {
    "  [!] HIP SDK not installed; dGPU side skipped." | Write-Host -ForegroundColor Yellow
}

"" | Write-Host
"=== Validation complete ===" | Write-Host
