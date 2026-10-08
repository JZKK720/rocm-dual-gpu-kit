# =============================================================================
# DECISIVE TEST: force the model onto the iGPU ONLY (HIP_VISIBLE_DEVICES=0)
# to determine how much of the 111 GB the iGPU can actually hold, and whether
# it beats the dGPU placement Ollama chose on its own.
#
# Usage: .\test-igpu-only.ps1          # force iGPU
#        .\test-igpu-only.ps1 -Restore # restore 0,1
# =============================================================================
param(
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
    "=== RESTORE HIP_VISIBLE_DEVICES=0,1 ==="
    [Environment]::SetEnvironmentVariable('HIP_VISIBLE_DEVICES', '0,1', 'User')
    Set-Item -Path Env:HIP_VISIBLE_DEVICES -Value '0,1'
    Restart-Tray
    "  restored."
    exit 0
}

[Environment]::SetEnvironmentVariable('HIP_VISIBLE_DEVICES', '0', 'User')
Set-Item -Path Env:HIP_VISIBLE_DEVICES -Value '0'
"=== forcing iGPU ONLY (HIP_VISIBLE_DEVICES=0) ==="

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
"  loading $MODEL ctx=$Ctx on iGPU only ..."

$body = @{
    model   = $MODEL
    prompt  = 'hi'
    stream  = $false
    options = @{ num_ctx = $Ctx; num_predict = 1 }
} | ConvertTo-Json -Depth 5

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post `
        -Body $body -ContentType 'application/json' -TimeoutSec 3600 | Out-Null
    "  completed in $([math]::Round($sw.Elapsed.TotalSeconds,1))s"
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
