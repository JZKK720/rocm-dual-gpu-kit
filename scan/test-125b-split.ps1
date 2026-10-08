# =============================================================================
# DECISIVE TEST: does OLLAMA_SCHED_SPREAD=1 split the 111 GB MoE model across
# BOTH the iGPU (ROCm0) and the dGPU (ROCm1)?
#
# Uses a tiny context (4096) and num_predict=1 to minimise runtime while still
# forcing a real fit decision for the full 111 GB weight set.
#
# Usage: .\test-125b-split.ps1 -Spread 1
#        .\test-125b-split.ps1 -Spread 0
#        .\test-125b-split.ps1 -Restore
# =============================================================================
param(
    [int]$Spread = 1,
    [int]$Ctx = 4096,
    [switch]$Restore
)

$ErrorActionPreference = 'Continue'
$TRAY = "$env:LOCALAPPDATA\Programs\Ollama\ollama app.exe"
$MODEL = 'qwen3.8-flash-next:125b-a6b-q4_K_M'

function Latest-Log {
    Get-ChildItem "$env:LOCALAPPDATA\Ollama" -Filter 'server*.log' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Restart-Tray {
    Get-Process -Name "ollama app" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    Get-Process -Name "ollama" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3
    Start-Process -FilePath $TRAY -WindowStyle Hidden
    Start-Sleep -Seconds 8
}

if ($Restore) {
    "=== RESTORE: clearing test env vars ==="
    [Environment]::SetEnvironmentVariable('OLLAMA_SCHED_SPREAD', $null, 'User')
    [Environment]::SetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', $null, 'User')
    Restart-Tray
    "  done."
    exit 0
}

"=== 125B split test: OLLAMA_SCHED_SPREAD=$Spread  ctx=$Ctx ==="
[Environment]::SetEnvironmentVariable('OLLAMA_SCHED_SPREAD', "$Spread", 'User')
[Environment]::SetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', "$Ctx", 'User')

Restart-Tray
$log = (Latest-Log).FullName
"  watching: $log"

# flush any resident models
try {
    '{"model":"nemotron-3.5-lightning:30b-a3b","keep_alive":0}' |
        Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post `
        -ContentType 'application/json' -TimeoutSec 30 | Out-Null
} catch { }
Start-Sleep -Seconds 3

$before = (Get-Item $log).Length

"  loading $MODEL (ctx=$Ctx) -- this is the slow part, please wait..."
$body = @{
    model   = $MODEL
    prompt  = 'hi'
    stream  = $false
    options = @{ num_ctx = $Ctx; num_predict = 1 }
} | ConvertTo-Json -Depth 5

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $r = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post `
        -Body $body -ContentType 'application/json' -TimeoutSec 3600
    "  completed in $([math]::Round($sw.Elapsed.TotalSeconds,1))s"
} catch {
    "  request ended after $([math]::Round($sw.Elapsed.TotalSeconds,1))s : $_"
}

""
"=============== DEVICE PLACEMENT ==============="
$log = (Latest-Log).FullName
$fs = [System.IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
$fs.Seek([Math]::Min($before, $fs.Length), 'Begin') | Out-Null
$sr = New-Object System.IO.StreamReader($fs)
$new = $sr.ReadToEnd(); $sr.Close(); $fs.Close()

$new -split "`n" | Select-String -Pattern `
    'llama_prepare_model_devices|offloaded [0-9]+/[0-9]+ layers|model buffer size|KV buffer size|n_ctx +=|fit_params|memory for test allocation|common_param:   -' |
    ForEach-Object { "  " + $_.Line.Trim() }

""
"=============== VERDICT ==============="
$ig = ($new -split "`n" | Select-String 'ROCm0' ).Count
$dg = ($new -split "`n" | Select-String 'ROCm1' ).Count
"  ROCm0 (iGPU) mentions: $ig"
"  ROCm1 (dGPU) mentions: $dg"
if ($ig -gt 0 -and $dg -gt 0) { "  >>> BOTH GPUs engaged" } else { "  >>> SINGLE GPU only" }
""
