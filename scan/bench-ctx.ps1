# =============================================================================
# Measured ctx sweep: does reducing context actually accelerate output?
# Reports prompt-eval and generation tok/s from Ollama's own timing fields.
#
# Usage: .\bench-ctx.ps1 -Ctx 8192
#        .\bench-ctx.ps1 -Ctx 262144
# =============================================================================
param(
    [int]$Ctx = 8192,
    [int]$Predict = 64,
    [string]$Model = 'qwen3.8-flash-next:125b-a6b-q4_K_M'
)

$ErrorActionPreference = 'Continue'

$prompt = 'Explain in one paragraph why memory bandwidth limits large language model inference.'

$body = @{
    model   = $Model
    prompt  = $prompt
    stream  = $false
    options = @{ num_ctx = $Ctx; num_predict = $Predict; temperature = 0 }
} | ConvertTo-Json -Depth 5

"=== ctx=$Ctx  predict=$Predict  model=$Model ==="
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $r = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post `
        -Body $body -ContentType 'application/json' -TimeoutSec 3600
    $total = $sw.Elapsed.TotalSeconds

    $pe = $r.prompt_eval_count
    $ped = $r.prompt_eval_duration
    $ec = $r.eval_count
    $ed = $r.eval_duration

    "  total wall time      : {0,10:N1} s" -f $total
    "  load duration        : {0,10:N1} s" -f ($r.load_duration / 1e9)
    if ($ped) {
        "  prompt eval          : {0,6} tokens in {1,8:N1} s  -> {2,7:N2} tok/s" -f `
            $pe, ($ped / 1e9), ($pe / ($ped / 1e9))
    }
    if ($ed) {
        "  generation           : {0,6} tokens in {1,8:N1} s  -> {2,7:N2} tok/s" -f `
            $ec, ($ed / 1e9), ($ec / ($ed / 1e9))
    }
    ""
    "  --- text ---"
    ($r.response -split "`n" | Select-Object -First 12) | ForEach-Object { "  $_" }
} catch {
    "  FAILED: $_"
}
""
