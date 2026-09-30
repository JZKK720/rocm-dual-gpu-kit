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
# install-npu-lemonade.ps1
# Phase 1.3 of the kit: bring the XDNA2 NPU (Strix Halo) into the tri-GPU
# serving stack via Lemonade Server + FastFlowLM.
#
# What this does (read-only on kit files, installs per-user software):
#   1. Detect NPU hardware (PCI\VEN_1022&DEV_17F0) and NPU driver version.
#      - Requires driver >= 32.0.203.280 (RyzenAI 1.6.0 minimum).
#   2. Install Lemonade Server (MSI, silent) if not already present.
#   3. Install the FastFlowLM NPU backend (flm:npu) via Lemonade CLI.
#   4. Run flm validate to confirm the NPU stack passes.
#   5. Verify the server responds on http://localhost:13305 and reports
#      amd_npu available with family XDNA2.
#
# This does NOT touch: HIP SDK, TheRock venv, Ollama config, registry,
# or any global environment variables. Lemonade is fully self-contained.
#
# Usage:
#   .\install-npu-lemonade.ps1
#   .\install-npu-lemonade.ps1 -Model qwen3-0.6b-FLM   # also pull a model
#   .\install-npu-lemonade.ps1 -SkipInstall            # only check + validate
#
# Exit 0 when NPU serving is ready, 1 otherwise.

param(
    [string]$Model = '',
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Step 1: NPU hardware + driver check
# ---------------------------------------------------------------------------
"=== install-npu-lemonade: NPU bring-up ===" | Write-Host

$npuDev = Get-CimInstance Win32_PnPEntity -Filter "PNPDeviceID LIKE '%VEN_1022&DEV_17F0%'" |
    Where-Object { $_.Name -like '*NPU*' } | Select-Object -First 1

if (-not $npuDev) {
    "[FAIL] No XDNA2 class NPU found (PCI VEN_1022 DEV_17F0 missing)." |
        Write-Host -ForegroundColor Red
    "  This kit's NPU path requires Ryzen AI 300-series / Strix Halo." | Write-Host
    exit 1
}
"  [OK] NPU device: $($npuDev.Name) ($($npuDev.PNPDeviceID.Trim()))" | Write-Host

$npuDriver = Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceName='NPU Compute Accelerator Device'"
$driverVer = $npuDriver.DriverVersion
if (-not $driverVer) {
    "[FAIL] NPU detected but driver 'NPU Compute Accelerator Device' not registered." |
        Write-Host -ForegroundColor Red
    "  Install the AMD NPU driver (see Lemonade driver-install page)." | Write-Host
    exit 1
}

# Compare 4-part version numerically against RyzenAI 1.6.0 minimum 32.0.203.280.
$min = [version]'32.0.203.280'
try { $have = [version]$driverVer } catch { $have = $null }
if ($have -ge $min) {
    "  [OK] NPU driver: $driverVer (>= 32.0.203.280 required by Ryzen AI / FLM)" | Write-Host
} else {
    "[FAIL] NPU driver $driverVer is below minimum 32.0.203.280." |
        Write-Host -ForegroundColor Red
    "  Update the NPU driver first (Adrenalin includes it)." | Write-Host
    exit 1
}

# ---------------------------------------------------------------------------
# Step 2: Lemonade Server install (silent MSI, per-machine + per-user dirs)
# ---------------------------------------------------------------------------
$lemonadeBin = Join-Path $env:LOCALAPPDATA 'lemonade_server\bin'
$lemonadeExe = Join-Path $lemonadeBin 'lemonade.exe'

if (-not (Test-Path $lemonadeExe)) {
    if ($SkipInstall) {
        "[FAIL] -SkipInstall set but Lemonade not found at $lemonadeExe" |
            Write-Host -ForegroundColor Red
        exit 1
    }
    "  Lemonade not present. Downloading latest lemonade.msi..." | Write-Host
    $msi = Join-Path $env:TEMP 'lemonade.msi'
    curl.exe -L -o $msi --retry 3 --max-time 600 `
        --speed-limit 1000 --speed-time 45 `
        'https://github.com/lemonade-sdk/lemonade/releases/latest/download/lemonade.msi'
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $msi) -or (Get-Item $msi).Length -lt 5MB) {
        "[FAIL] Download failed or file truncated ($msi)" | Write-Host -ForegroundColor Red
        exit 1
    }
    "  Installing (silent, per-machine)... " | Write-Host
    $proc = Start-Process msiexec.exe `
        -ArgumentList "/i `"$msi`" /qn /norestart /L*V `"$env:TEMP\lemonade-install.log`"" `
        -PassThru -Wait
    if ($proc.ExitCode -ne 0) {
        "[FAIL] msiexec exit code $($proc.ExitCode)" | Write-Host -ForegroundColor Red
        exit 1
    }
    "  [OK] Lemonade Server installed to $lemonadeBin" | Write-Host
} else {
    $ver = & $lemonadeExe --version 2>$null
    "  [OK] Lemonade already installed: $ver" | Write-Host
}

# ---------------------------------------------------------------------------
# Step 3: FastFlowLM NPU backend
# ---------------------------------------------------------------------------
"  Checking flm:npu backend..." | Write-Host
if (-not $SkipInstall) {
    & $lemonadeExe backends install flm:npu 2>&1 | ForEach-Object { "  $_" }
} else {
    "  (-SkipInstall: skipping backend install, assuming flm:npu present)" | Write-Host
}

$flmExe = Get-ChildItem (Join-Path $env:USERPROFILE '.cache\lemonade\bin\flm\npu') `
    -Filter 'flm.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $flmExe) {
    $flmExe = Get-Command flm.exe -ErrorAction SilentlyContinue
    $flmExe = $flmExe.Source
} else {
    $flmExe = $flmExe.FullName
}
if (-not $flmExe -or -not (Test-Path $flmExe)) {
    "[FAIL] flm.exe not found after backend install." | Write-Host -ForegroundColor Red
    exit 1
}
"  [OK] FLM binary: $flmExe" | Write-Host

# ---------------------------------------------------------------------------
# Step 4: flm validate (green output = NPU + driver compatible)
# ---------------------------------------------------------------------------
"  Running flm validate..." | Write-Host
$validateOut = & $flmExe validate 2>&1 | Out-String
$validateOut | ForEach-Object { "  $_" } | Write-Host
$validateOk = ($validateOut -match 'XDNA2') -and ($validateOut -match 'NPU dirver|NPU driver')
if (-not $validateOk) {
    "[FAIL] FLM validation did not report XDNA2 + driver." | Write-Host -ForegroundColor Red
    "  Raw output: $validateOut" | Write-Host
    exit 1
}

# ---------------------------------------------------------------------------
# Step 5: ensure server running, verify NPU visible via /api/v1/system-info
# ---------------------------------------------------------------------------
$serverUp = $false
try {
    $probe = Invoke-WebRequest -Uri 'http://127.0.0.1:13305/api/v1/system-info' `
        -UseBasicParsing -TimeoutSec 5
    if ($probe.StatusCode -eq 200) { $serverUp = $true }
} catch { $serverUp = $false }

if (-not $serverUp) {
    "  Server not running. Starting LemonadeServer.exe serve ..." | Write-Host
    $srvExe = Join-Path $lemonadeBin 'LemonadeServer.exe'
    if (-not (Test-Path $srvExe)) {
        # Fall back to listing candidates for a portable install.
        $srvExe = Get-ChildItem $lemonadeBin -Recurse -Filter 'LemonadeServer.exe' |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $srvExe -or -not (Test-Path $srvExe)) {
        "[FAIL] LemonadeServer.exe not found under $lemonadeBin" | Write-Host -ForegroundColor Red
        exit 1
    }
    Start-Process -FilePath $srvExe -ArgumentList 'serve' -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and -not $serverUp) {
        Start-Sleep -Seconds 3
        try {
            $probe = Invoke-WebRequest -Uri 'http://127.0.0.1:13305/api/v1/system-info' `
                -TimeoutSec 3
            if ($probe.StatusCode -eq 200) { $serverUp = $true }
        } catch { }
    }
}
if (-not $serverUp) {
    "[FAIL] Lemonade server did not come up on 13305 within 30s." | Write-Host -ForegroundColor Red
    exit 1
}
"  [OK] Lemonade server listening on 127.0.0.1:13305" | Write-Host

$info = Invoke-RestMethod -Uri 'http://127.0.0.1:13305/api/v1/system-info' -TimeoutSec 10
$npu = $info.devices.'amd_npu'
if ($npu.available -and $npu.family -match 'XDNA2') {
    "  [OK] Server sees amd_npu: available, family=$($npu.family)" | Write-Host
} else {
    "[FAIL] Server amd_npu state: $(($npu | ConvertTo-Json -Compress))" |
        Write-Host -ForegroundColor Red
    exit 1
}

$flmState = $info.recipes.'flm'.backends.'npu'.state
"  [ ] Recipes/flm/npu state: $flmState" | Write-Host

# ---------------------------------------------------------------------------
# Step 6: optional model pull
# ---------------------------------------------------------------------------
if ($Model -ne '') {
    "  Pulling model: $Model ..." | Write-Host
    & $lemonadeExe pull $Model 2>&1 | ForEach-Object { "  $_" }
    $pullExit = $LASTEXITCODE
    if ($pullExit -ne 0) {
        "[FAIL] pull exit code $pullExit" | Write-Host -ForegroundColor Red
        exit 1
    }
    "  [OK] Model $Model pulled." | Write-Host
}

"" | Write-Host
"=== VERDICT ===" | Write-Host -ForegroundColor Green
"  NPU bring-up: READY (Lemonade + FLM + XDNA2 driver) — port 13305" | Write-Host -ForegroundColor Green
"  Next: .\install-npu-lemonade.ps1 -Model qwen3-0.6b-FLM, then test:" | Write-Host -ForegroundColor Green
'    curl http://127.0.0.1:13305/api/v1/chat/completions -H "Content-Type: application/json" ` \' | Write-Host
'      -d ''{"model":"qwen3-0.6b-FLM","messages":[{"role":"user","content":"hi"}]}''' | Write-Host
exit 0