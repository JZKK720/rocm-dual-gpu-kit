# =============================================================================
# Read-only: pagefile / commit-limit / UMA carve-out probe.
# The commit limit, not raw RAM, is what caps memory-mapped weights.
# =============================================================================
$ErrorActionPreference = 'Continue'

function Sec($t) { ""; "=" * 74; "== $t"; "=" * 74 }

Sec "PAGEFILE CONFIGURATION"
Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue |
    Select-Object Name, InitialSize, MaximumSize | Format-List
"--- Win32_PageFileUsage ---"
Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue |
    Select-Object Name, AllocatedBaseSize, CurrentUsage, PeakUsage | Format-List
"--- AutomaticManagedPagefile ---"
(Get-CimInstance Win32_ComputerSystem).AutomaticManagedPagefile

Sec "COMMIT LIMIT vs PHYSICAL"
$os = Get-CimInstance Win32_OperatingSystem
"  TotalVisibleMemorySize : {0,10:N2} GiB" -f ($os.TotalVisibleMemorySize / 1MB)
"  FreePhysicalMemory     : {0,10:N2} GiB" -f ($os.FreePhysicalMemory / 1MB)
"  TotalVirtualMemorySize : {0,10:N2} GiB" -f ($os.TotalVirtualMemorySize / 1MB)
"  FreeVirtualMemory      : {0,10:N2} GiB" -f ($os.FreeVirtualMemory / 1MB)

Sec "MEMORY PERF COUNTERS (GiB)"
foreach ($c in '\Memory\Committed Bytes', '\Memory\Commit Limit',
               '\Memory\Available Bytes', '\Memory\Pool Paged Bytes',
               '\Memory\Pool Nonpaged Bytes', '\Memory\Cache Bytes',
               '\Memory\Standby Cache Normal Priority Bytes',
               '\Memory\Modified Page List Bytes') {
    $s = (Get-Counter $c -ErrorAction SilentlyContinue).CounterSamples
    if ($s) { "  {0,-52} {1,10:N2}" -f ($c -replace '\\Memory\\', ''), ($s[0].CookedValue / 1GB) }
}

Sec "UMA / iGPU CARVE-OUT EVIDENCE"
$k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0001'
if (Test-Path $k) {
    $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
    foreach ($n in ($p.PSObject.Properties.Name | Where-Object { $_ -match 'Memory|Vram|UMA|Segment|Aperture' })) {
        $v = $p.$n
        if ($v -is [byte[]] -and $v.Length -ge 8) {
            "  {0,-42} = {1,10:N2} GiB" -f $n, ([BitConverter]::ToUInt64($v, 0) / 1GB)
        } else {
            "  {0,-42} = {1}" -f $n, $v
        }
    }
}

""
"  INTERPRETATION"
"  ------------"
$phys = [math]::Round(((Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum) / 1GB, 1)
$osvis = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$igpuReg = 64.0
"  Physical modules populated : {0,8:N1} GiB" -f $phys
"  OS-visible RAM             : {0,8:N1} GiB" -f $osvis
"  iGPU driver qwMemorySize   : {0,8:N1} GiB" -f $igpuReg
"  => gap (carve-out or reserve) : {0,6:N1} GiB" -f ($phys - $osvis)
""
