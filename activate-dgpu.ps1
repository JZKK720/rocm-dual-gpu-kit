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
# activate-dgpu.ps1
# Activate the dGPU HIP SDK environment in the current PowerShell session.
# Snapshots the current env so deactivate-dgpu.ps1 can restore it.
#
# The dGPU side uses the system HIP SDK (C:\Program Files\AMD\ROCm\7.x\)
# instead of a second TheRock venv. This saves ~22 GB and resolves the
# lingering testCLIUsesDevelRootPath failure caused by the iGPU venv's
# hipconfig shadowing itself.
#
# Usage:
#   . C:\rocm-sdk-dgpu\activate-dgpu.ps1
#   HIP_VISIBLE_DEVICES=1 my_program.exe
#   . C:\rocm-sdk-dgpu\deactivate-dgpu.ps1

$ErrorActionPreference = 'Stop'

# Find HIP SDK
$hipSdk = $null
foreach ($c in @('C:\Program Files\AMD\ROCm\7.1','C:\Program Files\AMD\ROCm\7.0','C:\Program Files\AMD\ROCm\6.4','C:\Program Files\AMD\ROCm')) {
    if ((Test-Path $c) -and (Test-Path (Join-Path $c 'bin\hipconfig.exe'))) { $hipSdk = $c; break }
}
if (-not $hipSdk) { throw "HIP SDK not found at standard paths. Install HIP SDK 7.1.0 first." }

# Snapshot
$global:DGPU_ENV_SNAPSHOT = @{
    HIP_PATH  = $env:HIP_PATH
    ROCM_PATH = $env:ROCM_PATH
    PATH      = $env:PATH
}

# Clear iGPU venv interference, point to HIP SDK
$env:HIP_PATH  = $hipSdk
$env:ROCM_PATH = $hipSdk

# Prepend HIP SDK bin + lib
$hipBin = Join-Path $hipSdk 'bin'
$hipLib = Join-Path $hipSdk 'lib'
$env:PATH = "$hipBin;$hipLib;$env:PATH"

"=== dGPU (HIP SDK) activated ==="                          | Write-Host -ForegroundColor Cyan
"  HIP_PATH  = $env:HIP_PATH"                                | Write-Host
"  ROCM_PATH = $env:ROCM_PATH"                               | Write-Host
"  hipconfig = $((Get-Command hipconfig -ErrorAction SilentlyContinue).Source)" | Write-Host
"  hipInfo: see both GPUs; pin to dGPU with `$env:HIP_VISIBLE_DEVICES=1" | Write-Host
