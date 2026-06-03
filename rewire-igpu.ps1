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
# rewire-igpu.ps1
# Re-wire user + machine PATH/HIP_PATH/LLVM_PATH to make the iGPU TheRock venv
# the default ROCm toolchain globally.
#
# Snapshots current env to $VENV\env-backup.xml and $VENV\env-backup-machine.xml
# so you can roll back with rollback-rewire.ps1.

$ErrorActionPreference = 'Stop'
$VENV = 'C:\rocm-sdk'

if (-not (Test-Path "$VENV\.venv\Lib\site-packages\_rocm_sdk_core")) {
    throw "iGPU venv not found at $VENV\.venv. Run install-igpu-venv.ps1 first."
}

# Snapshot
[Environment]::GetEnvironmentVariables('User')    | Export-Clixml "$VENV\env-backup.xml"
[Environment]::GetEnvironmentVariables('Machine') | Export-Clixml "$VENV\env-backup-machine.xml"
"  env snapshot saved:" | Write-Host
"    $VENV\env-backup.xml" | Write-Host
"    $VENV\env-backup-machine.xml" | Write-Host

$coreBin = "$VENV\.venv\Lib\site-packages\_rocm_sdk_core"
$develLlvm= "$VENV\.venv\Lib\site-packages\_rocm_sdk_devel\lib\llvm"

# User scope
[Environment]::SetEnvironmentVariable('HIP_PATH',  $coreBin, 'User')
[Environment]::SetEnvironmentVariable('LLVM_PATH', $develLlvm, 'User')
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
$prepend  = "$VENV\.venv\Scripts;$coreBin\bin;$develLlvm\bin"
[Environment]::SetEnvironmentVariable('PATH', $prepend + ';' + $userPath, 'User')

# Machine scope (UAC)
$msiPath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
$msiCmd  = "[Environment]::SetEnvironmentVariable('HIP_PATH','$coreBin','Machine'); " + `
           "[Environment]::SetEnvironmentVariable('PATH','$($VENV\.venv\Scripts);$coreBin\bin;' + `$msiPath,'Machine')"
Start-Process powershell -ArgumentList '-NoProfile','-Command',$msiCmd -Verb RunAs -Wait

"  user + machine env rewired." | Write-Host
"  Open a fresh pwsh to verify:" | Write-Host
"    Get-Command hipconfig,hipcc,rocm-sdk,clang | Select-Object Name,Source" | Write-Host
