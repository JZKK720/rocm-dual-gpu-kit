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
# deactivate-dgpu.ps1
# Restore the env vars that activate-dgpu.ps1 snapshotted.

if (-not $global:DGPU_ENV_SNAPSHOT) {
    Write-Warning "No DGPU_ENV_SNAPSHOT found; nothing to restore."
    return
}

$env:HIP_PATH  = $global:DGPU_ENV_SNAPSHOT.HIP_PATH
$env:ROCM_PATH = $global:DGPU_ENV_SNAPSHOT.ROCM_PATH
$env:PATH      = $global:DGPU_ENV_SNAPSHOT.PATH
Remove-Variable DGPU_ENV_SNAPSHOT -Scope Global -ErrorAction SilentlyContinue

"=== dGPU environment restored ==="                          | Write-Host -ForegroundColor Yellow
"  HIP_PATH  = $env:HIP_PATH"                                | Write-Host
"  hipconfig = $((Get-Command hipconfig -ErrorAction SilentlyContinue).Source)" | Write-Host
