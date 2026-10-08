# =============================================================================
# DECISIVE TEST: truly force the iGPU.
#
# Why the earlier attempt failed:
#   OLLAMA_VULKAN=true makes the Vulkan backend enumerate BOTH GPUs independently
#   of HIP_VISIBLE_DEVICES. Setting HIP_VISIBLE_DEVICES=0 hid ROCm0 but Vulkan1
#   (the dGPU) remained, so Ollama still chose the dGPU.
#
# This script disables Vulkan AND pins HIP to device 0, leaving ROCm0 (iGPU)
# as the only candidate. It then measures where the weights land and how fast
# generation runs.
#
# Usage: .\force-igpu-real.ps1 -Ctx 8192
#        .\force-igpu-real.ps1 -Restore
# =============================================================================
param(
    [int]$Ctx = 8192,
    [int]$Predict = 128,
    [switch]$Restore
)

$ErrorActionPreference = 'Continue'
$TRAY = "$env:LOCALAPPDATA\Programs\Ollama\ollama app.exe"
$MODEL = 'qwen3.8-flash-next:125b-a6b-q4_K_M'
$TRACKED = @('OLLAMA_VULKAN', 'HIP_VISIBLE_DEVICES', 'ROCR_VISIBLE_DEVICES', 'OLLAMA_CONTEXT_LENGTH')

function Latest-Log {
    Get-ChildItem "$env:LOCALAPPDATA\Ollama" -Filter 'server*.log' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
function Restart-Tray {
    Get-Process -Name "ollama app" -EA SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    Get-Process -Name "ollama" -EA SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3
    Start-Process -FilePath $TRAY -WindowStyle Hidden
    Start-Sleep -Seconds 10
}

if ($Restore) {
    "=== RESTORE ==="
    [Environment]::SetEnvironmentVariable('OLLAMA_VULKAN', $null, 'User')
    [Environment]::SetEnvironmentVariable('HIP_VISIBLE_DEVICES', '0,1', 'User')
    [Environment]::SetEnvironmentVariable('ROCR_VISIBLE_DEVICES', '0,1', 'User')
    [Environment]::SetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', $null, 'User')
    foreach ($k in $TRACKED) { Remove-Item "Env:$k" -EA SilentlyContinue }
    Set-Item Env:HIP_VISIBLE_DEVICES '0,1'
    Set-Item Env:ROCR_VISIBLE_DEVICES '0,1'
    Restart-Tray
    "  restored: HIP=0,1 ROCR=0,1, Vulkan default"
    exit 0
}

# --- the combination that leaves ONLY the iGPU visible ---
[Environment]::SetEnvironmentVariable('OLLAMA_VULKAN', 'false', 'User')
Set-Item Env:OLLAMA_VULKAN 'false'
[Environment]::SetEnvironmentVariable('HIP_VISIBLE_DEVICES', '0', 'User')
Set-Item Env:HIP_VISIBLE_DEVICES '0'
[Environment]::SetEnvironmentVariable('ROCR_VISIBLE_DEVICES', '0', 'User')
Set-Item Env:ROCR_VISIBLE_DEVICES '0'
[Environment]::SetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', "$Ctx", 'User')
Set-Item Env:OLLAMA_CONTEXT_LENGTH "$Ctx"

"=== FORCE iGPU: OLLAMA_VULKAN=false, HIP_VISIBLE_DEVICES=0, ctx=$Ctx ==="
Restart-Tray
$log = (Latest-Log).FullName
"  log = $log"

try {
    '{"model":"nemotron-3.5-lightning:30b-a3b","keep_alive":0}' |
        Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post `
        -ContentType 'application/json' -TimeoutSec 30 | Out-Null
} catch { }
Start-Sleep -Seconds 3

$before = (Get-Item $log).Length
"  loading $MODEL (ctx=$Ctx) ..."

$body = @{
    model   = $MODEL
    prompt  = 'Describe how a mixture-of-experts model routes tokens to experts.'
    stream  = $false
    options = @{ num_ctx = $Ctx; num_predict = $Predict; temperature = 0 }
} | ConvertTo-Json -Depth 5

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $r = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post `
        -Body $body -ContentType 'application/json' -TimeoutSec 3600
    "  completed in $([math]::Round($sw.Elapsed.TotalSeconds,1))s"
    if ($r.prompt_eval_duration) {
        "  prompt eval : {0} tok in {1:N1}s -> {2:N2} tok/s" -f $r.prompt_eval_count,
            ($r.prompt_eval_duration / 1e9), ($r.prompt_eval_count / ($r.prompt_eval_duration / 1e9))
    }
    if ($r.eval_duration) {
        "  generation  : {0} tok in {1:N1}s -> {2:N2} tok/s" -f $r.eval_count,
            ($r.eval_duration / 1e9), ($r.eval_count / ($r.eval_duration / 1e9))
    }
} catch { "  ended after $([math]::Round($sw.Elapsed.TotalSeconds,1))s : $_" }

""
"=============== PLACEMENT ==============="
$log = (Latest-Log).FullName
$fs = [System.IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
$fs.Seek([Math]::Min($before, $fs.Length), 'Begin') | Out-Null
$sr = New-Object System.IO.StreamReader($fs)
$new = $sr.ReadToEnd(); $sr.Close(); $fs.Close()

$new -split "`n" | Select-String -Pattern `
    'llama_prepare_model_devices|offloaded [0-9]+/[0-9]+ layers|model buffer size|KV buffer size|n_ctx +=|common_param:   -|cannot meet free memory|inference compute' |
    ForEach-Object { "  " + $_.Line.Trim() }
""
