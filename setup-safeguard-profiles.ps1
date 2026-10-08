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
# setup-safeguard-profiles.ps1
# Configures and registers optimized, safe-context-window models inside Ollama
# to prevent memory overflows, pagefile thrashing, and high latency.
#
# Usage:
#   .\setup-safeguard-profiles.ps1
# =============================================================================

$ErrorActionPreference = 'Stop'

# --- 1. Define Paths ---
$ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$NemotronModelfile = Join-Path $ScriptDir "nemotron-safe.Modelfile"
$QwenModelfile = Join-Path $ScriptDir "qwen-safe.Modelfile"

"" | Write-Host
"=== Setting Up Optimized Model Safeguards ===" | Write-Host -ForegroundColor Cyan

# --- 2. Write Modelfiles ---
"  Writing nemotron-safe.Modelfile..." | Write-Host
$nemotronContent = @"
FROM nemotron-3.5-lightning:30b-a3b
# Restrict context window to fit comfortably within physical memory bounds
PARAMETER num_ctx 8192
PARAMETER num_predict 2048
PARAMETER temperature 0
"@
$nemotronContent | Out-File -FilePath $NemotronModelfile -Encoding utf8 -Force

"  Writing qwen-safe.Modelfile..." | Write-Host
$qwenContent = @"
FROM qwen3.8-flash-next:125b-a6b-q4_K_M
# Restrict context window to fit robustly with MoE activation footprint
PARAMETER num_ctx 4096
PARAMETER num_predict 1024
PARAMETER temperature 0
"@
$qwenContent | Out-File -FilePath $QwenModelfile -Encoding utf8 -Force

# --- 3. Verify Ollama Connection & State ---
$ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollamaCmd) {
    $ollamaExe = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
    if (-not (Test-Path $ollamaExe)) {
        throw "Ollama executable not found on this system. Please verify installation."
    }
}

# Check if Ollama is running
$isRunning = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
if (-not $isRunning) {
    "  [!] Ollama server is not running. Attempting to start it..." | Write-Host -ForegroundColor Yellow
    $trayAppExe = "$env:LOCALAPPDATA\Programs\Ollama\ollama app.exe"
    if (Test-Path $trayAppExe) {
        Start-Process -FilePath $trayAppExe -WindowStyle Hidden
        Start-Sleep -Seconds 5
    } else {
        throw "Could not launch Ollama tray application. Please launch Ollama manually first."
    }
}

# --- 4. Query available models ---
$list = (ollama list) -join "`n"

# Only register nemotron-safe if the base model exists
if ($list -match "nemotron-3.5-lightning:30b-a3b") {
    "  Registering optimized 'nemotron-safe' model..." | Write-Host -ForegroundColor Green
    ollama create nemotron-safe -f $NemotronModelfile
} else {
    "  [-] Base model nemotron-3.5-lightning:30b-a3b not found in 'ollama list'." | Write-Host -ForegroundColor Yellow
    "      To download first: ollama pull nemotron-3.5-lightning:30b-a3b" | Write-Host
}

# Only register qwen-safe if the base model exists
if ($list -match "qwen3.8-flash-next:125b-a6b-q4_K_M") {
    "  Registering optimized 'qwen-safe' model..." | Write-Host -ForegroundColor Green
    ollama create qwen-safe -f $QwenModelfile
} else {
    "  [-] Base model qwen3.8-flash-next:125b-a6b-q4_K_M not found in 'ollama list'." | Write-Host -ForegroundColor Yellow
    "      To download first: ollama pull qwen3.8-flash-next:125b-a6b-q4_K_M" | Write-Host
}

"" | Write-Host
"=== Setup Complete ===" | Write-Host -ForegroundColor Green
"  The optimized config profiles are ready to use!" | Write-Host
"  You can run them anytime using:" | Write-Host
"    ollama run nemotron-safe" | Write-Host
"    ollama run qwen-safe" | Write-Host
"" | Write-Host
