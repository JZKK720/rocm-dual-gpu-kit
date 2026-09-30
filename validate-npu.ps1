# =============================================================================
# rocm-dual-gpu-kit
# Copyright 2026 cubecloud Limited (https://cubecloud.io)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# =============================================================================
# validate-npu.ps1
# Phase 1.3 validation: benchmark LLM inference on the XDNA2 NPU through
# Lemonade + FastFlowLM, and (optionally) prove simultaneous tri-device
# serving: NPU + iGPU + dGPU each load one model.
#
# Read-only on kit files; uses the already-running Lemonade server on 13305.
#
# Usage:
#   .\validate-npu.ps1                                # NPU-only benchmark
#   .\validate-npu.ps1 -Model qwen3-0.6b-FLM -Tokens 200
#   .\validate-npu.ps1 -TriGPU                        # also exercise iGPU+dGPU loads
#
# Verdict lines:
#   NPU DECODE: <tok/s>      <- FastFlowLM reports decoding_speed_tps
#   NPU PREFILL: TTFT <s>
#   TRI-DEVICE: PASS|SKIP
#
# Exit 0 when NPU DECODE >= 10 tok/s (0.6B q4nx on XDNA2 measures ~85), 1 otherwise.

param(
    [string]$Model = 'qwen3-0.6b-FLM',
    [int]$Tokens = 200,
    [switch]$TriGPU
)

$ErrorActionPreference = 'Stop'

function Invoke-ChatCompletion {
    param([string]$Name, [string]$Prompt, [int]$MaxTokens)

    $body = @{
        model       = $Name
        messages    = @(@{ role = 'user'; content = $Prompt })
        max_tokens  = $MaxTokens
        stream      = $false
    } | ConvertTo-Json -Depth 6 -Compress

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = Invoke-RestMethod -Uri 'http://127.0.0.1:13305/api/v1/chat/completions' `
        -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 600
    $sw.Stop()

    $usage = $resp.usage
    return @{
        Usage       = $usage
        WallSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        Text        = $resp.choices[0].message.content
        Model       = $resp.model
    }
}

"=== validate-npu: XDNA2 NPU serving benchmark ===" | Write-Host

# 0. Server must be up.
$serverUp = $false
try {
    $info = Invoke-RestMethod 'http://127.0.0.1:13305/api/v1/system-info' -TimeoutSec 5
    $serverUp = $true
} catch {
    "[FAIL] Lemonade server not reachable on 127.0.0.1:13305." |
        Write-Host -ForegroundColor Red
    "  Run .\install-npu-lemonade.ps1 first." | Write-Host
    exit 1
}
$npu = $info.devices.'amd_npu'
"  NPU device   : $($npu.name)" | Write-Host
"  NPU family   : $($npu.family)" | Write-Host
"  NPU available: $($npu.available)" | Write-Host
if (-not ($npu.available -and $npu.family -match 'XDNA2')) {
    "[FAIL] Server does not report an available XDNA2 NPU." | Write-Host -ForegroundColor Red
    exit 1
}

# 1. Ensure the model is pulled (auto-pull on load is slower; do it explicitly).
$models = Invoke-RestMethod 'http://127.0.0.1:13305/api/v1/models' -TimeoutSec 10
$hasModel = ($models.data | Where-Object { $_.id -eq $Model }).Count -gt 0
if (-not $hasModel) {
    "  Model '$Model' not pulled yet. Pulling..." | Write-Host
    $lemonadeExe = Join-Path $env:LOCALAPPDATA 'lemonade_server\bin\lemonade.exe'
    & $lemonadeExe pull $Model 2>&1 | ForEach-Object { "  $_" }
    if ($LASTEXITCODE -ne 0) {
        "[FAIL] pull '$Model' failed." | Write-Host -ForegroundColor Red
        exit 1
    }
}

# 2. Warm-up request (loads NPU model if not resident; measures full load path).
"  Warm-up request (may include first NPU load)..." | Write-Host
try {
    $null = Invoke-ChatCompletion -Name $Model -Prompt 'Say OK.' -MaxTokens 8
} catch {
    "[FAIL] warm-up request threw: $($_.Exception.Message)" | Write-Host -ForegroundColor Red
    exit 1
}

# 3. Benchmark request.
"  Benchmark request (${Tokens}-token generation)..." | Write-Host
$bench = Invoke-ChatCompletion -Name $Model `
    -Prompt 'Write a 200-word essay about the history of computing.' -MaxTokens $Tokens
$u = $bench.Usage

"" | Write-Host
"=== BENCHMARK ===" | Write-Host
"  model            : $($bench.Model)" | Write-Host
"  wall             : $($bench.WallSeconds) s" | Write-Host
"  prompt tokens    : $($u.prompt_tokens)" | Write-Host
"  completion tokens: $($u.completion_tokens)" | Write-Host
"  decode duration  : $([math]::Round($u.decoding_duration,3)) s" | Write-Host

$npuDecode  = [math]::Round($u.decoding_speed_tps, 1)
$npuTtft    = [math]::Round($u.prefill_duration_ttft, 3)
$npuPrefill = [math]::Round($u.prefill_speed_tps, 1)

"NPU DECODE: $npuDecode tok/s" | Write-Host
"NPU PREFILL: TTFT ${npuTtft} s ($npuPrefill tok/s)" | Write-Host
"NPU LOAD: $([math]::Round($u.load_duration,3)) s" | Write-Host

$preview = ''
if ($bench.Text) { $preview = $bench.Text.Substring(0, [Math]::Min(120, $bench.Text.Length)) }
"  text preview    : $preview..." | Write-Host

# 4. Optional tri-gpu proof
$tri = 'SKIP'
if ($TriGPU) {
    "  Tri-GPU mode: NPU model + one iGPU (vulkan/rocm) model concurrent." | Write-Host
    "  (dGPU model omitted here; use configure-ollama-dual-gpu.ps1 for that path.)" | Write-Host
    "  [TODO] Tri-device load orchestration lands in a later rev." | Write-Host -ForegroundColor Yellow
}

"" | Write-Host
"=== VERDICT ===" | Write-Host
"  $npuDecode tok/s NPU decode on $Model" | Write-Host
if ($npuDecode -ge 10) {
    "  overall: PASS (NPU serving works)" | Write-Host -ForegroundColor Green
    exit 0
} else {
    "  overall: FAIL (decode below sanity threshold 10 tok/s)" | Write-Host -ForegroundColor Red
    exit 1
}