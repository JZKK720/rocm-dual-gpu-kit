# =============================================================================
# rocm-dual-gpu-kit  (ad-hoc evidence collector - not part of the kit)
# Read-only memory / GPU / Ollama environment probe.
# =============================================================================
$ErrorActionPreference = 'Continue'

function Section($t) { "" ; "=" * 74 ; "== $t" ; "=" * 74 }

Section "PHYSICAL RAM MODULES"
Get-CimInstance Win32_PhysicalMemory |
    Select-Object @{n='GB';e={[math]::Round($_.Capacity/1GB,1)}}, Speed, Manufacturer, PartNumber |
    Format-Table -AutoSize

Section "MEMORY TOTALS"
$cs = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem
"TotalPhysicalMemory : {0:N2} GiB" -f ($cs.TotalPhysicalMemory/1GB)
"TotalVisibleMemory  : {0:N2} GiB" -f ($os.TotalVisibleMemorySize/1MB)
"FreePhysicalMemory   : {0:N2} GiB" -f ($os.FreePhysicalMemory/1MB)
"TotalVirtualMemory   : {0:N2} GiB" -f ($os.TotalVirtualMemorySize/1MB)

Section "GPU ADAPTERS (Win32)"
Get-CimInstance Win32_VideoController |
    Select-Object Name,
        @{n='AdapterRAM_GB';e={[math]::Round($_.AdapterRAM/1GB,2)}},
        @{n='DriverVersion';e={$_.DriverVersion}},
        @{n='VideoModeDescription';e={$_.VideoModeDescription}} |
    Format-List

Section "AMD DRIVER VRAM KEYS (registry)"
$bases = @(
  'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000',
  'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0001'
)
foreach ($b in $bases) {
    if (Test-Path $b) {
        "--- $b"
        $p = Get-ItemProperty $b -ErrorAction SilentlyContinue
        foreach ($k in 'HardwareInformation.qwMemorySize','HardwareInformation.MemorySize',
                       'HardwareInformation.qwVramSize','HardwareInformation.AdapterString',
                       'DALNonStandardModesBCD1','PP_ThermalAutoThrottlingEnable') {
            if ($p.PSObject.Properties.Name -contains $k) {
                $v = $p.$k
                if ($v -is [byte[]] -and $v.Length -ge 8) {
                    "    {0,-40} = {1:N2} GiB" -f $k, ([BitConverter]::ToUInt64($v,0)/1GB)
                } else {
                    "    {0,-40} = {1}" -f $k, $v
                }
            }
        }
    }
}

Section "OLLAMA ENVIRONMENT (current process)"
Get-ChildItem Env: | Where-Object { $_.Name -match 'OLLAMA|HIP|ROCR|HSA|GGML|LLAMA' } |
    Sort-Object Name | ForEach-Object { "  {0,-34} = {1}" -f $_.Name, $_.Value }

Section "OLLAMA ENVIRONMENT (persisted user scope)"
foreach ($s in 'User','Machine') {
    foreach ($k in 'OLLAMA_MAX_LOADED_MODELS','OLLAMA_NUM_PARALLEL','OLLAMA_KEEP_ALIVE',
                   'OLLAMA_IGPU_ENABLE','OLLAMA_CONTEXT_LENGTH','OLLAMA_FLASH_ATTENTION',
                   'OLLAMA_KV_CACHE_TYPE','OLLAMA_MODELS','HIP_VISIBLE_DEVICES','ROCR_VISIBLE_DEVICES') {
        $v = [Environment]::GetEnvironmentVariable($k, $s)
        if ($v) { "  [{0}] {1,-32} = {2}" -f $s, $k, $v }
    }
}

Section "MODEL BLOB TOTAL ON DISK"
$manifestRoot = "$env:USERPROFILE\.ollama\models\manifests\registry.ollama.ai\library\qwen3.8-flash-next"
$mf = Get-ChildItem -LiteralPath $manifestRoot -Recurse -File | Select-Object -First 1
if ($mf) {
    $j = Get-Content -LiteralPath $mf.FullName -Raw | ConvertFrom-Json
    $tot = 0
    foreach ($l in $j.layers) {
        $tot += $l.size
        "  {0,-34} {1,9:N2} GB" -f $l.mediaType, ($l.size/1GB)
    }
    "  {0,-34} {1,9:N2} GB" -f 'TOTAL', ($tot/1GB)
}
"" 
