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
# detect-hardware.ps1
# Detect iGPU / dGPU on this box, their gcnArchName, HIP SDK presence, MSVC, Python.
# Drives the rest of the kit by writing $env:DETECT_* and printing a summary.

$ErrorActionPreference = 'Continue'
"=== Hardware / software detection ===" | Write-Host
"  time: $(Get-Date -Format 'HH:mm:ss')" | Write-Host
"" | Write-Host

# 1. Python
"--- Python ---" | Write-Host
$py = $null
foreach ($c in @('C:\Program Files\Python312\python.exe','C:\Program Files\Python311\python.exe','C:\Python312\python.exe','C:\Python311\python.exe','python')) {
    if (Test-Path $c -ErrorAction SilentlyContinue) { $py = $c; break }
}
if ($null -eq $py) {
    "  [!] No system Python 3.11/3.12 found at standard paths." | Write-Host -ForegroundColor Yellow
} else {
    "  python:  $py" | Write-Host
    "  version: $((& $py -V 2>&1).Trim())" | Write-Host
}

# 2. HIP SDK
"" | Write-Host
"--- HIP SDK ---" | Write-Host
$hipSdk = $null
$candidates = @(
    'C:\Program Files\AMD\ROCm\7.1',
    'C:\Program Files\AMD\ROCm\7.0',
    'C:\Program Files\AMD\ROCm\6.4',
    'C:\Program Files\AMD\ROCm'
)
foreach ($c in $candidates) {
    if ((Test-Path $c) -and (Test-Path (Join-Path $c 'bin\hipconfig.exe'))) {
        $hipSdk = $c; break
    }
}
if ($null -eq $hipSdk) {
    "  [!] No HIP SDK installed at standard paths." | Write-Host -ForegroundColor Yellow
} else {
    $hipConfig = Join-Path $hipSdk 'bin\hipconfig.exe'
    $hipVer = (hipconfig --version 2>&1 | Out-String).Trim()
    "  path:    $hipSdk" | Write-Host
    "  version: $hipVer" | Write-Host
    $env:HIP_SDK_PATH = $hipSdk
}

# 3. AMD driver
"" | Write-Host
"--- AMD driver ---" | Write-Host
$drv = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'AMD|ATI|Radeon' } | Select-Object -First 5
if ($drv) {
    foreach ($d in $drv) { "  $($d.FriendlyName)  [$($d.Status)]" | Write-Host }
} else {
    "  [!] No AMD display devices found via PnP." | Write-Host -ForegroundColor Yellow
}

# 4. hipInfo enumeration (using HIP SDK if available, else any hipInfo on PATH)
"" | Write-Host
"--- hipInfo device enumeration ---" | Write-Host
$hipInfo = $null
if ($hipSdk) { $hipInfo = Join-Path $hipSdk 'bin\hipInfo.exe' }
if (-not (Test-Path $hipInfo)) {
    $hipInfo = (Get-Command hipInfo -ErrorAction SilentlyContinue).Source
}
if ($hipInfo -and (Test-Path $hipInfo)) {
    $out = & $hipInfo 2>&1 | Out-String
    $devices = [regex]::Matches($out, '(?ms)device#\s+(\d+).*?Name:\s+([^\r\n]+).*?pciBusID:\s+(\d+).*?totalGlobalMem:\s+([^\r\n]+).*?gcnArchName:\s+(\S+).*?non-peers:\s+([^\r\n]+)')
    $igpuTarget = $null
    $dgpuTarget = $null
    foreach ($m in $devices) {
        $n   = $m.Groups[1].Value
        $nm  = $m.Groups[2].Value.Trim()
        $pci = $m.Groups[3].Value
        $mem = $m.Groups[4].Value.Trim()
        $arch= $m.Groups[5].Value
        $peer= $m.Groups[6].Value.Trim()
        "  device#$n  $nm" | Write-Host
        "    pciBusID:     $pci" | Write-Host
        "    global mem:   $mem" | Write-Host
        "    gcnArchName:  $arch" | Write-Host
        "    non-peers:    $peer" | Write-Host
        "" | Write-Host
        # Heuristic: iGPU usually has a very large 'global mem' (shared system RAM)
        # or contains "Graphics" but not "RX".
        $isIGPU = $nm -match 'Graphics' -and $nm -notmatch 'RX\s*\d'
        if ($isIGPU) { $igpuTarget = $arch; $env:DETECT_IGPU_NAME = $nm; $env:DETECT_IGPU_ARCH = $arch }
        else         { $dgpuTarget = $arch; $env:DETECT_DGPU_NAME = $nm; $env:DETECT_DGPU_ARCH = $arch }
    }
} else {
    "  [!] No hipInfo found. Install HIP SDK or a TheRock venv to enumerate." | Write-Host -ForegroundColor Yellow
}

# 5. Map gcnArchName to TheRock wheel index
"" | Write-Host
"--- TheRock wheel-index mapping ---" | Write-Host
function Get-TheRockIndex($arch) {
    switch -Regex ($arch) {
        '^gfx1151$'           { return 'gfx1151' }
        '^gfx1155$'           { return 'gfx1151' }   # Strix Point often under gfx1151 index
        '^gfx12(00|01|10|11)$' { return 'gfx12-generic' }   # RDNA 4
        '^gfx110[0-3]$'       { return 'gfx110X-all' }
        '^gfx103[0-5]$'       { return 'gfx103X-all' }
        default               { return $null }
    }
}
function Get-LibExtra($arch) {
    switch -Regex ($arch) {
        '^gfx1151$' { return 'rocm-sdk-libraries-gfx1151' }
        '^gfx1155$' { return 'rocm-sdk-libraries-gfx1151' }   # try same
        '^gfx12'    { return 'rocm-sdk-libraries-gfx12-generic' }
        '^gfx110'   { return 'rocm-sdk-libraries-gfx110x-all' }
        '^gfx103'   { return 'rocm-sdk-libraries-gfx103x-all' }
        default     { return $null }
    }
}

if ($env:DETECT_IGPU_ARCH) {
    $idx = Get-TheRockIndex $env:DETECT_IGPU_ARCH
    $lib = Get-LibExtra    $env:DETECT_IGPU_ARCH
    "  iGPU arch $env:DETECT_IGPU_ARCH -> TheRock index: $idx, libraries extra: $lib" | Write-Host
    $env:DETECT_IGPU_INDEX = $idx
    $env:DETECT_IGPU_LIB   = $lib
}
if ($env:DETECT_DGPU_ARCH) {
    $idx = Get-TheRockIndex $env:DETECT_DGPU_ARCH
    "  dGPU arch $env:DETECT_DGPU_ARCH -> TheRock index: $idx" | Write-Host
    $env:DETECT_DGPU_INDEX = $idx
}

# 6. Visual Studio BuildTools (for dGPU C++ compile)
"" | Write-Host
"--- Visual Studio BuildTools ---" | Write-Host
$msvcRoots = @('C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools','C:\BuildTools')
$msvcFound = $null
foreach ($r in $msvcRoots) {
    if (Test-Path $r) {
        $msvcVer = Get-ChildItem "$r\VC\Tools\MSVC" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($msvcVer) {
            "  $r  (MSVC $($msvcVer.Name))" | Write-Host
            $msvcFound = $msvcVer.FullName
            $env:DETECT_MSVC_INC = "$($msvcVer.FullName)\include"
            $env:DETECT_MSVC_LIB = "$($msvcVer.FullName)\lib\x64"
            $env:DETECT_MSVC_BIN = "$($msvcVer.FullName)\bin\Hostx64\x64"
        }
    }
}
$winKit = 'C:\Program Files (x86)\Windows Kits\10\Include'
if (Test-Path $winKit) {
    $sdkVer = Get-ChildItem $winKit -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if ($sdkVer) {
        "  Windows SDK: $($sdkVer.Name)  at $winKit\$($sdkVer.Name)" | Write-Host
        $env:DETECT_SDK_INC = "$winKit\$($sdkVer.Name)"
        $env:DETECT_SDK_LIB = "C:\Program Files (x86)\Windows Kits\10\Lib\$($sdkVer.Name)"
    }
}
if (-not $msvcFound) {
    "  [!] No Visual Studio BuildTools found. dGPU C++ compile will not work." | Write-Host -ForegroundColor Yellow
}

# 7. Summary + suggested next steps
"" | Write-Host
"=== SUMMARY ===" | Write-Host
"  iGPU:  arch=$($env:DETECT_IGPU_ARCH)  TheRock index=$($env:DETECT_IGPU_INDEX)  lib=$($env:DETECT_IGPU_LIB)" | Write-Host
"  dGPU:  arch=$($env:DETECT_DGPU_ARCH)  HIP SDK=$($hipSdk)" | Write-Host
"  MSVC:  $($env:DETECT_MSVC_INC)" | Write-Host
"  SDK:   $($env:DETECT_SDK_INC)" | Write-Host
"" | Write-Host
"  Suggested next:" | Write-Host
"    install-igpu-venv.ps1    - set up iGPU TheRock venv" | Write-Host
"    activate-dgpu.ps1        - activate HIP SDK for dGPU work" | Write-Host
"    validate.ps1             - end-to-end smoke test" | Write-Host
"" | Write-Host
"  Detection results also written to: $VENV\detect.env (re-source to restore)" | Write-Host
$env:DETECT_HIP_SDK = $hipSdk
# Persist
$envLines = @()
$env:DETECT_IGPU_ARCH,$env:DETECT_IGPU_INDEX,$env:DETECT_IGPU_LIB,$env:DETECT_IGPU_NAME | ForEach-Object { $envLines += $_ }
# Filter empty
$envLines = $envLines | Where-Object { $_ }
$envLines | Out-File -FilePath 'C:\therock\rocm-dual-gpu-kit\detect.env' -Encoding ascii -Force
