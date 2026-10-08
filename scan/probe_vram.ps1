# =============================================================================
# Read-only VRAM probe: DXGI dedicated/shared per adapter + AMD driver registry.
# No writes, no driver changes. Used to determine whether the iGPU's reported
# ~99 GB is real dedicated memory or an aperture over-report.
# =============================================================================
$ErrorActionPreference = 'Continue'

"=========================================================================="
"== DXGI ADAPTER MEMORY (dedicated vs shared)"
"=========================================================================="
$tmp = Join-Path $env:TEMP "dxdiag_probe.txt"
if (Test-Path $tmp) { Remove-Item $tmp -Force }
try {
    Start-Process -FilePath "dxdiag.exe" -ArgumentList "/t", $tmp -Wait -WindowStyle Hidden
} catch {
    "dxdiag failed: $_"
}
if (Test-Path $tmp) {
    Get-Content $tmp |
        Select-String -Pattern 'Card name|Chip type|Dedicated Memory|Shared Memory|Display Memory|Driver Model|Driver Version' |
        ForEach-Object { "  " + $_.Line.Trim() }
} else {
    "  (dxdiag produced no file)"
}

""
"=========================================================================="
"== AMD DRIVER REGISTRY: memory-related values per adapter"
"=========================================================================="
$base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
Get-ChildItem $base -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($p.DriverDesc) {
        "--- [{0}]  {1}" -f $_.PSChildName, $p.DriverDesc
        foreach ($n in ($p.PSObject.Properties.Name | Where-Object { $_ -match 'Memory|Vram|UMA|Segment|Aperture|Dedicated' })) {
            $v = $p.$n
            if ($v -is [byte[]] -and $v.Length -ge 8) {
                "      {0,-42} = {1,10:N2} GiB" -f $n, ([BitConverter]::ToUInt64($v, 0) / 1GB)
            } elseif ($v -is [uint64] -or $v -is [int64]) {
                "      {0,-42} = {1,10:N2} GiB" -f $n, ($v / 1GB)
            } else {
                "      {0,-42} = {1}" -f $n, $v
            }
        }
    }
}

""
"=========================================================================="
"== WMI: adapter capacity vs system RAM"
"=========================================================================="
"  Win32_VideoController.AdapterRAM is uint32-capped (always ~4 GiB); ignore it."
"  MemoryArray MaxCapacity : {0,10:N2} GiB" -f ((Get-CimInstance Win32_PhysicalMemoryArray).MaxCapacity / 1MB)
"  Sum of DIMM Capacity    : {0,10:N2} GiB" -f (((Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum) / 1GB)
"  OS TotalVisible         : {0,10:N2} GiB" -f ((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1MB)
""
