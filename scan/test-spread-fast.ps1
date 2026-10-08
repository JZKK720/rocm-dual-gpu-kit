# =============================================================================
# FAST spread-mechanism test (uses a small model so it loads in seconds).
# Verifies whether OLLAMA_SCHED_SPREAD actually changes device placement in
# Ollama 0.34.1 -- the kit docs (written for 0.30.11) claim multi-GPU-per-model
# is impossible.
#
# Usage: .\test-spread-fast.ps1 -Spread 1 -Model nemotron-3.5-lightning:30b-a3b
#        .\test-spread-fast.ps1 -Restore
# =============================================================================
param(
    [string]$Model = 'nemotron-3.5-lightning:30b-a3b',
    [int]$Spread = 1,
    [int]$Ctx = 4096,
    [switch]$Restore
)

$ErrorActionPreference = 'Continue'
$LOG = "$env:LOCALAPPDATA\Ollama\server.log"
$TRAY = "$env:LOCALAPPDATA\Programs\Ollama\ollama app.exe"

function Restart-Tray {
    Get-Process -Name "ollama app" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    Get-Process -Name "ollama" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    Start-Process -FilePath $TRAY -WindowStyle Hidden
    Start-Sleep -Seconds 6
}

if ($Restore) {
    "=== RESTORE ==="
    [Environment]::SetEnvironmentVariable('OLLAMA_SCHED_SPREAD', $null, 'User')
    [Environment]::SetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', $null, 'User')
    Restart-Tray
    "  removed test env vars; tray restarted."
    exit 0
}

"=== spread test: OLLAMA_SCHED_SPREAD=$Spread  model=$Model  ctx=$Ctx ==="
[Environment]::SetEnvironmentVariable('OLLAMA_SCHED_SPREAD', "$Spread", 'User')
[Environment]::SetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', "$Ctx", 'User')

$before = if (Test-Path $LOG) { (Get-Item $LOG).Length } else { 0 }
"  log baseline = $before bytes"

Restart-Tray
"  tray restarted; unloading any resident models..."
try { Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post `
    -Body '{"model":"nomic-embed-text:latest","keep_alive":0}' -ContentType 'application/json' `
    -TimeoutSec 30 | Out-Null } catch { }

"  loading $Model ..."
$body = @{
    model   = $Model
    prompt  = 'hi'
    stream  = $false
    options = @{ num_ctx = $Ctx; num_predict = 1 }
} | ConvertTo-Json -Depth 5

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post `
        -Body $body -ContentType 'application/json' -TimeoutSec 900 | Out-Null
    "  completed in $([math]::Round($sw.Elapsed.TotalSeconds,1))s"
} catch { "  failed after $([math]::Round($sw.Elapsed.TotalSeconds,1))s : $_" }

""
"=============== DEVICE PLACEMENT (new log lines) ==============="
$fs = [System.IO.File]::Open($LOG, 'Open', 'Read', 'ReadWrite')
$fs.Seek($before, 'Begin') | Out-Null
$sr = New-Object System.IO.StreamReader($fs)
$new = $sr.ReadToEnd(); $sr.Close(); $fs.Close()

$new -split "`n" | Select-String -Pattern `
    'llama_prepare_model_devices|offloaded [0-9]+/[0-9]+ layers|model buffer size|KV buffer size|n_ctx +=|fit_params|memory for test allocation|using device|inference compute' |
    ForEach-Object { "  " + $_.Line.Trim() }

""
"=============== SPREAD DECISION ==============="
$used = @()
if ($new -match 'ROCm0') { $used += 'ROCm0 (iGPU)' }
if ($new -match 'ROCm1') { $used += 'ROCm1 (dGPU)' }
if ($used.Count -gt 1) { "  RESULT: model placed on BOTH GPUs -> spread WORKS" }
elseif ($used.Count -eq 1) { "  RESULT: single GPU only -> $($used[0])" }
else { "  RESULT: no ROCm device used" }
""
