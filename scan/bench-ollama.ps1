# =============================================================================
# bench-ollama.ps1 — Strata-style benchmark harness for the local Ollama server.
#
# Implements the eval methodology from scan/STRATA-RESEARCH.md §3:
#   1. Cold prefill probe  : unload (keep_alive=0), then ONE non-stream call
#                            with num_predict=1; report prompt_eval tok/s.
#   2. Three SSE runs      : stream=true, temperature=0, num_predict=192;
#                            report TTFT, avg/peak wall TPS, engine TPS.
#   3. Interleaved A/B     : arms alternate A,B,A,B,A,B (never sequential
#                            blocks); medians reported per arm.
#   4. First fresh prompt after load is DISCARDED (cold-load, not a measure).
#   5. Fresh prompts share zero tokens across runs (seeded word-shuffle).
#
# Modes:
#   .\bench-ollama.ps1 -Model qwen3.8-flash-next:125b-a6b-q4_K_M -Ctx 8192
#       -> single-arm baseline matrix (cold probe + 3 SSE runs)
#   .\bench-ollama.ps1 -AB KV -Model qwen3.8:27b-mtp-q4_K_M
#       -> interleaved KV-cache A/B (f16 vs q8_0 vs q4_0), server restarts
#          between arms (OLLAMA_KV_CACHE_TYPE is a server env var)
#   .\bench-ollama.ps1 -AB Ctx -CtxList 4096,8192,16384
#       -> interleaved context ladder (num_ctx is per-request; reloads happen
#          when ctx exceeds the loaded context)
#
# Results land in scan\results\bench-<timestamp>\ as JSON + matrix.md.
# =============================================================================

param(
    [string]$Model = 'qwen3.8-flash-next:125b-a6b-q4_K_M',
    [int]$Ctx = 8192,
    [int]$Predict = 192,
    [ValidateSet('none', 'KV', 'Ctx')]
    [string]$AB = 'none',
    [string[]]$CtxList = @('4096', '8192', '16384'),
    [string[]]$KVArms = @('f16', 'q8_0', 'q4_0'),
    [int]$Pairs = 3,
    [int]$ProbeTokens = 0,   # 0 = auto: min(1536, ctx-256); keep small when
                             # prefill is slow (the 125B measures ~14 tok/s)
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Continue'
$API = 'http://127.0.0.1:11434'
$TRAY = "$env:LOCALAPPDATA\Programs\Ollama\ollama app.exe"
$LOG = "$env:LOCALAPPDATA\Ollama\server.log"

if (-not $OutDir) {
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutDir = Join-Path $PSScriptRoot "results\bench-$ts"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ---------------------------------------------------------------------------
# Fresh-prompt generator: seeded shuffle of a word pool -> distinct text.
# ~4 chars/token for English; -Tokens approximates the prompt token count.
# ---------------------------------------------------------------------------
$script:WordPool = @(
    'harbor','lantern','quartz','meadow','cipher','tundra','beacon','willow',
    'cobalt','ember','fjord','granite','helix','ivory','jasper','kelp',
    'lagoon','marble','nectar','onyx','prism','quiver','ripple','saffron',
    'timber','umber','velvet','walnut','xenon','yarrow','zephyr','anchor',
    'basalt','cinder','dune','echo','fable','glacier','hollow','ingot',
    'jungle','kernel','lattice','mosaic','nimbus','orbit','pinnacle','quarry',
    'ridge','summit','thicket','umbra','vessel','wharf','yeast','zinc',
    'alloy','bramble','canyon','delta','estuary','flint','grove','heather'
)

function New-FreshPrompt {
    param([int]$Seed, [int]$Tokens)
    $rng = [System.Random]::new($Seed)
    $words = New-Object System.Collections.Generic.List[string]
    $need = [Math]::Max(64, $Tokens * 4 / 6)   # ~6 chars/word incl. space
    while ($words.Count -lt $need) {
        $i = $rng.Next($script:WordPool.Count)
        $words.Add($script:WordPool[$i])
    }
    $text = ($words -join ' ')
    return "Summarize the following passage in one sentence. PASSAGE: $text"
}

# ---------------------------------------------------------------------------
# Server control
# ---------------------------------------------------------------------------
function Restart-Ollama {
    param([hashtable]$EnvVars = @{})
    Get-Process -Name 'ollama app' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    Get-Process -Name 'ollama' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    # Registry write AND current-session write: a child process only sees the
    # session value (measured gotcha, repo memory).
    foreach ($k in $EnvVars.Keys) {
        [Environment]::SetEnvironmentVariable($k, $EnvVars[$k], 'User')
        Set-Item -Path "Env:$k" -Value $EnvVars[$k]
    }
    Start-Process -FilePath $TRAY -WindowStyle Hidden
    Start-Sleep -Seconds 6
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-RestMethod -Uri "$API/api/version" -TimeoutSec 2 | Out-Null
            return $true
        } catch { Start-Sleep -Seconds 2 }
    }
    return $false
}

function Unload-Model {
    param([string]$M)
    try {
        Invoke-RestMethod -Uri "$API/api/generate" -Method Post `
            -Body (@{ model = $M; keep_alive = 0 } | ConvertTo-Json) `
            -ContentType 'application/json' -TimeoutSec 120 | Out-Null
    } catch { }
    Start-Sleep -Seconds 3
}

# ---------------------------------------------------------------------------
# Run 1: cold prefill probe (unload -> one 1-token non-stream call)
# ---------------------------------------------------------------------------
function Invoke-ColdPrefillProbe {
    param([string]$M, [int]$C, [int]$Seed, [int]$ProbeTks = 0)
    Unload-Model -M $M
    $pt = if ($ProbeTks -gt 0) { $ProbeTks } else { [Math]::Min(1536, [Math]::Max(512, $C - 256)) }
    $prompt = New-FreshPrompt -Seed $Seed -Tokens $pt
    $body = @{
        model   = $M
        prompt  = $prompt
        stream  = $false
        options = @{ num_ctx = $C; num_predict = 1; temperature = 0 }
    } | ConvertTo-Json -Depth 5
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod -Uri "$API/api/generate" -Method Post `
            -Body $body -ContentType 'application/json' -TimeoutSec 7200
        $sw.Stop()
        $pe = $r.prompt_eval_count
        $ped = $r.prompt_eval_duration
        $tps = if ($ped) { [Math]::Round($pe / ($ped / 1e9), 1) } else { 0 }
        return @{
            kind = 'cold_prefill'; prompt_tokens = $pe; tps = $tps
            wall_s = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
            load_s = [Math]::Round($r.load_duration / 1e9, 2)
        }
    } catch {
        return @{ kind = 'cold_prefill'; error = "$_" }
    }
}

# ---------------------------------------------------------------------------
# Run 2: one SSE streaming run (t=0, num_predict=192)
# ---------------------------------------------------------------------------
function Invoke-SseRun {
    param([string]$M, [int]$C, [int]$Seed, [int]$RunIdx)
    $prompt = New-FreshPrompt -Seed ($Seed + 1000 + $RunIdx) -Tokens ([Math]::Min($C - 256, 4096))
    $body = @{
        model   = $M
        prompt  = $prompt
        stream  = $true
        options = @{ num_ctx = $C; num_predict = $Predict; temperature = 0 }
    } | ConvertTo-Json -Depth 5
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $req = [System.Net.HttpWebRequest]::Create("$API/api/generate")
    $req.Method = 'POST'
    $req.ContentType = 'application/json'
    $req.Timeout = 7200000
    $req.ReadWriteTimeout = 7200000
    try {
        $rs = $req.GetRequestStream()
        $rs.Write($bytes, 0, $bytes.Length)
        $rs.Close()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $ttftMs = -1; $nGen = 0; $firstChunkAt = $sw.Elapsed.TotalMilliseconds
        $lastChunkAt = $firstChunkAt; $engineTps = 0; $evalCount = 0; $evalDur = 0
        $peCount = 0; $peDur = 0
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if (-not $line) { continue }
            $j = $null
            try { $j = $line | ConvertFrom-Json } catch { continue }
            # Count every streamed token chunk. Thinking models (Ollama 0.9+)
            # stream `thinking` chunks before the final `response` chunks;
            # counting only `response` would report ~2% of real throughput.
            if ($j.response -or $j.thinking) {
                if ($ttftMs -lt 0) { $ttftMs = [Math]::Round($sw.Elapsed.TotalMilliseconds) }
                $nGen++
                $lastChunkAt = $sw.Elapsed.TotalMilliseconds
            }
            if ($j.eval_count) { $evalCount = $j.eval_count; $evalDur = $j.eval_duration }
            if ($j.prompt_eval_count) { $peCount = $j.prompt_eval_count; $peDur = $j.prompt_eval_duration }
            if ($j.done) { break }
        }
        $reader.Close(); $resp.Close()
        $genWallS = ($lastChunkAt - $firstChunkAt) / 1000.0
        $wallTps = if ($genWallS -gt 0) { [Math]::Round($nGen / $genWallS, 2) } else { 0 }
        $engineTps = if ($evalDur) { [Math]::Round($evalCount / ($evalDur / 1e9), 2) } else { 0 }
        $prefillTps = if ($peDur) { [Math]::Round($peCount / ($peDur / 1e9), 1) } else { 0 }
        return @{
            kind = 'sse'; run = $RunIdx; prompt_tokens = $peCount
            ttft_ms = $ttftMs; gen_tokens = $nGen
            wall_tps = $wallTps; engine_tps = $engineTps
            sse_prefill_tps = $prefillTps
        }
    } catch {
        return @{ kind = 'sse'; run = $RunIdx; error = "$_" }
    }
}

# ---------------------------------------------------------------------------
# One arm = cold probe + 3 SSE runs (first SSE run discarded as cold-load)
# ---------------------------------------------------------------------------
function Invoke-Arm {
    param([string]$M, [int]$C, [int]$Seed, [string]$Label, [int]$ProbeTks = 0)
    "  [$Label] cold prefill probe..."
    $probe = Invoke-ColdPrefillProbe -M $M -C $C -Seed $Seed -ProbeTks $ProbeTks
    "  [$Label] probe: $(if ($probe.error) { $probe.error } else { "$($probe.prompt_tokens) tok @ $($probe.tps) tok/s (load $($probe.load_s)s)" })"
    $runs = @()
    for ($i = 1; $i -le ($Pairs + 1); $i++) {
        $r = Invoke-SseRun -M $M -C $C -Seed $Seed -RunIdx $i
        if ($r.error) {
            "  [$Label] SSE run $i FAILED: $($r.error)"
        } else {
            "  [$Label] SSE run $i : ttft=$($r.ttft_ms)ms  wall=$($r.wall_tps) t/s  engine=$($r.engine_tps) t/s  prefill=$($r.sse_prefill_tps) t/s"
        }
        $runs += $r
    }
    # discard run 1 (cold load); medians over the rest
    $kept = $runs | Where-Object { -not $_.error } | Select-Object -Skip 1
    $median = {
        param($arr, $prop)
        $s = $arr | ForEach-Object { $_.$prop } | Sort-Object
        if ($s.Count -eq 0) { return 0 }
        $m = [Math]::Floor(($s.Count - 1) / 2)
        return [Math]::Round(($s[$m] + $s[([Math]::Min($m + 1, $s.Count - 1))]) / 2, 2)
    }
    $summary = if ($kept.Count -gt 0) {
        @{
            label = $Label; model = $M; ctx = $C
            cold_prefill_tps = $probe.tps
            ttft_ms = & $median $kept 'ttft_ms'
            wall_tps = & $median $kept 'wall_tps'
            engine_tps = & $median $kept 'engine_tps'
            sse_prefill_tps = & $median $kept 'sse_prefill_tps'
            runs_kept = $kept.Count
        }
    } else { @{ label = $Label; model = $M; ctx = $C; error = 'all SSE runs failed' } }
    return @{ probe = $probe; runs = $runs; summary = $summary }
}

# ---------------------------------------------------------------------------
# Matrix writer (Strata matrix.md shape)
# ---------------------------------------------------------------------------
function Write-Matrix {
    param([object[]]$Summaries, [string]$Path, [string]$Header)
    $lines = @("# Ollama benchmark — $Header", "", "Harness: bench-ollama.ps1 (Strata-style: cold prefill probe, 3x SSE t=0 num_predict=$Predict, interleaved arms, first run discarded).", "")
    $lines += '| Arm | Model | Ctx | Cold Prefill t/s | TTFT ms (med) | Wall TPS (med) | Engine TPS (med) | SSE Prefill t/s | Runs |'
    $lines += '|---|---|---:|---:|---:|---:|---:|---:|---:|'
    foreach ($s in $Summaries) {
        if ($s.error) { $lines += "| $($s.label) | $($s.model) | $($s.ctx) | ERROR | - | - | - | - | 0 |" }
        else {
            $lines += "| $($s.label) | $($s.model) | $($s.ctx) | $($s.cold_prefill_tps) | $($s.ttft_ms) | $($s.wall_tps) | $($s.engine_tps) | $($s.sse_prefill_tps) | $($s.runs_kept) |"
        }
    }
    $lines += ''
    $lines | Set-Content -Path $Path -Encoding utf8
    "matrix written: $Path"
}

# ===========================================================================
# MAIN
# ===========================================================================
"=== bench-ollama ==="
"  model=$Model  ctx=$Ctx  predict=$Predict  AB=$AB  out=$OutDir"
""

$allSummaries = @()

switch ($AB) {

    'none' {
        $arm = Invoke-Arm -M $Model -C $Ctx -Seed 42 -Label "baseline-ctx$Ctx" -ProbeTks $ProbeTokens
        $allSummaries += $arm.summary
        $arm | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutDir 'arm.json') -Encoding utf8
    }

    'KV' {
        # KV cache type is a SERVER env var -> restart between arms.
        # Interleave: A1,B1,C1,A2,B2,C2,... (never sequential blocks).
        $seq = @()
        for ($p = 1; $p -le $Pairs; $p++) {
            foreach ($kv in $KVArms) { $seq += @{ kv = $kv; pair = $p } }
        }
        $seedBase = 100
        foreach ($step in $seq) {
            $label = "kv-$($step.kv)"
            "=== arm $label (pair $($step.pair)) — restarting Ollama with OLLAMA_KV_CACHE_TYPE=$($step.kv) ==="
            $ok = Restart-Ollama -EnvVars @{
                'OLLAMA_KV_CACHE_TYPE'  = $step.kv
                'OLLAMA_FLASH_ATTENTION' = '1'
            }
            if (-not $ok) { "  RESTART FAILED — skipping"; continue }
            $seed = $seedBase + $step.pair * 10 + [array]::IndexOf($KVArms, $step.kv)
            $arm = Invoke-Arm -M $Model -C $Ctx -Seed $seed -Label "$label-p$($step.pair)"
            $allSummaries += $arm.summary
            $arm | ConvertTo-Json -Depth 6 |
                Set-Content (Join-Path $OutDir "arm-$label-p$($step.pair).json") -Encoding utf8
        }
        # restore: remove the test env vars
        "=== restoring default KV env ==="
        [Environment]::SetEnvironmentVariable('OLLAMA_KV_CACHE_TYPE', $null, 'User')
        Remove-Item Env:OLLAMA_KV_CACHE_TYPE -ErrorAction SilentlyContinue
        Restart-Ollama | Out-Null
    }

    'Ctx' {
        # num_ctx is per-request; interleave by alternating ctx across pairs.
        $seq = @()
        for ($p = 1; $p -le $Pairs; $p++) {
            foreach ($c in $CtxList) { $seq += @{ ctx = [int]$c; pair = $p } }
        }
        $seedBase = 200
        foreach ($step in $seq) {
            $label = "ctx-$($step.ctx)"
            $seed = $seedBase + $step.pair * 10 + [array]::IndexOf($CtxList, "$($step.ctx)")
            $arm = Invoke-Arm -M $Model -C $step.ctx -Seed $seed -Label "$label-p$($step.pair)"
            $allSummaries += $arm.summary
            $arm | ConvertTo-Json -Depth 6 |
                Set-Content (Join-Path $OutDir "arm-$label-p$($step.pair).json") -Encoding utf8
        }
    }
}

Write-Matrix -Summaries $allSummaries -Path (Join-Path $OutDir 'matrix.md') `
    -Header "$Model (AB=$AB)"
$allSummaries | ConvertTo-Json -Depth 5 |
    Set-Content (Join-Path $OutDir 'summaries.json') -Encoding utf8
"=== done — results in $OutDir ==="
