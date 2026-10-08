# =============================================================================
# DECISIVE OPTIMISATION TEST
#
# Ollama 0.34.1 currently picks the dGPU (24 GB) and pushes ~79 GB to host
# RAM/pagefile -> disk thrash. The iGPU exposes far more memory. This script
# forces the iGPU via Vulkan device pinning and measures the difference.
#
# Usage: .\force-igpu.ps1                  # pin iGPU via Vulkan
#        .\force-igpu.ps1 -Ctx 8192
#        .\force-igpu.ps1 -Restore          # undo all changes
# =============================================================================
param(
    [int]$Ctx = 8192,
    [int]$Predict = 128,
    [switch]$Restore
)

$ErrorActionPreference = 'Continue'
$TRAY = "$env:LOCALAPPDATA\Programs\Ollama\ollama app.exe"
$MODEL = 'qwen3.8-flash-next:125b-a6b-q4_K_M'
$TRACKED = @('GGML_VK_VISIBLE_DEVICES', 'OLLAMA_VULKAN', 'OLLAMA_CONTEXT_LENGTH')

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
    Start-Sleep -Seconds 9
}

if ($Restore) {
    "=== RESTORE ==="
    foreach ($k in $TRACKED) {
        [Environment]::SetEnvironmentVariable($k, $null, 'User')
        Remove-Item "Env:$k" -ErrorAction SilentlyContinue
        "  cleared $k"
    }
    Restart-Tray
    "  tray restarted with defaults."
    exit 0
}

# --- pin the iGPU. Vulkan exposes 106 GiB free on the iGPU vs 24 GiB on dGPU.
[Environment]::SetEnvironmentVariable('GGML_VK_VISIBLE_DEVICES', '0', 'User')
Set-Item Env:GGML_VK_VISIBLE_DEVICES '0'
[Environment]::SetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', "$Ctx", 'User')
Set-Item Env:OLLAMA_CONTEXT_LENGTH "$Ctx"

"=== FORCE iGPU (GGML_VK_VISIBLE_DEVICES=0, ctx=$Ctx) ==="
Restart-Tray

$log = (Latest-Log).FullName
"  log = $log"

# unload everything first
try {
    '{"model":"nemotron-3.5-lightning:30b-a3b","keep_alive":0}' |
        Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post `
        -ContentType 'application/json' -TimeoutSec 30 | Out-Null
} catch { }
Start-Sleep -Seconds 3

$before = (Get-Item $log).Length
"  loading $MODEL (ctx=$Ctx, predict=$Predict) ..."

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
    if ($r.eval_duration) {
        "  prompt eval : {0} tok in {1:N1}s -> {2:N2} tok/s" -f `
            $r.prompt_eval_count, ($r.prompt_eval_duration / 1e9), `
            ($r.prompt_eval_count / ($r.prompt_eval_duration / 1e9))
    }
    if ($r.eval_duration) {
        "  generation  : {0} tok in {1:N1}s -> {2:N2} tok/s" -f `
            $r.eval_count, ($r.eval_duration / 1e9), ($r.eval_count / ($r.eval_duration / 1e9))
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
