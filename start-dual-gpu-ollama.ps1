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
# start-dual-gpu-ollama.ps1
# Option 1: Run Ollama with two models loaded simultaneously — one on the
# iGPU (87 GB VRAM) and one on the dGPU (24 GB VRAM).
#
# This sets the Ollama env vars so the scheduler allows 2 models resident
# at once. Ollama's scheduler picks one GPU per model, so with 2 models
# loaded, both GPUs are used in parallel for concurrent requests.
#
# Usage:
#   .\start-dual-gpu-ollama.ps1              # start Ollama with dual-model support
#   .\start-dual-gpu-ollama.ps1 -Stop        # stop the Ollama server
#
# After starting, load two models in separate terminals:
#   ollama run gemma4:12b-it-q8_0    # ~12 GB, will land on dGPU (24 GB)
#   ollama run gemma4:26b-a4b-it-q8_0  # ~28 GB, will land on iGPU (87 GB)
#
# Then concurrent requests to different models run on different GPUs.

param(
    [switch]$Stop
)

$ErrorActionPreference = 'Stop'

if ($Stop) {
    "" | Write-Host
    "=== Stopping Ollama server ===" | Write-Host
    $proc = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
    if ($proc) {
        $proc | Stop-Process -Force
        "  Stopped $($proc.Count) Ollama process(es)." | Write-Host -ForegroundColor Green
    } else {
        "  Ollama is not running." | Write-Host -ForegroundColor Yellow
    }
    # Also stop the llama-server runners
    $runner = Get-Process -Name "llama-server" -ErrorAction SilentlyContinue
    if ($runner) {
        $runner | Stop-Process -Force
        "  Stopped $($runner.Count) llama-server runner(s)." | Write-Host
    }
    exit 0
}

# --- Set env vars for dual-model dual-GPU ---
# Allow 2 models resident in VRAM simultaneously
$env:OLLAMA_MAX_LOADED_MODELS = "2"
# One parallel request per model (each on its own GPU)
$env:OLLAMA_NUM_PARALLEL = "1"
# Keep models loaded for 30 minutes (default 5m is too short for dev work)
$env:OLLAMA_KEEP_ALIVE = "30m"
# Bind to all interfaces (consistent with existing config)
$env:OLLAMA_HOST = "0.0.0.0:11434"
# Enable iGPU (the 87 GB Strix Halo iGPU is our workhorse)
$env:OLLAMA_IGPU_ENABLE = "1"
# Let Ollama see both GPUs
$env:HIP_VISIBLE_DEVICES = "0,1"
$env:ROCR_VISIBLE_DEVICES = "0,1"

"" | Write-Host
"=== Dual-GPU Ollama Configuration ===" | Write-Host -ForegroundColor Cyan
"  OLLAMA_MAX_LOADED_MODELS = $env:OLLAMA_MAX_LOADED_MODELS  (2 models in VRAM)" | Write-Host
"  OLLAMA_NUM_PARALLEL      = $env:OLLAMA_NUM_PARALLEL  (1 request per model)" | Write-Host
"  OLLAMA_KEEP_ALIVE        = $env:OLLAMA_KEEP_ALIVE  (30 min)" | Write-Host
"  OLLAMA_IGPU_ENABLE       = $env:OLLAMA_IGPU_ENABLE  (iGPU enabled)" | Write-Host
"  HIP_VISIBLE_DEVICES      = $env:HIP_VISIBLE_DEVICES  (both GPUs)" | Write-Host
"" | Write-Host
"  GPU 0 (iGPU): AMD Radeon 8060S Graphics  — 87.9 GB VRAM" | Write-Host
"  GPU 1 (dGPU): AMD Radeon RX 7900 XTX     — 24.0 GB VRAM" | Write-Host
"" | Write-Host
"  Recommended model assignments:" | Write-Host
"    iGPU (87 GB): gemma4:26b-a4b-it-q8_0  (~28 GB)  or  qwen3.5:35b-a3b (~23 GB)" | Write-Host
"    dGPU (24 GB): gemma4:12b-it-q8_0      (~12 GB)  or  ornith:9b-q8_0  (~9.5 GB)" | Write-Host
"" | Write-Host

# --- Stop any existing Ollama first ---
$existing = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
if ($existing) {
    "  Stopping existing Ollama process..." | Write-Host -ForegroundColor Yellow
    $existing | Stop-Process -Force
    Start-Sleep -Seconds 2
}

# --- Start Ollama serve in background ---
"=== Starting Ollama server ===" | Write-Host
$ollamaExe = (Get-Command ollama -ErrorAction SilentlyContinue).Source
if (-not $ollamaExe) {
    $ollamaExe = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
}
if (-not (Test-Path $ollamaExe)) { throw "Ollama not found at $ollamaExe" }
"  exe: $ollamaExe" | Write-Host

$proc = Start-Process -FilePath $ollamaExe -ArgumentList "serve" -PassThru -NoNewWindow
Start-Sleep -Seconds 3

if ($proc.HasExited) {
    "  [!] Ollama exited immediately (code $($proc.ExitCode))." | Write-Host -ForegroundColor Red
    exit 1
} else {
    "  Ollama server started (PID $($proc.Id))." | Write-Host -ForegroundColor Green
}

"" | Write-Host
"=== Next steps ===" | Write-Host
"  1. Load the large model (lands on iGPU 87 GB):" | Write-Host
"     ollama run gemma4:26b-a4b-it-q8_0" | Write-Host
"" | Write-Host
"  2. In a SECOND terminal, load the small model (lands on dGPU 24 GB):" | Write-Host
"     ollama run gemma4:12b-it-q8_0" | Write-Host
"" | Write-Host
"  3. Both models are now in VRAM on different GPUs." | Write-Host
"     Concurrent requests to different models run in parallel." | Write-Host
"" | Write-Host
"  Check status:  ollama ps" | Write-Host
"  Stop:          .\start-dual-gpu-ollama.ps1 -Stop" | Write-Host
"" | Write-Host