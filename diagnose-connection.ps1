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
# diagnose-connection.ps1
# Read-only diagnostic for the dGPU + USB4 / Thunderbolt dock connection.
# Walks the transport stack top-down: form factor -> USB4/TB4 -> PCIe -> AMD
# driver -> HIP runtime -> venv shadowing, and prints a per-layer verdict
# plus a single most-actionable "Suggested next" block.
#
# Usage:
#   .\diagnose-connection.ps1
#
# Optional env overrides:
#   $env:DIAG_DGPU_VENDOR_ID   (default 0x1002 = AMD)
#   $env:DIAG_DGPU_DEVICE_ID   (default 0x744C = Navi 31 RX 7900 XTX; informational only)
#   $env:DIAG_LOG_PATH         (default .\diagnose-connection.log)
#
# This script NEVER mutates registry, drivers, firmware, or env vars. It only
# reads. Remediation is the user's call. The output is a single screenshot-
# friendly verdict table.

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
""
"=== Connection diagnostic (read-only) ==="
"  time: $timestamp"
""

# Verdict counters. Layers push into these and we render the final table.
$verdicts = New-Object System.Collections.Generic.List[object]

function Add-Verdict {
    param([string]$Layer, [string]$Status, [string]$Evidence)
    $verdicts.Add([pscustomobject]@{ Layer = $Layer; Status = $Status; Evidence = $Evidence })
}

# -----------------------------------------------------------------------------
# Layer 1: Form factor & host platform
# -----------------------------------------------------------------------------
""
"--- 1. Form factor & host platform ---"

$formFactor = 'Unknown'
$evidence1  = ''
try {
    $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bb = Get-WmiObject -Class Win32_BaseBoard    -ErrorAction SilentlyContinue
    $bi = Get-WmiObject -Class Win32_BIOS         -ErrorAction SilentlyContinue
    if ($cs) {
        $pcType = $cs.PCSystemType
        # 1=Desktop, 2=Mobile(Laptop), 8=Workstation, etc.
        switch ($pcType) {
            1 { $formFactor = 'Desktop' }
            2 { $formFactor = 'Laptop' }
            8 { $formFactor = 'Workstation' }
            default { $formFactor = "Type $pcType" }
        }
        $tb4AddIn = $false
        try {
            $tb4AddIn = [bool](Get-PnpDevice -Class System -ErrorAction SilentlyContinue |
                Where-Object { $_.HardwareID -match 'PCI\\VEN_8086.*(0C03|9A1B|9A1F|9A21)' -or
                                 $_.FriendlyName -match 'Thunderbolt' } | Select-Object -First 1)
        } catch { $tb4AddIn = $false }
        if ($formFactor -eq 'Desktop' -and $tb4AddIn) {
            $formFactor = 'Desktop + TB4 add-in card'
        } elseif ($formFactor -eq 'Laptop' -and $tb4AddIn) {
            $formFactor = 'Laptop with built-in USB4'
        }
        "  System:        $($cs.Manufacturer) $($cs.Model)"
        "  Form factor:   $formFactor"
        if ($bb) { "  Baseboard:     $($bb.Manufacturer) $($bb.Product)" }
        if ($bi) { "  BIOS:          $($bi.SMBIOSBIOSVersion)  (release $($bi.ReleaseDate))" }
        $evidence1 = "$($cs.Manufacturer) $($cs.Model) :: $formFactor"
    } else {
        "  [!] WMI Win32_ComputerSystem unavailable."
        $evidence1 = 'WMI Win32_ComputerSystem unavailable'
    }
} catch {
    "  [!] WMI query failed: $($_.Exception.Message)"
    $evidence1 = "WMI error: $($_.Exception.Message)"
}

# Inferred topology: "dGPU over USB4-mapped PCIe" if we are in any USB4 topology,
# otherwise "dGPU on native PCIe slot".
$topology = 'native PCIe (dGPU in a motherboard slot)'
if ($formFactor -match 'USB4|TB4|Thunderbolt') { $topology = 'USB4 / TB4-mapped PCIe (dGPU behind a dock)' }
"  Topology:      $topology"
$evidence1 = "$evidence1 :: $topology"
Add-Verdict -Layer '1. Form factor / topology' -Status 'OK' -Evidence $evidence1

# -----------------------------------------------------------------------------
# Layer 2: USB4 / Thunderbolt topology
# -----------------------------------------------------------------------------
""
"--- 2. USB4 / Thunderbolt topology ---"

$tbStatus   = 'OK'
$tbEvidence = ''
$tbCount    = 0
$tbProblem  = $false
try {
    $tbDevices = @()
    $tbDevices += Get-PnpDevice -Class System -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -match 'USB4|Thunderbolt|TBT' -or $_.HardwareID -match 'USB4|TBT' }
    $tbDevices += Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.HardwareID -match 'USB4|TBT|Thunderbolt' -and ($_.Class -ne 'System') }

    $tbDevices = $tbDevices | Sort-Object -Property InstanceId -Unique

    foreach ($d in $tbDevices) {
        $tbCount++
        $errCode = if ($d.PSObject.Properties['ConfigManagerErrorCode']) { $d.ConfigManagerErrorCode } else { 0 }
        $errHex  = '0x{0:X2}' -f [int]$errCode
        $problem = ($d.Status -ne 'OK') -or ($errCode -ne 0)
        $tag     = if ($problem) { '[!]' } else { '[ ]' }
        "  $tag $($d.FriendlyName)"
        "      instance:  $($d.InstanceId)"
        "      status:    $($d.Status)  (CM error code: $errHex)"
        if ($problem) { $tbProblem = $true }
    }
    if ($tbCount -eq 0) {
        "  [!] No USB4 / Thunderbolt devices found via PnP."
        $tbStatus   = 'WARN'
        $tbEvidence = 'No USB4 / Thunderbolt devices enumerated (controller may be off, BIOS disabled, or driver missing)'
    } else {
        $tbHealthy = @($tbDevices | Where-Object { $_.Status -eq 'OK' -and ($_.ConfigManagerErrorCode -eq 0) }).Count
        $tbEvidence = "$tbCount USB4/TB device(s) found ($tbHealthy OK)"
        if ($tbProblem) {
            # Distinguish "the host controller is broken" (true FAIL) from "one downstream
            # router on the dock is degraded" (WARN, since dGPU may still enumerate under
            # the OK router's tunnel).
            $hostBroken = $tbDevices | Where-Object { $_.Class -eq 'System' -and ($_.Status -ne 'OK' -or $_.ConfigManagerErrorCode -ne 0) }
            if ($hostBroken) {
                $tbStatus   = 'FAIL'
                $tbEvidence = "$tbEvidence, host USB4 router is degraded (true FAIL -- dGPU will not enumerate)"
            } else {
                $tbStatus   = 'WARN'
                $tbEvidence = "$tbEvidence, at least one downstream device degraded (WARN -- dGPU may still enumerate under the OK tunnel)"
            }
        }
    }
    $usb4Net = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'USB4|Thunderbolt' -or $_.InterfaceDescription -match 'USB4|Thunderbolt' }
    if ($usb4Net) {
        foreach ($n in $usb4Net) {
            "  [ ] NetAdapter: $($n.Name)  ($($n.Status))  LinkSpeed=$($n.LinkSpeed)"
        }
    } else {
        "  [i] No USB4/Thunderbolt NetAdapter present (expected for non-networked docks)"
    }
    try {
        $evts = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='*Thunderbolt*,*USB4*'; StartTime=(Get-Date).AddHours(-1) } -ErrorAction SilentlyContinue
        if ($evts) {
            "  Recent USB4/TB events (last 1h):"
            $evts | Select-Object -First 5 -Property TimeCreated,ProviderName,Id,LevelDisplayName,Message |
                ForEach-Object { "      $($_.TimeCreated.ToString('HH:mm:ss')) [$($_.LevelDisplayName)] $($_.ProviderName)/$($_.Id) :: $($_.Message.Split([Environment]::NewLine)[0])" }
        }
    } catch { }
} catch {
    "  [!] PnP enumeration failed: $($_.Exception.Message)"
    $tbStatus   = 'WARN'
    $tbEvidence = "PnP error: $($_.Exception.Message)"
}
Add-Verdict -Layer '2. USB4 / Thunderbolt' -Status $tbStatus -Evidence $tbEvidence

# -----------------------------------------------------------------------------
# Layer 3: PCIe link state
# -----------------------------------------------------------------------------
""
"--- 3. PCIe link state (AMD = vendor 0x1002) ---"

$pcieStatus   = 'OK'
$pcieEvidence = ''
$amdDevices   = @()
try {
    $amdDevices = Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match 'PCI\\VEN_1002' -or $_.InstanceId -match 'PCI\\VEN_1022' }
    # Filter for the discrete-class GPUs only. RDNA 3 dGPUs surface as PCI\VEN_1002&DEV_....
    $dGPUs = @($amdDevices | Where-Object { $_.Class -eq 'Display' -or $_.FriendlyName -match 'RX\s*\d' -or $_.InstanceId -match 'DEV_7[0-9A-F]{3}|DEV_73[0-9A-F]{2}' })
    $igpus = @($amdDevices | Where-Object { $_.Class -ne 'Display' -and $_.FriendlyName -match 'Graphics' -and $_.FriendlyName -notmatch 'RX\s*\d' })

    if ($dGPUs.Count -eq 0) {
        "  [!] No discrete AMD GPU (RX class) found via PnP."
        $pcieStatus   = 'FAIL'
        $pcieEvidence = 'No AMD discrete GPU in PnP. Check: dock power, TB4 cable, TB4 BIOS setting, USB4 controller driver.'
    } else {
        # The dock can enumerate the card, then re-enumerate it on a hot-plug event.
        # The "double entry" symptom is a stale driver handle -- the first instance
        # holds the device open, the second can't bind the AMD driver.
        $rxEntries   = @($dGPUs | Where-Object { $_.FriendlyName -match 'RX\s*7\d{3}' -or $_.InstanceId -match 'DEV_744C' })
        $broken      = @($rxEntries | Where-Object { $_.Status -ne 'OK' -or $_.ConfigManagerErrorCode -ne 0 })
        $duplicated  = $rxEntries.Count -gt 1
        $linkText    = ''
        foreach ($d in $dGPUs) {
            $errCode = if ($d.PSObject.Properties['ConfigManagerErrorCode']) { $d.ConfigManagerErrorCode } else { 0 }
            $errHex  = '0x{0:X2}' -f [int]$errCode
            $tag     = if ($d.Status -ne 'OK' -or $errCode -ne 0) { '[!]' } else { '[ ]' }
            "  $tag $($d.FriendlyName)"
            "      instance:  $($d.InstanceId)"
            "      status:    $($d.Status)  (CM error code: $errHex)"
            # Try to read current PCIe link speed from the parent port.
            try {
                $props = Get-PnpDeviceProperty -InstanceId $d.InstanceId -ErrorAction SilentlyContinue
                $key   = 'DEVPKEY_PciDevice_CurrentLinkSpeed'
                $kprop = $props | Where-Object { $_.KeyName -eq $key }
                if ($kprop) {
                    $linkText = $kprop.Data
                    "      current:   $linkText"
                }
            } catch { }
        }
        if ($duplicated -and $broken.Count -gt 0) {
            $pcieStatus   = 'FAIL'
            $pcieEvidence = "$($rxEntries.Count) RX 7900 XTX entries in PnP, $($broken.Count) in non-OK state -- classic stale-driver-handle after a dock re-enumerate. Fix: uninstall the AMD dGPU device in Device Manager with 'Delete the driver software' then Scan for hardware changes."
        } elseif ($rxEntries.Count -eq 0) {
            $pcieStatus   = 'WARN'
            $pcieEvidence = "$($dGPUs.Count) AMD device(s) present in PnP but none matched the RX 7900 XTX heuristic"
        } elseif ($broken.Count -gt 0) {
            $pcieStatus   = 'FAIL'
            $pcieEvidence = "$($rxEntries.Count) RX 7900 XTX entry(ies) in PnP, all in non-OK state (CM 0x$('{0:X2}' -f [int]$broken[0].ConfigManagerErrorCode))"
        } else {
            # Single healthy RX 7900 XTX.
            $pcieStatus   = 'OK'
            $primary      = $rxEntries[0]
            if ($linkText) {
                $pcieEvidence = "$($primary.FriendlyName) OK in PnP, link=$linkText"
            } else {
                $pcieEvidence = "$($primary.FriendlyName) OK in PnP (link speed unavailable)"
            }
        }
    }
    if ($igpus.Count -gt 0) {
        ""
        "  iGPU (informational):"
        foreach ($i in $igpus) { "    [ ] $($i.FriendlyName)  [$($i.Status)]" }
    }
} catch {
    "  [!] PnP enumeration failed: $($_.Exception.Message)"
    $pcieStatus   = 'WARN'
    $pcieEvidence = "PnP error: $($_.Exception.Message)"
}
Add-Verdict -Layer '3. PCIe (AMD dGPU)' -Status $pcieStatus -Evidence $pcieEvidence

# -----------------------------------------------------------------------------
# Layer 4: AMD driver layer
# -----------------------------------------------------------------------------
""
"--- 4. AMD driver layer ---"

$drvStatus   = 'OK'
$drvEvidence = ''
try {
    $amdDrv = Get-WmiObject Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceName -match 'AMD|Radeon|ATIKMDAG|amdkmdag|amdfendr' }
    if ($amdDrv) {
        foreach ($d in $amdDrv | Select-Object -First 8) {
            "  [ ] $($d.DeviceName)"
            "      driver:   $($d.DriverVersion)  ($($d.DriverDate))"
            "      inf:      $($d.InfName)"
        }
        $drvEvidence = "$($amdDrv.Count) AMD driver entry(ies) installed"
    } else {
        "  [!] No AMD signed drivers registered in WMI."
        $drvStatus   = 'WARN'
        $drvEvidence = 'No AMD signed drivers found in WMI'
    }
    try {
        $evts = Get-WinEvent -FilterHashtable @{ LogName='System'; StartTime=(Get-Date).AddHours(-1) } -ErrorAction SilentlyContinue |
            Where-Object { $_.ProviderName -match 'atikmdag|amdfendr|amdkmdag|DriverFrameworks-UserMode|Application Error' }
        if ($evts) {
            "  Recent AMD driver / kernel events (last 1h):"
            $evts | Select-Object -First 5 -Property TimeCreated,ProviderName,Id,LevelDisplayName,Message |
                ForEach-Object { "      $($_.TimeCreated.ToString('HH:mm:ss')) [$($_.LevelDisplayName)] $($_.ProviderName)/$($_.Id) :: $($_.Message.Split([Environment]::NewLine)[0])" }
            $drvEvidence = "$drvEvidence; $($evts.Count) related event(s) in last 1h"
        } else {
            "  [i] No AMD driver / kernel events in the last 1h."
        }
    } catch { }
} catch {
    "  [!] WMI Win32_PnPSignedDriver query failed: $($_.Exception.Message)"
    $drvStatus   = 'WARN'
    $drvEvidence = "WMI error: $($_.Exception.Message)"
}
Add-Verdict -Layer '4. AMD driver' -Status $drvStatus -Evidence $drvEvidence

# -----------------------------------------------------------------------------
# Layer 5: HIP runtime + venv shadowing
# -----------------------------------------------------------------------------
""
"--- 5. HIP runtime + venv shadowing ---"

$hipStatus   = 'OK'
$hipEvidence = ''

""
"  env:"
"    HIP_PATH  = $($env:HIP_PATH)"
"    ROCM_PATH = $($env:ROCM_PATH)"
$venvShadow = ($env:HIP_PATH -and ($env:HIP_PATH -match '\\.venv\\' -or $env:HIP_PATH -match '\\rocm-sdk\\')) -and
              ($env:DETECT_DGPU_ARCH -or $env:HIP_VISIBLE_DEVICES)
if ($venvShadow) {
    "  [!] HIP_PATH points to a venv while a dGPU target is requested -- venv shadowing."
    "      This is the AGENTS.md invariant-#3 bug. Run deactivate-dgpu.ps1 or rollback-rewire.ps1."
    $hipStatus   = 'WARN'
    $hipEvidence = 'venv shadowing: HIP_PATH is a venv path while dGPU expected'
} else {
    "  [i] No venv shadowing detected in env."
}

# Find hipInfo
$hipInfo = $null
$hipSdk  = $null
foreach ($c in @('C:\Program Files\AMD\ROCm\7.1','C:\Program Files\AMD\ROCm\7.0','C:\Program Files\AMD\ROCm\6.4','C:\Program Files\AMD\ROCm')) {
    if ((Test-Path $c) -and (Test-Path (Join-Path $c 'bin\hipInfo.exe'))) { $hipSdk = $c; break }
}
if ($hipSdk) { $hipInfo = Join-Path $hipSdk 'bin\hipInfo.exe' }
# Fall back to the venv that rewire-igpu.ps1 stashes in the user PATH.
if (-not $hipInfo) {
    $hipOnPath = (Get-Command hipInfo -ErrorAction SilentlyContinue).Source
    if ($hipOnPath -and (Test-Path $hipOnPath)) {
        $hipSdk  = Split-Path -Parent (Split-Path -Parent $hipOnPath)
        $hipInfo = $hipOnPath
    }
}
if ($hipInfo -and -not (Test-Path $hipInfo)) { $hipInfo = $null }

if ($hipInfo -and (Test-Path $hipInfo)) {
    "  hipInfo: $hipInfo"
    $out = & $hipInfo 2>&1 | Out-String
    $deviceMatches = [regex]::Matches($out, '(?ms)device#\s+\d+')
    "  hipInfo devices found: $($deviceMatches.Count)"
    if ($deviceMatches.Count -eq 0) {
        $hipStatus   = 'FAIL'
        $hipEvidence = 'hipInfo enumerated 0 devices (driver sees the card but ROCm does not)'
    } else {
        foreach ($m in $deviceMatches) {
            $nmLine = ($out.Substring($m.Index, [Math]::Min(80, $out.Length - $m.Index)) -split "`n")[0]
            "      $nmLine" | Out-Null
        }
        $hipEvidence = "$($deviceMatches.Count) device(s) visible to ROCm"
    }
} else {
    "  [!] No hipInfo found; HIP SDK not installed or not on PATH."
    $hipStatus   = 'WARN'
    $hipEvidence = 'No hipInfo binary (install HIP SDK or use the iGPU venv python -m rocm_sdk test for runtime smoke)'
}
Add-Verdict -Layer '5. HIP runtime / venv' -Status $hipStatus -Evidence $hipEvidence

# -----------------------------------------------------------------------------
# Layer 6: rocm-smi (optional, only if on PATH)
# -----------------------------------------------------------------------------
""
"--- 6. rocm-smi (optional) ---"
$rsmi = (Get-Command rocm-smi -ErrorAction SilentlyContinue).Source
if ($rsmi) {
    "  rocm-smi: $rsmi"
    $out = & rocm-smi --showid 2>&1 | Out-String
    if ($out) {
        $out.Split([Environment]::NewLine) | Select-Object -First 20 | ForEach-Object { "    $_" }
        $devs = [regex]::Matches($out, 'GPU\[\d+\]')
        Add-Verdict -Layer '6. rocm-smi' -Status 'OK' -Evidence "$($devs.Count) GPU(s) reported by rocm-smi"
    } else {
        Add-Verdict -Layer '6. rocm-smi' -Status 'WARN' -Evidence 'rocm-smi returned no output'
    }
} else {
    "  [i] rocm-smi not on PATH; skipping (non-fatal)."
    Add-Verdict -Layer '6. rocm-smi' -Status 'WARN' -Evidence 'rocm-smi not installed (optional signal)'
}

# -----------------------------------------------------------------------------
# Verdict table
# -----------------------------------------------------------------------------
""
"=== VERDICT (top-down, fix the first FAIL first) ==="
"{0,-32} {1,-6} {2}" -f 'Layer', 'State', 'Evidence'
('-' * 100)
foreach ($v in $verdicts) {
    $color = 'White'
    switch ($v.Status) { 'OK'   { $color = 'Green' } 'WARN' { $color = 'Yellow' } 'FAIL' { $color = 'Red' } }
    "{0,-32} {1,-6} {2}" -f $v.Layer, $v.Status, $v.Evidence
}

# -----------------------------------------------------------------------------
# Suggested next
# -----------------------------------------------------------------------------
""
"=== Suggested next ==="

$firstFail = $verdicts | Where-Object { $_.Status -eq 'FAIL' } | Select-Object -First 1
$anyWarn   = $verdicts | Where-Object { $_.Status -eq 'WARN' } | Select-Object -First 1

if ($firstFail -and $firstFail.Layer -match 'USB4') {
    "  - Re-seat the USB4 / Thunderbolt cable at both ends."
    "  - Confirm the dock has its own PSU powered on."
    "  - Re-check BIOS: Thunderbolt / USB4 must be 'Enabled', not 'Discrete'."
    "  - Re-run this script to confirm topology returns."
} elseif ($firstFail -and $firstFail.Layer -match 'PCIe') {
    "  - The dGPU is not in PnP. Open Device Manager -> View -> Show hidden devices."
    "  - Check the 'System devices' tree for the USB4 / TB4 root."
    "  - Try a different TB4 cable (some cables are USB-C 10Gbps, not 40Gbps)."
    "  - Re-seat the RX 7900 XTX in the dock PCIe slot."
} elseif ($firstFail -and $firstFail.Layer -match 'HIP') {
    "  - HIP runtime sees 0 devices even though PnP sees the card. Usually a venv shadow."
    "    Run: . .\deactivate-dgpu.ps1  (if active)"
    "    Or:  . .\rollback-rewire.ps1   (if the iGPU rewire is shadowing HIP_PATH)"
    "  - Then re-run validate.ps1."
} elseif ($firstFail) {
    "  - First-fail layer: $($firstFail.Layer)"
    "    Evidence: $($firstFail.Evidence)"
} elseif ($venvShadow) {
    "  - Venv shadowing detected. Run: . .\deactivate-dgpu.ps1"
    "  - If that doesn't help: . .\rollback-rewire.ps1"
} else {
    "  - All transport / driver / runtime layers report OK."
    "  - Re-run: . .\activate-dgpu.ps1 ; .\validate.ps1"
}

if ($anyWarn) {
    ""
    "  WARN layers (non-fatal, but worth attention):"
    foreach ($w in $verdicts | Where-Object { $_.Status -eq 'WARN' }) {
        "    - $($w.Layer): $($w.Evidence)"
    }
}

# -----------------------------------------------------------------------------
# Optional log persistence
# -----------------------------------------------------------------------------
$logPath = $env:DIAG_LOG_PATH
if (-not $logPath) { $logPath = Join-Path $PSScriptRoot 'diagnose-connection.log' }
try {
    $lines = @()
    $lines += "=== diagnose-connection.ps1 $timestamp ==="
    foreach ($v in $verdicts) { $lines += ("{0,-32} {1,-6} {2}" -f $v.Layer, $v.Status, $v.Evidence) }
    $lines | Out-File -FilePath $logPath -Encoding ascii -Force
    ""
    "  Log: $logPath"
} catch { }

""
"=== Diagnostic complete ==="
