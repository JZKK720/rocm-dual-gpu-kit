"""Read-only ASCII string scanner for Ollama binaries.

Confirms which Ollama/llama.cpp environment variables this exact build actually
honours. Prevents recommending env vars the binary ignores.

Usage: python scan_bins.py <file> [<file> ...]
"""
import re
import sys
from pathlib import Path

CANDIDATES = [
    # Ollama server tuning
    "OLLAMA_SCHED_SPREAD", "OLLAMA_IGPU_ENABLE", "OLLAMA_GPU_OVERHEAD",
    "OLLAMA_KV_CACHE_TYPE", "OLLAMA_FLASH_ATTENTION", "OLLAMA_CONTEXT_LENGTH",
    "OLLAMA_NUM_PARALLEL", "OLLAMA_MAX_LOADED_MODELS", "OLLAMA_KEEP_ALIVE",
    "OLLAMA_MODELS", "OLLAMA_HOST", "OLLAMA_DEBUG", "OLLAMA_NEW_ENGINE",
    # llama.cpp
    "NO_PEER_COPY", "GGML_CUDA_NO_PEER_COPY", "LLAMA_ARG_SPLIT_MODE",
    "LLAMA_ARG_TENSOR_SPLIT", "LLAMA_ARG_DEVICE", "LLAMA_ARG_N_GPU_LAYERS",
    "LLAMA_ARG_CTX_SIZE", "LLAMA_ARG_CACHE_TYPE_K", "LLAMA_ARG_CACHE_TYPE_V",
    "LLAMA_ARG_FLASH_ATTN", "LLAMA_ARG_N_CPU_MOE", "LLAMA_ARG_OVERRIDE_TENSOR",
    "split-mode", "tensor-split", "n-cpu-moe", "cache-type-k", "cache-type-v",
    # backends
    "ggml-hip.dll", "ggml-vulkan.dll", "rocm_v7_1", "ROCm0", "ROCm1",
]


def scan(path):
    data = Path(path).read_bytes()
    if len(data) > 900 * 1024 * 1024:
        print(f"  (skipping {path}: unusually large)")
    print("=" * 74)
    print(f"FILE: {path}")
    print(f"  size: {len(data)/1024**2:,.1f} MiB")
    print("=" * 74)
    present, absent = [], []
    for s in CANDIDATES:
        if data.find(s.encode("utf-8")) >= 0 or data.find(s.encode("utf-16-le")) >= 0:
            present.append(s)
        else:
            absent.append(s)
    print("  -- PRESENT --")
    for s in present:
        print(f"     [yes] {s}")
    print("  -- ABSENT --")
    for s in absent:
        print(f"     [ no] {s}")
    print()


if __name__ == "__main__":
    for p in sys.argv[1:]:
        scan(p)
