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
# configure-ollama-dual-gpu.ps1
# Configure Ollama's user-level environment variables for dual-GPU operation,
# then gracefully restart the Ollama tray app so the server picks up the new config.
#
# This does NOT kill the Ollama service — it sets persistent user env vars and
# restarts the tray app, which in turn restarts the server with the new config.
#
# Usage:
#   .\configure-ollama-dual-gpu.ps1          # apply config and restart tray app
#   .\configure-ollama-dual-gpu.ps1 -Revert  # remove the config and restart

param(
    [switch]$Revert
)

$ErrorActionPreference = 'Stop'

function Restart-OllamaTrayApp {
    # Find the tray app process
    $trayApp = Get-Process -Name "ollama app" -ErrorAction SilentlyContinue
    if (-not $trayApp) {
        "  [!] Ollama tray app not running. Starting it..." | Write-Host -ForegroundColor Yellow
        $trayAppExe = "$env:LOCALAPPDATA\Programs\Ollama\ollama app.exe"
        if (Test-Path $trayAppExe) {
            Start-Process -FilePath $trayAppExe -WindowStyle Hidden
            Start-Sleep -Seconds 3
        } else {
            throw "Ollama tray app not found at $trayAppExe"
        }
        return
    }

    "  Stopping Ollama tray app (PID $($trayApp.Id))..." | Write-Host
    $trayApp | Stop-Process -Force

    # Wait for the server process to also stop
    Start-Sleep -Seconds 2
    $server = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
    if ($server) {
        "  Waiting for server to stop..." | Write-Host
        $server | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    }

    "  Starting Ollama tray app..." | Write-Host
    $trayAppExe = "$env:LOCALAPPDATA\Programs\Ollama\ollama app.exe"
    if (Test-Path $trayAppExe) {
        Start-Process -FilePath $trayAppExe -WindowStyle Hidden
        Start-Sleep -Seconds 3
        "  Tray app restarted." | Write-Host -ForegroundColor Green
    } else {
        throw "Ollama tray app not found at $trayAppExe"
    }
}

# --- Env vars to set for dual-GPU dual-model operation ---
$envVars = @{
    "OLLAMA_MAX_LOADED_MODELS" = "2"      # Allow 2 models in VRAM simultaneously
    "OLLAMA_NUM_PARALLEL"      = "1"      # 1 request per model (each on its own GPU)
    "OLLAMA_KEEP_ALIVE"        = "30m"    # Keep models loaded for 30 min
    "OLLAMA_IGPU_ENABLE"       = "1"      # Enable iGPU (Strix Halo 87 GB)
    "HIP_VISIBLE_DEVICES"      = "0,1"    # Both GPUs visible to HIP
    "ROCR_VISIBLE_DEVICES"     = "0,1"    # Both GPUs visible to ROCR
}

if ($Revert) {
    "" | Write-Host
    "=== Reverting Ollama dual-GPU config ===" | Write-Host -ForegroundColor Cyan
    foreach ($key in $envVars.Keys) {
        [Environment]::SetEnvironmentVariable($key, $null, "User")
        "  Removed user env var: $key" | Write-Host
    }
    "" | Write-Host
    "  Restarting Ollama tray app..." | Write-Host
    Restart-OllamaTrayApp
    "" | Write-Host
    "  Done. Ollama will now use default single-GPU behavior." | Write-Host -ForegroundColor Green
    exit 0
}

"" | Write-Host
"=== Configuring Ollama for dual-GPU dual-model operation ===" | Write-Host -ForegroundColor Cyan

# Set user-level environment variables (persistent across reboots)
foreach ($key in $envVars.Keys) {
    $value = $envVars[$key]
    [Environment]::SetEnvironmentVariable($key, $value, "User")
    "  Set user env var: $key = $value" | Write-Host
}

# Also set in current session for immediate effect
foreach ($key in $envVars.Keys) {
    Set-Item -Path "Env:$key" -Value $envVars[$key]
}

"" | Write-Host
"  GPU assignment (Ollama scheduler picks one GPU per model):" | Write-Host
"    GPU 0 (iGPU): AMD Radeon 8060S Graphics  — 87.9 GB VRAM" | Write-Host
"    GPU 1 (dGPU): AMD Radeon RX 7900 XTX     — 24.0 GB VRAM" | Write-Host
"" | Write-Host
"  Recommended model pairing:" | Write-Host
"    iGPU (87 GB): gemma4:26b-a4b-it-q8_0  (~28 GB)  or  qwen3.5:35b-a3b (~23 GB)" | Write-Host
"    dGPU (24 GB): gemma4:12b-it-q8_0      (~12 GB)  or  ornith:9b-q8_0  (~9.5 GB)" | Write-Host
"" | Write-Host

# Restart the Ollama tray app so it picks up the new env vars
Restart-OllamaTrayApp

"" | Write-Host
"=== Done ===" | Write-Host -ForegroundColor Green
"  Ollama tray app restarted. The server now runs with dual-GPU config." | Write-Host
"" | Write-Host
"  Next steps:" | Write-Host
"  1. Load the large model (lands on iGPU):" | Write-Host
"     ollama run gemma4:26b-a4b-it-q8_0" | Write-Host
"" | Write-Host
"  2. In a SECOND terminal, load the small model (lands on dGPU):" | Write-Host
"     ollama run gemma4:12b-it-q8_0" | Write-Host
"" | Write-Host
"  3. Both models are now in VRAM on different GPUs." | Write-Host
"     Concurrent requests to different models run in parallel." | Write-Host
"" | Write-Host
"  Check status:  ollama ps" | Write-Host
"  Revert:        .\configure-ollama-dual-gpu.ps1 -Revert" | Write-Host
"" | Write-Host