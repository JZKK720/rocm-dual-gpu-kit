# =============================================================================
# bench-strata.ps1 — Strata-style benchmark harness for the Strata server.
#
# Same eval methodology as bench-ollama.ps1 (scan/STRATA-RESEARCH.md §3):
#   1. Cold prefill probe  : ONE non-stream call with max_tokens=1 on a fresh
#                            prompt; report prefill tok/s (server reports it
#                            in the log; we measure wall time + token count).
#   2. Three SSE runs      : stream=true, temperature=0, max_tokens=192;
#                            report TTFT, wall TPS, engine TPS (from usage).
#   3. Interleaved A/B     : arms alternate A,B,A,B,A,B (never sequential
#                            blocks); medians reported per arm.
#   4. First fresh prompt after load is DISCARDED (cold-load, not a measure).
#   5. Fresh prompts share zero tokens across runs (seeded word-shuffle).
#
# Differences vs Ollama:
#   - Endpoint: OpenAI-compatible /v1/chat/completions on port 8080.
#   - No server restarts needed for KV A/B: Strata's KV type is fixed at
#     setup time (8-bit here), so the A/B dimension is CONTEXT instead.
#   - Strata answers one request at a time; no parallelism in the harness.
#   - reasoning_effort=none for speed-only measurement.
#
# Modes:
#   .\bench-strata.ps1
#       -> single-arm baseline matrix (cold probe + 3 SSE runs @ 8K ctx)
#   .\bench-strata.ps1 -AB Ctx -CtxList 4096,8192,16384
#       -> interleaved context ladder
#
# Results land in scan\results\bench-strata-<timestamp>\ as JSON + matrix.md.
# =============================================================================

param(
    [string]$Base = 'http://127.0.0.1:8080',
    [string]$ModelName = 'strata',          # Strata ignores the model name
    [int]$Ctx = 8192,
    [int]$Predict = 192,
    [ValidateSet('none', 'Ctx')]
    [string]$AB = 'none',
    [string[]]$CtxList = @('4096', '8192', '16384'),
    [int]$Pairs = 3,
    [int]$ProbeTokens = 0,   # 0 = auto: min(1536, ctx-256)
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Continue'

if (-not $OutDir) {
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutDir = Join-Path $PSScriptRoot "results\bench-strata-$ts"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ---------------------------------------------------------------------------
# Fresh-prompt generator: identical to bench-ollama.ps1 (same word pool, same
# seeding) so prompts are comparable across the two harnesses.
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
# Health check: is the model loaded?
# ---------------------------------------------------------------------------
function Test-StrataLoaded {
    try {
        $h = Invoke-RestMethod "$Base/health" -TimeoutSec 5
        return [bool]$h.loaded
    } catch { return $false }
}

# ---------------------------------------------------------------------------
# Run 1: cold prefill probe (one 1-token non-stream call on a fresh prompt).
# Strata has no unload API; the probe measures prefill on a prompt the server
# has never seen (fresh seed), so no KV reuse applies.
# ---------------------------------------------------------------------------
function Invoke-ColdPrefillProbe {
    param([int]$C, [int]$Seed, [int]$ProbeTks = 0)
    $pt = if ($ProbeTks -gt 0) { $ProbeTks } else { [Math]::Min(1536, [Math]::Max(512, $C - 256)) }
    $prompt = New-FreshPrompt -Seed $Seed -Tokens $pt
    $body = @{
        model            = $ModelName
        messages         = @(@{ role = 'user'; content = $prompt })
        max_tokens       = 1
        temperature      = 0
        reasoning_effort = 'none'
        stream           = $false
    } | ConvertTo-Json -Depth 5
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod -Uri "$Base/v1/chat/completions" -Method Post `
            -Body $body -ContentType 'application/json' -TimeoutSec 7200
        $sw.Stop()
        $pe = $r.usage.prompt_tokens
        $wall = $sw.Elapsed.TotalSeconds
        # Strata's log reports exact prefill tok/s; wall-based estimate is the
        # harness-side number (includes HTTP + 1 decode token).
        $tps = if ($wall -gt 0) { [Math]::Round($pe / $wall, 1) } else { 0 }
        return @{
            kind = 'cold_prefill'; prompt_tokens = $pe; tps = $tps
            wall_s = [Math]::Round($wall, 2)
        }
    } catch {
        return @{ kind = 'cold_prefill'; error = "$_" }
    }
}

# ---------------------------------------------------------------------------
# Run 2: one SSE streaming run (t=0, max_tokens=192).
# OpenAI SSE: lines "data: {...}", terminated by "data: [DONE]".
# ---------------------------------------------------------------------------
function Invoke-SseRun {
    param([int]$C, [int]$Seed, [int]$RunIdx)
    $prompt = New-FreshPrompt -Seed ($Seed + 1000 + $RunIdx) -Tokens ([Math]::Min($C - 256, 4096))
    $body = @{
        model            = $ModelName
        messages         = @(@{ role = 'user'; content = $prompt })
        max_tokens       = $Predict
        temperature      = 0
        reasoning_effort = 'none'
        stream           = $true
    } | ConvertTo-Json -Depth 5
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $req = [System.Net.HttpWebRequest]::Create("$Base/v1/chat/completions")
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
        $lastChunkAt = $firstChunkAt
        $peCount = 0; $compCount = 0
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if (-not $line) { continue }
            if (-not $line.StartsWith('data: ')) { continue }
            $payload = $line.Substring(6)
            if ($payload -eq '[DONE]') { break }
            $j = $null
            try { $j = $payload | ConvertFrom-Json } catch { continue }
            $delta = $j.choices[0].delta
            if ($delta -and ($delta.content -or $delta.reasoning_content)) {
                if ($ttftMs -lt 0) { $ttftMs = [Math]::Round($sw.Elapsed.TotalMilliseconds) }
                $nGen++
                $lastChunkAt = $sw.Elapsed.TotalMilliseconds
            }
            if ($j.usage) {
                $peCount = $j.usage.prompt_tokens
                $compCount = $j.usage.completion_tokens
            }
        }
        $reader.Close(); $resp.Close()
        $genWallS = ($lastChunkAt - $firstChunkAt) / 1000.0
        $wallTps = if ($genWallS -gt 0) { [Math]::Round($nGen / $genWallS, 2) } else { 0 }
        $prefillTps = 0
        if ($peCount -and $ttftMs -gt 0) {
            $prefillTps = [Math]::Round($peCount / ($ttftMs / 1000.0), 1)
        }
        return @{
            kind = 'sse'; run = $RunIdx; prompt_tokens = $peCount
            ttft_ms = $ttftMs; gen_tokens = $nGen
            wall_tps = $wallTps; completion_tokens = $compCount
            sse_prefill_tps = $prefillTps
        }
    } catch {
        return @{ kind = 'sse'; run = $RunIdx; error = "$_" }
    }
}

# ---------------------------------------------------------------------------
# Engine-reported rates: the SSE client on Windows localhost sees chunks
# trickle ~320 ms apart (delayed-ACK/Nagle artifact) — wall TPS from chunk
# timing reads ~3 t/s while the engine actually decodes at 80+ tok/s. The
# engine log line is ground truth:
#   "prompt N tokens = ... read in X ms (P tok/s), M generated in Y ms (D tok/s), drafts accepted ..."
# ---------------------------------------------------------------------------
function Get-EngineRates {
    $log = 'C:\Strata\repo\strata-iq2_xs.log'
    if (-not (Test-Path $log)) { return $null }
    $line = (Get-Content $log -Tail 30 | Select-String -Pattern 'prompt \d+ tokens = .* generated in') | Select-Object -Last 1
    if (-not $line) { return $null }
    $l = $line.Line
    $pf = if ($l -match '\(([\d.]+) tok/s\), (\d+) generated in (\d+) ms \(([\d.]+) tok/s\)') {
        @{ prefill_tps = [double]$Matches[1]; gen = [int]$Matches[2]; gen_ms = [int]$Matches[3]; decode_tps = [double]$Matches[4] }
    } else { $null }
    $drafts = if ($l -match 'drafts accepted (\d+) of (\d+)') { @{ accepted = [int]$Matches[1]; of = [int]$Matches[2] } } else { $null }
    if ($pf) { $pf.drafts = $drafts }
    return $pf
}

# ---------------------------------------------------------------------------
# One arm = cold probe + 3 SSE runs (first SSE run discarded as cold-load)
# ---------------------------------------------------------------------------
function Invoke-Arm {
    param([int]$C, [int]$Seed, [string]$Label, [int]$ProbeTks = 0)
    "  [$Label] cold prefill probe..."
    $probe = Invoke-ColdPrefillProbe -C $C -Seed $Seed -ProbeTks $ProbeTks
    "  [$Label] probe: $(if ($probe.error) { $probe.error } else { "$($probe.prompt_tokens) tok @ $($probe.tps) tok/s (wall $($probe.wall_s)s)" })"
    $runs = @()
    for ($i = 1; $i -le ($Pairs + 1); $i++) {
        $r = Invoke-SseRun -C $C -Seed $Seed -RunIdx $i
        if ($r.error) {
            "  [$Label] SSE run $i FAILED: $($r.error)"
        } else {
            $eng = Get-EngineRates
            if ($eng) {
                $r.engine_decode_tps = $eng.decode_tps
                $r.engine_prefill_tps = $eng.prefill_tps
                $r.drafts = if ($eng.drafts) { "$($eng.drafts.accepted)/$($eng.drafts.of)" } else { '' }
                "  [$Label] SSE run $i : ttft=$($r.ttft_ms)ms  wall=$($r.wall_tps) t/s (client)  ENGINE decode=$($r.engine_decode_tps) t/s prefill=$($r.engine_prefill_tps) t/s drafts=$($r.drafts)"
            } else {
                "  [$Label] SSE run $i : ttft=$($r.ttft_ms)ms  wall=$($r.wall_tps) t/s  prefill=$($r.sse_prefill_tps) t/s  gen=$($r.gen_tokens)"
            }
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
            label = $Label; model = 'qwen3.8-flash-next-iq2_xs'; ctx = $C
            cold_prefill_tps = $probe.tps
            ttft_ms = & $median $kept 'ttft_ms'
            wall_tps = & $median $kept 'wall_tps'
            sse_prefill_tps = & $median $kept 'sse_prefill_tps'
            engine_decode_tps = & $median $kept 'engine_decode_tps'
            engine_prefill_tps = & $median $kept 'engine_prefill_tps'
            runs_kept = $kept.Count
        }
    } else { @{ label = $Label; model = 'qwen3.8-flash-next-iq2_xs'; ctx = $C; error = 'all SSE runs failed' } }
    return @{ probe = $probe; runs = $runs; summary = $summary }
}

# ---------------------------------------------------------------------------
# Matrix writer
# ---------------------------------------------------------------------------
function Write-Matrix {
    param([object[]]$Summaries, [string]$Path, [string]$Header)
    $lines = @("# Strata benchmark — $Header", "", "Harness: bench-strata.ps1 (Strata-style: cold prefill probe, 3x SSE t=0 max_tokens=$Predict, interleaved arms, first run discarded). Engine: Strata 0.1.40.2, IQ2_XS, KV 8-bit, 131K ctx server.", "")
    $lines += '| Arm | Ctx | Cold Prefill t/s | TTFT ms (med) | Engine Decode t/s (med) | Engine Prefill t/s (med) | Client Wall TPS | Runs |'
    $lines += '|---|---:|---:|---:|---:|---:|---:|---:|'
    foreach ($s in $Summaries) {
        if ($s.error) { $lines += "| $($s.label) | $($s.ctx) | ERROR | - | - | - | - | 0 |" }
        else {
            $lines += "| $($s.label) | $($s.ctx) | $($s.cold_prefill_tps) | $($s.ttft_ms) | $($s.engine_decode_tps) | $($s.engine_prefill_tps) | $($s.wall_tps) | $($s.runs_kept) |"
        }
    }
    $lines += ''
    $lines | Set-Content -Path $Path -Encoding utf8
    "matrix written: $Path"
}

# ===========================================================================
# MAIN
# ===========================================================================
"=== bench-strata ==="
if (-not (Test-StrataLoaded)) {
    "ERROR: Strata model not loaded. Start it first:"
    "  Start-Process C:\Strata\repo\run-iq2_xs.bat"
    "  (wait for /health loaded=true, ~1-3 min)"
    return
}
"  base=$Base  ctx=$Ctx  predict=$Predict  AB=$AB  out=$OutDir"
""

$allSummaries = @()

switch ($AB) {

    'none' {
        $arm = Invoke-Arm -C $Ctx -Seed 42 -Label "baseline-ctx$Ctx" -ProbeTks $ProbeTokens
        $allSummaries += $arm.summary
        $arm | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutDir 'arm.json') -Encoding utf8
    }

    'Ctx' {
        # Interleave: ctx1,ctx2,ctx3,ctx1,ctx2,ctx3,... (never sequential blocks).
        $seq = @()
        for ($p = 1; $p -le $Pairs; $p++) {
            foreach ($c in $CtxList) { $seq += @{ ctx = [int]$c; pair = $p } }
        }
        $seedBase = 200
        foreach ($step in $seq) {
            $label = "ctx-$($step.ctx)"
            $seed = $seedBase + $step.pair * 10 + [array]::IndexOf($CtxList, "$($step.ctx)")
            $arm = Invoke-Arm -C $step.ctx -Seed $seed -Label "$label-p$($step.pair)"
            $allSummaries += $arm.summary
            $arm | ConvertTo-Json -Depth 6 |
                Set-Content (Join-Path $OutDir "arm-$label-p$($step.pair).json") -Encoding utf8
        }
    }
}

Write-Matrix -Summaries $allSummaries -Path (Join-Path $OutDir 'matrix.md') `
    -Header "qwen3.8-flash-next IQ2_XS on Strata (AB=$AB)"
$allSummaries | ConvertTo-Json -Depth 5 |
    Set-Content (Join-Path $OutDir 'summaries.json') -Encoding utf8
"=== done — results in $OutDir ==="