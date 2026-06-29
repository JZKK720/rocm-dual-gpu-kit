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
# test-peer-vram.ps1
# Compile and run peer_vram_test.cpp to reproduce the non-peers VRAM copy
# failure and verify the host-memory staging workaround.
#
# Usage:
#   .\test-peer-vram.ps1
#
# Expected verdict lines in stdout:
#   PEER COPY: FAIL (expected)      <- non-peers, hipMemcpyPeer fails
#   STAGING COPY: PASS              <- dGPU -> host pinned -> iGPU works
#
# Exit code 0 if STAGING COPY: PASS, non-zero otherwise.

$ErrorActionPreference = 'Stop'

# 1. Detect hardware to populate $env:DETECT_DGPU_ARCH.
. "$PSScriptRoot\detect-hardware.ps1" *> $null
$arch = $env:DETECT_DGPU_ARCH
if (-not $arch) { throw "DETECT_DGPU_ARCH not set. Run detect-hardware.ps1 first." }

# 2. Activate the dGPU HIP SDK env (clears HIP_PATH shadowing per invariant #3).
. "$PSScriptRoot\activate-dgpu.ps1"

# 3. Resolve source + output paths.
$SRC = Join-Path $PSScriptRoot 'peer_vram_test.cpp'
$DST = Join-Path $PSScriptRoot 'peer_vram_test.exe'
if (-not (Test-Path $SRC)) { throw "Source not found: $SRC" }

# 4. Auto-detect MSVC + Windows SDK (same logic as dgpu-build-template.ps1).
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

$env:PATH = "$MSVC_BIN;$env:PATH"

# 5. Resolve clang.exe (invariant #4: never use hipcc.bat for paths with spaces).
$clang = Join-Path $env:HIP_PATH 'bin\clang.exe'
if (-not (Test-Path $clang)) { throw "clang.exe not found at $clang" }

"" | Write-Host
"=== test-peer-vram: compile peer_vram_test.cpp for $arch ===" | Write-Host
"  src  : $SRC" | Write-Host
"  dst  : $DST" | Write-Host
"  arch : $arch" | Write-Host
"  clang: $clang" | Write-Host
"  MSVC : $MSVC_INC" | Write-Host
"  SDK  : $SDK_INC" | Write-Host

# 6. Compile (invariant #4 + #5: clang.exe direct, --offload-arch mandatory).
& $clang -O2 --driver-mode=g++ `
    -fuse-ld=lld `
    --ld-path="$env:HIP_PATH\bin\lld-link.exe" `
    --hip-link `
    "--offload-arch=$arch" `
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

if (-not (Test-Path $DST) -or $compileExit -ne 0) {
    "  [!] Compile failed." | Write-Host -ForegroundColor Red
    . "$PSScriptRoot\deactivate-dgpu.ps1"
    exit 1
}

# 7. Run with both devices visible.
"" | Write-Host
"=== run (HIP_VISIBLE_DEVICES=0,1) ===" | Write-Host
$env:HIP_VISIBLE_DEVICES = '0,1'
$output = & $DST 2>&1 | Out-String
$output | ForEach-Object { "  $_" } | Write-Host
$runExit = $LASTEXITCODE
"  run exit=$runExit" | Write-Host
$env:HIP_VISIBLE_DEVICES = $null

# 8. Grep verdict lines.
$peerLine    = ($output -split "`n" | Where-Object { $_ -match '^PEER COPY:' }) -join ''
$stagingLine = ($output -split "`n" | Where-Object { $_ -match '^STAGING COPY:' }) -join ''

"" | Write-Host
"=== VERDICT ===" | Write-Host
"  $peerLine"    | Write-Host
"  $stagingLine" | Write-Host

# 9. Deactivate dGPU env.
. "$PSScriptRoot\deactivate-dgpu.ps1"

# 10. Exit 0 only if staging passed.
if ($stagingLine -match 'PASS') {
    "  overall: PASS (staging workaround works)" | Write-Host -ForegroundColor Green
    exit 0
} else {
    "  overall: FAIL (staging workaround did not pass)" | Write-Host -ForegroundColor Red
    exit 1
}