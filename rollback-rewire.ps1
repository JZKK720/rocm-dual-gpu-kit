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
# rollback-rewire.ps1
# Restore the env vars snapshotted by rewire-igpu.ps1.

$ErrorActionPreference = 'Stop'
$VENV = 'C:\rocm-sdk'

if (-not (Test-Path "$VENV\env-backup.xml")) {
    throw "No env-backup.xml found at $VENV. Run rewire-igpu.ps1 first to create one, or restore manually."
}

# Restore user scope
$user = Import-Clixml "$VENV\env-backup.xml"
foreach ($k in $user.Keys) {
    [Environment]::SetEnvironmentVariable($k, $user[$k], 'User')
}

# Restore machine scope (UAC)
$machine = Import-Clixml "$VENV\env-backup-machine.xml"
$msiCmd = '$d = Import-Clixml "C:\rocm-sdk\env-backup-machine.xml"; foreach ($k in $d.Keys) { [Environment]::SetEnvironmentVariable($k, $d[$k], "Machine") }'
Start-Process powershell -ArgumentList '-NoProfile','-Command',$msiCmd -Verb RunAs -Wait

"  env restored to pre-rewire state." | Write-Host
"  Open a fresh pwsh to verify." | Write-Host
