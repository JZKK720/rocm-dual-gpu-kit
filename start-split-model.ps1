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
# start-split-model.ps1
# Option 2: Run a single model split across both GPUs using llama-server
# directly (bypassing Ollama's scheduler) with --split-mode layer.
#
# This forces llama.cpp to distribute model layers across the iGPU (87 GB)
# and dGPU (24 GB). Because the GPUs are non-peers (NO_PEER_COPY=1), each
# layer boundary stages through host memory — expect 2-4x slower than
# single-GPU for most models. Only use this when a model genuinely doesn't
# fit in either GPU alone.
#
# Usage:
#   .\start-split-model.ps1                              # default: qwen3.5:35b-a3b
#   .\start-split-model.ps1 -Model gemma4:26b-a4b-it-q8_0  # specify model
#   .\start-split-model.ps1 -Stop                          # stop the server
#
# The server exposes an OpenAI-compatible API at http://localhost:8081
# Test with:
#   curl http://localhost:8081/v1/chat/completions -d '{"model":"split","messages":[{"role":"user","content":"hello"}]}'

param(
    [string]$Model = "qwen3.5:35b-a3b",
    [int]$Port = 8081,
    [int]$CtxSize = 8192,
    [int]$NGl = 999,
    [switch]$Stop
)

$ErrorActionPreference = 'Stop'

# --- Resolve Ollama's bundled llama-server and ROCm libs ---
$ollamaLib = "$env:LOCALAPPDATA\Programs\Ollama\lib\ollama"
$llamaServer = Join-Path $ollamaLib "llama-server.exe"
$rocmDir = Join-Path $ollamaLib "rocm_v7_1"

if (-not (Test-Path $llamaServer)) { throw "llama-server.exe not found at $llamaServer" }
if (-not (Test-Path $rocmDir)) { throw "ROCm lib dir not found at $rocmDir" }

if ($Stop) {
    "" | Write-Host
    "=== Stopping split-model llama-server ===" | Write-Host
    $proc = Get-Process -Name "llama-server" -ErrorAction SilentlyContinue
    if ($proc) {
        $proc | Stop-Process -Force
        "  Stopped $($proc.Count) llama-server process(es)." | Write-Host -ForegroundColor Green
    } else {
        "  llama-server is not running." | Write-Host -ForegroundColor Yellow
    }
    exit 0
}

# --- Resolve the model blob path from Ollama's manifest ---
$manifestPath = "$env:USERPROFILE\.ollama\models\manifests\registry.ollama.ai\library\$($Model -replace ':','/')"
if (-not (Test-Path $manifestPath)) { throw "Model manifest not found: $manifestPath`nAvailable models: ollama list" }
$manifest = Get-Content $manifestPath | ConvertFrom-Json
$modelDigest = ($manifest.layers | Where-Object { $_.mediaType -match 'image.model' }).digest
if (-not $modelDigest) { throw "No model layer found in manifest for $Model" }
$modelPath = Join-Path "$env:USERPROFILE\.ollama\models\blobs" ($modelDigest -replace 'sha256:','sha256-')
if (-not (Test-Path $modelPath)) { throw "Model blob not found: $modelPath" }

# Resolve projector if present (for multimodal models)
$projDigest = ($manifest.layers | Where-Object { $_.mediaType -match 'projector' }).digest
$projPath = $null
if ($projDigest) {
    $projPath = Join-Path "$env:USERPROFILE\.ollama\models\blobs" ($projDigest -replace 'sha256:','sha256-')
}

# --- Set ROCm env for both GPUs ---
$env:HIP_VISIBLE_DEVICES = "0,1"
$env:ROCR_VISIBLE_DEVICES = "0,1"
$env:HIP_PATH = $rocmDir
$env:ROCM_PATH = $rocmDir
$env:PATH = "$rocmDir\bin;$ollamaLib;$env:PATH"

"" | Write-Host
"=== Split-Model Dual-GPU Configuration ===" | Write-Host -ForegroundColor Cyan
"  Model:     $Model" | Write-Host
"  Blob:      $modelPath" | Write-Host
if ($projPath) { "  Projector: $projPath" | Write-Host }
"  Port:      $Port" | Write-Host
"  Context:   $CtxSize tokens" | Write-Host
"  GPU layers: $NGl (all)" | Write-Host
"  Split mode: layer (pipelined across iGPU + dGPU)" | Write-Host
"  Tensor split: 0.78,0.22 (iGPU gets ~78%, dGPU gets ~22%)" | Write-Host
"" | Write-Host
"  GPU 0 (iGPU): AMD Radeon 8060S Graphics  — 87.9 GB VRAM" | Write-Host
"  GPU 1 (dGPU): AMD Radeon RX 7900 XTX     — 24.0 GB VRAM" | Write-Host
"  Total VRAM:   111.9 GB" | Write-Host
"" | Write-Host
"  NOTE: NO_PEER_COPY=1 — layer boundaries stage through host RAM." | Write-Host -ForegroundColor Yellow
"  Expect 2-4x slower than single-GPU. Use only when the model" | Write-Host -ForegroundColor Yellow
"  doesn't fit in one GPU alone." | Write-Host -ForegroundColor Yellow
"" | Write-Host

# --- Stop any existing llama-server first ---
$existing = Get-Process -Name "llama-server" -ErrorAction SilentlyContinue
if ($existing) {
    "  Stopping existing llama-server..." | Write-Host -ForegroundColor Yellow
    $existing | Stop-Process -Force
    Start-Sleep -Seconds 2
}

# --- Build arguments ---
# Tensor split: iGPU (87.9 GB) gets 87.9/(87.9+24.0) = 0.785, dGPU gets 0.215
$args = @(
    "-m", $modelPath,
    "--split-mode", "layer",
    "--tensor-split", "0.78,0.22",
    "-ngl", $NGl,
    "-c", $CtxSize,
    "--port", $Port,
    "--host", "127.0.0.1",
    "--alias", "split"
)
if ($projPath) {
    $args += @("--mmproj", $projPath)
}

"=== Starting llama-server ===" | Write-Host
"  exe: $llamaServer" | Write-Host
"  args: $($args -join ' ')" | Write-Host
"" | Write-Host

# --- Start llama-server in background ---
$proc = Start-Process -FilePath $llamaServer -ArgumentList $args -PassThru -NoNewWindow
Start-Sleep -Seconds 5

if ($proc.HasExited) {
    "  [!] llama-server exited immediately (code $($proc.ExitCode))." | Write-Host -ForegroundColor Red
    "  Check that the model path is correct and both GPUs are visible." | Write-Host
    exit 1
} else {
    "  llama-server started (PID $($proc.Id))." | Write-Host -ForegroundColor Green
}

"" | Write-Host
"=== Server is live ===" | Write-Host
"  OpenAI API:  http://127.0.0.1:$Port/v1/chat/completions" | Write-Host
"  Health:      http://127.0.0.1:$Port/health" | Write-Host
"" | Write-Host
"  Test with:" | Write-Host
"  curl http://127.0.0.1:$Port/v1/chat/completitions -H 'Content-Type: application/json' -d '{""model"":""split"",""messages"":[{""role"":""user"",""content"":""hello""}]}'" | Write-Host
"" | Write-Host
"  Stop: .\start-split-model.ps1 -Stop" | Write-Host
"" | Write-Host