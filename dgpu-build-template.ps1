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
# dgpu-build-template.ps1
# Compile and run a HIP program for the dGPU using the system HIP SDK.
# Template: edit $SRC, $DST, $ARCH to match your dGPU.
#
# Auto-detects MSVC BuildTools and Windows SDK from standard paths.
# Adjust the $MSVC / $SDK overrides if your install lives elsewhere.

$ErrorActionPreference = 'Stop'

# --- Inputs (edit these) ---
$SRC  = 'C:\rocm-sdk-dgpu\vector_add.cpp'    # your .cpp
$DST  = 'C:\rocm-sdk-dgpu\vector_add.exe'    # output .exe
$ARCH = 'gfx1100'                            # dGPU's gcnArchName (see detect-hardware.ps1)

# --- Activate HIP SDK ---
. "$PSScriptRoot\activate-dgpu.ps1"

# --- Auto-detect MSVC + Windows SDK ---
$msvcRoot = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'
if (-not (Test-Path $msvcRoot)) { $msvcRoot = 'C:\BuildTools' }
if (-not (Test-Path $msvcRoot)) { throw "Visual Studio BuildTools not found at standard paths." }
$msvcVer = Get-ChildItem "$msvcRoot\VC\Tools\MSVC" -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (-not $msvcVer) { throw "No MSVC version under $msvcRoot\VC\Tools\MSVC." }

$sdkRoot = 'C:\Program Files (x86)\Windows Kits\10'
if (-not (Test-Path $sdkRoot)) { throw "Windows Kits 10 not found at $sdkRoot." }
$sdkVer = Get-ChildItem "$sdkRoot\Include" -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (-not $sdkVer) { throw "No Windows SDK version under $sdkRoot\Include." }

$MSVC_INC = "$($msvcVer.FullName)\include"
$MSVC_LIB = "$($msvcVer.FullName)\lib\x64"
$MSVC_BIN = "$($msvcVer.FullName)\bin\Hostx64\x64"
$SDK_INC  = "$($sdkVer.FullName)"
$SDK_LIB  = "$sdkRoot\Lib\$($sdkVer.Name)"

# Add MSVC bin to PATH for link.exe
$env:PATH = "$MSVC_BIN;$env:PATH"

"" | Write-Host
"=== compile $SRC for $ARCH ===" | Write-Host
"  MSVC : $MSVC_INC" | Write-Host
"  SDK  : $SDK_INC"  | Write-Host

# Invoke clang.exe directly (NOT hipcc.bat - mishandles paths with spaces)
$clang = 'C:\Program Files\AMD\ROCm\7.1\bin\clang.exe'
if (-not (Test-Path $clang)) {
    # try the discovered HIP SDK path
    $clang = Join-Path $env:HIP_PATH 'bin\clang.exe'
}
& $clang -O2 --driver-mode=g++ `
    -fuse-ld=lld `
    --ld-path="$env:HIP_PATH\bin\lld-link.exe" `
    --hip-link `
    "--offload-arch=$ARCH" `
    "-I$MSVC_INC" `
    "-I$SDK_INC\ucrt" `
    "-I$SDK_INC\um" `
    "-I$SDK_INC\shared" `
    "-I$SDK_INC\winrt" `
    "-L$MSVC_LIB" `
    "-L$SDK_LIB\ucrt\x64" `
    "-L$SDK_LIB\um\x64" `
    -x hip $SRC -o $DST 2>&1 | ForEach-Object { "  $_" }
$compileExit = $LASTEXITCODE
"  compile exit=$compileExit" | Write-Host
"  $DST exists: $((Test-Path $DST).ToString().ToLower())" | Write-Host

if ((Test-Path $DST) -and $compileExit -eq 0) {
    "" | Write-Host
    "=== run on dGPU (HIP_VISIBLE_DEVICES=1) ===" | Write-Host
    $env:HIP_VISIBLE_DEVICES = '1'
    & $DST 2>&1 | ForEach-Object { "  $_" }
    "  run exit=$LASTEXITCODE" | Write-Host
    $env:HIP_VISIBLE_DEVICES = $null
}

. "$PSScriptRoot\deactivate-dgpu.ps1"
