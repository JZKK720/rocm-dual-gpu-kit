# =============================================================================
# BOTTLENECK MEASUREMENT
#
# Runs a long generation in the background while sampling disk-read throughput,
# hard page faults, and available memory. Distinguishes:
#   (a) disk/page-cache bound  -> high disk reads, low available RAM
#   (b) RAM-bandwidth bound    -> near-zero disk reads
#   (c) GPU bound              -> neither
#
# Usage: .\measure-io.ps1 -Ctx 8192 -Predict 200
# =============================================================================
param(
    [int]$Ctx = 8192,
    [int]$Predict = 200,
    [string]$Model = 'qwen3.8-flash-next:125b-a6b-q4_K_M'
)

$ErrorActionPreference = 'Continue'

# --- warm the model so the load phase doesn't pollute the sample ---
"warming model at ctx=$Ctx ..."
$warm = @{
    model = $Model; prompt = 'hi'; stream = $false
    options = @{ num_ctx = $Ctx; num_predict = 1 }
} | ConvertTo-Json -Depth 5
try {
    Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post `
        -Body $warm -ContentType 'application/json' -TimeoutSec 1800 | Out-Null
    "  warm-up done."
} catch { "  warm-up failed: $_" }

# --- capture baselines ---
$osBefore = Get-CimInstance Win32_OperatingSystem
$pfBefore = Get-CimInstance Win32_PageFileUsage
$memBefore = (Get-Counter '\Memory\Available Bytes' -EA SilentlyContinue).CounterSamples[0].CookedValue
$diskBefore = (Get-Counter '\PhysicalDisk(_Total)\Disk Read Bytes/sec' -EA SilentlyContinue)

"  available RAM before : {0,8:N2} GiB" -f ($memBefore / 1GB)
"  pagefile used before : {0,8:N1} MiB" -f $pfBefore.CurrentUsage

# --- launch generation in background ---
""
"starting background generation (num_predict=$Predict) ..."
$job = Start-Job -ScriptBlock {
    param($m, $p, $c)
    $body = @{
        model = $m; prompt = $p; stream = $false
        options = @{ num_ctx = $c; num_predict = 200; temperature = 0 }
    } | ConvertTo-Json -Depth 5
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post `
            -Body $body -ContentType 'application/json' -TimeoutSec 3600
        [pscustomobject]@{
            Ok = $true; Secs = $sw.Elapsed.TotalSeconds
            PE = $r.prompt_eval_count; PED = $r.prompt_eval_duration
            EC = $r.eval_count;        ED = $r.eval_duration
        }
    } catch {
        [pscustomobject]@{ Ok = $false; Err = "$_" }
    }
} -ArgumentList $Model, 'Describe how a mixture-of-experts model routes tokens to experts, in detail.', $Ctx

# --- sample while it runs ---
$samples = @()
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($job.State -eq 'Running' -and $sw.Elapsed.TotalSeconds -lt 300) {
    $d = (Get-Counter '\PhysicalDisk(_Total)\Disk Read Bytes/sec' -EA SilentlyContinue).CounterSamples
    $m = (Get-Counter '\Memory\Available Bytes' -EA SilentlyContinue).CounterSamples
    $p = (Get-Counter '\Memory\Page Reads/sec' -EA SilentlyContinue).CounterSamples
    $samples += [pscustomobject]@{
        t     = [math]::Round($sw.Elapsed.TotalSeconds, 0)
        dRead = if ($d) { [math]::Round($d[0].CookedValue / 1MB, 1) } else { 0 }
        avail = if ($m) { [math]::Round($m[0].CookedValue / 1GB, 2) } else { 0 }
        pgRd  = if ($p) { [math]::Round($p[0].CookedValue, 0) } else { 0 }
    }
    Start-Sleep -Milliseconds 900
}
$jobResult = Receive-Job -Job $job -Wait -AutoRemoveJob:$false
Remove-Job -Job $job -Force

""
"=============== SAMPLES (t, MiB/s disk read, GiB avail, page-reads/s) ==============="
$samples | Format-Table -AutoSize | Out-String | ForEach-Object { $_.Trim() }

$avgRead = ($samples | Measure-Object dRead -Average).Average
$maxRead = ($samples | Measure-Object dRead -Maximum).Maximum
$minAvail = ($samples | Measure-Object avail -Minimum).Minimum

""
"=============== VERDICT ==============="
"  avg disk read during gen : {0,10:N1} MiB/s" -f $avgRead
"  peak disk read           : {0,10:N1} MiB/s" -f $maxRead
"  min available RAM        : {0,10:N2} GiB" -f $minAvail
$pfAfter = Get-CimInstance Win32_PageFileUsage
"  pagefile used after      : {0,10:N1} MiB  (peak {1:N1})" -f $pfAfter.CurrentUsage, $pfAfter.PeakUsage

if ($jobResult.Ok) {
    "  prompt eval : {0} tok in {1:N1}s -> {2:N2} tok/s" -f `
        $jobResult.PE, ($jobResult.PED / 1e9), ($jobResult.PE / ($jobResult.PED / 1e9))
    "  generation  : {0} tok in {1:N1}s -> {2:N2} tok/s" -f `
        $jobResult.EC, ($jobResult.ED / 1e9), ($jobResult.EC / ($jobResult.ED / 1e9))
} else {
    "  generation failed: $($jobResult.Err)"
}

""
if ($avgRead -gt 200) {
    "  >>> DISK-BOUND: weights are streaming from NVMe, not resident in RAM."
} elseif ($avgRead -gt 30) {
    "  >>> PARTIALLY DISK-BOUND: some expert paging occurring."
} else {
    "  >>> NOT DISK-BOUND: bottleneck is RAM/GPU bandwidth."
}
""
