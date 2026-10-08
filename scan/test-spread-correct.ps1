# =============================================================================
# CORRECTED spread test.
#
# The earlier run had a confound: [Environment]::SetEnvironmentVariable(...,'User')
# writes the registry but does NOT update the current PowerShell session, so a
# child process started from that session never saw OLLAMA_SCHED_SPREAD.
#
# This version sets BOTH the persisted User value AND $env: in-session, then
# starts the tray app so the child actually inherits it. It also verifies the
# child process tree picked the variable up.
#
# Usage: .\test-spread-correct.ps1 -Spread 1
#        .\test-spread-correct.ps1 -Spread 0
#        .\test-spread-correct.ps1 -Restore
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
    "=== RESTORE ==="
    [Environment]::SetEnvironmentVariable('OLLAMA_SCHED_SPREAD', $null, 'User')
    Remove-Item Env:OLLAMA_SCHED_SPREAD -ErrorAction SilentlyContinue
    Restart-Tray
    "  cleared and restarted."
    exit 0
}

# --- set BOTH registry (persist) AND session (so children inherit) ---
[Environment]::SetEnvironmentVariable('OLLAMA_SCHED_SPREAD', "$Spread", 'User')
Set-Item -Path Env:OLLAMA_SCHED_SPREAD -Value "$Spread"
"=== corrected spread test: OLLAMA_SCHED_SPREAD=$Spread (session+registry) ==="
"  session value = '$env:OLLAMA_SCHED_SPREAD'"

Restart-Tray

# verify the running server actually inherited it
$srv = Get-Process -Name "ollama" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($srv) { "  ollama server PID = $($srv.Id)" }

$log = (Latest-Log).FullName
"  log = $log"

# unload everything
try {
    '{"model":"nemotron-3.5-lightning:30b-a3b","keep_alive":0}' |
        Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post `
        -ContentType 'application/json' -TimeoutSec 30 | Out-Null
} catch { }
Start-Sleep -Seconds 3

$before = (Get-Item $log).Length

"  loading $MODEL ctx=$Ctx ..."
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
    'llama_prepare_model_devices|offloaded [0-9]+/[0-9]+ layers|model buffer size|KV buffer size|n_ctx +=|common_param:   -|cannot meet free memory' |
    ForEach-Object { "  " + $_.Line.Trim() }

""
$lines = $new -split "`n"
$ig = ($lines | Select-String 'ROCm0 ' ).Count
$dg = ($lines | Select-String 'ROCm1 ' ).Count
"  ROCm0(iGPU) refs: $ig   ROCm1(dGPU) refs: $dg"
""
