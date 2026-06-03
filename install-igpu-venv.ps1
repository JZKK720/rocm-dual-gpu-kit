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
# install-igpu-venv.ps1
# Auto-installs the iGPU TheRock venv based on hardware detection.
# Reads env from detect-hardware.ps1 output (DETECT_IGPU_ARCH, DETECT_IGPU_INDEX, etc).

$ErrorActionPreference = 'Stop'

# Re-run detection if env not set
if (-not $env:DETECT_IGPU_ARCH) {
    "  [i] detect env not set; running detect-hardware.ps1 first..." | Write-Host -ForegroundColor Yellow
    . "$PSScriptRoot\detect-hardware.ps1" *> $null
}
if (-not $env:DETECT_IGPU_ARCH) {
    throw "Could not detect iGPU gcnArchName. Run detect-hardware.ps1 manually to debug."
}

$arch  = $env:DETECT_IGPU_ARCH
$index = $env:DETECT_IGPU_INDEX
$lib   = $env:DETECT_IGPU_LIB
if (-not $index)   { throw "No TheRock index mapping for arch '$arch'." }
if (-not $lib)     { throw "No TheRock libraries extra mapping for arch '$arch'." }

# Find Python
$py = $null
foreach ($c in @('C:\Program Files\Python312\python.exe','C:\Program Files\Python311\python.exe','C:\Python312\python.exe','C:\Python311\python.exe','python')) {
    if (Test-Path $c -ErrorAction SilentlyContinue) { $py = $c; break }
}
if (-not $py) { throw "No system Python 3.11/3.12 found at standard paths." }

# Detect TheRock version from the index (or use a known stable one)
$ver = '7.13.0'   # adjust if a newer one is available
$baseUrl = "https://repo.amd.com/rocm/whl/$index/"
$pkgUrl  = "$baseUrl$lib/"
$wheelBase = $lib -replace '_','-'
$wheelName = "$($lib -replace '^rocm-sdk-libraries-','rocm_sdk_libraries_')-$ver-py3-none-win_amd64.whl"
$coreWheel = "rocm_sdk_core-$ver-py3-none-win_amd64.whl"
$develWheel= "rocm_sdk_devel-$ver-py3-none-win_amd64.whl"
$bootstrap = "rocm_bootstrap-0.1.0-py3-none-any.whl"
$sdist     = "rocm-$ver.tar.gz"

"" | Write-Host
"=== iGPU venv install: $arch (TheRock $ver) ===" | Write-Host
"  index:    $baseUrl" | Write-Host
"  python:   $py"      | Write-Host

$VENV  = 'C:\rocm-sdk'
$cache = "$VENV\cache"

# 1. Create venv
"  [1/4] create venv at $VENV\.venv ..." | Write-Host
if (Test-Path "$VENV\.venv") {
    "    removing existing venv" | Write-Host
    Remove-Item -Recurse -Force "$VENV\.venv"
}
& $py -m venv "$VENV\.venv"
& "$VENV\.venv\Scripts\python.exe" -m pip install --upgrade pip wheel setuptools 2>&1 | Out-Null

# 2. Pre-download
"  [2/4] pre-download wheels to $cache ..." | Write-Host
New-Item -ItemType Directory -Force -Path $cache | Out-Null
# Clean any prior *_index.html artifacts (they confuse --find-links)
Get-ChildItem $cache -Filter '*_index.html' -ErrorAction SilentlyContinue | Remove-Item -Force
& "$VENV\.venv\Scripts\python.exe" -m pip download --no-deps --no-build-isolation `
    --index-url "$baseUrl" --dest $cache `
    rocm_bootstrap rocm-sdk-core rocm-sdk-devel $lib rocm 2>&1 | Out-Null

# 3. Install wheels then meta
"  [3/4] install from local cache (no network) ..." | Write-Host
& "$VENV\.venv\Scripts\python.exe" -m pip install --no-index --find-links $cache --no-build-isolation --no-cache-dir `
    rocm_bootstrap==0.1.0 `
    rocm-sdk-core==$ver `
    rocm-sdk-devel==$ver `
    "$lib==$ver" 2>&1 | Out-Null
& "$VENV\.venv\Scripts\python.exe" -m pip install --no-index --find-links $cache --no-build-isolation --no-cache-dir rocm 2>&1 | Out-Null

# 4. Smoke test
"  [4/4] smoke test ..." | Write-Host
& "$VENV\.venv\Scripts\python.exe" -m rocm_sdk version
& "$VENV\.venv\Scripts\python.exe" -m rocm_sdk targets
& "$VENV\.venv\Scripts\python.exe" -m rocm_sdk test 2>&1 | Select-String -Pattern 'Ran [0-9]+ tests' | ForEach-Object { "  $_" | Write-Host }

"=== Done. Next: rewire-igpu.ps1 (machine scope) ===" | Write-Host
