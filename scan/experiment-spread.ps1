# =============================================================================
# DECISIVE EXPERIMENT: can Ollama spread one model across iGPU + dGPU?
#
# Sets OLLAMA_SCHED_SPREAD=1 + a small context (to make the fit easy), restarts
# the Ollama tray app, loads the model, then reports the device placement from
# the server log.
#
# Usage:
#   .\experiment-spread.ps1 -Spread 1     # test spread ON
#   .\experiment-spread.ps1 -Spread 0     # baseline (single GPU)
#   .\experiment-spread.ps1 -Restore      # remove test env vars, restart
# =============================================================================
param(
    [int]$Spread = 1,
    [int]$Ctx = 8192,
    [switch]$Restore
)

$ErrorActionPreference = 'Continue'
$LOG = "$env:LOCALAPPDATA\Ollama\server.log"
$TRAY = "$env:LOCALAPPDATA\Programs\Ollama\ollama app.exe"

function Restart-Tray {
    Get-Process -Name "ollama app" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    Get-Process -Name "ollama" -ErrorAction SilentlyContinue | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
    Get-Process -Name "ollama" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    Start-Process -FilePath $TRAY -WindowStyle Hidden
    Start-Sleep -Seconds 5
}

if ($Restore) {
    "=== RESTORE: removing experiment env vars ==="
    foreach ($k in 'OLLAMA_SCHED_SPREAD', 'OLLAMA_CONTEXT_LENGTH') {
        [Environment]::SetEnvironmentVariable($k, $null, 'User')
        "  removed $k"
    }
    Restart-Tray
    "  done. tray restarted with original config."
    exit 0
}

"=== EXPERIMENT: OLLAMA_SCHED_SPREAD=$Spread  ctx=$Ctx ==="
[Environment]::SetEnvironmentVariable('OLLAMA_SCHED_SPREAD', "$Spread", 'User')
[Environment]::SetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', "$Ctx", 'User')
"  set OLLAMA_SCHED_SPREAD = $Spread"
"  set OLLAMA_CONTEXT_LENGTH = $Ctx"

$before = if (Test-Path $LOG) { (Get-Item $LOG).Length } else { 0 }
"  log baseline bytes = $before"

"  restarting tray app..."
Restart-Tray
"  tray app restarted."

"  loading model (num_ctx=$Ctx) ... this takes a while."
$body = @{
    model   = 'qwen3.8-flash-next:125b-a6b-q4_K_M'
    prompt  = 'hi'
    stream  = $false
    options = @{ num_ctx = $Ctx; num_predict = 1 }
} | ConvertTo-Json -Depth 5

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $r = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post `
        -Body $body -ContentType 'application/json' -TimeoutSec 1800
    "  load+gen completed in $([math]::Round($sw.Elapsed.TotalSeconds,1))s"
} catch {
    "  request failed after $([math]::Round($sw.Elapsed.TotalSeconds,1))s : $_"
}

"" 
"=================== DEVICE PLACEMENT (new log lines) ==================="
$fs = [System.IO.File]::Open($LOG, 'Open', 'Read', 'ReadWrite')
$fs.Seek($before, 'Begin') | Out-Null
$sr = New-Object System.IO.StreamReader($fs)
$new = $sr.ReadToEnd()
$sr.Close(); $fs.Close()

$patterns = 'llama_prepare_model_devices|common_param:   -|offloaded [0-9]+/[0-9]+ layers|model buffer size|KV buffer size|n_ctx + =|fit_params|memory for test allocation|using device'
$new -split "`n" | Select-String -Pattern $patterns | ForEach-Object { "  " + $_.Line.Trim() }
""
