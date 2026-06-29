// =============================================================================
// rocm-dual-gpu-kit
// Copyright 2026 cubecloud Limited (https://cubecloud.io)
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// =============================================================================
// peer_vram_test.cpp
// Reproduce the non-peers VRAM copy failure and demonstrate the host-memory
// staging workaround on an AMD dual-GPU box (iGPU + dGPU marked non-peers).
//
// Build (via test-peer-vram.ps1):
//   clang.exe --driver-mode=g++ --hip-link --offload-arch=gfx1100 ...
// Run:
//   HIP_VISIBLE_DEVICES=0,1 peer_vram_test.exe
//
// Expected output verdict lines (grepped by the runner):
//   PEER COPY: FAIL (expected)      <- non-peers, hipMemcpyPeer fails
//   STAGING COPY: PASS              <- dGPU -> host pinned -> iGPU works

#include <hip/hip_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static const size_t N = 1024;          // 1 KiB of ints
static const int    PATTERN = 0xCAFEBABE;

#define HIP_CHECK(expr) do { \
    hipError_t _e = (expr); \
    if (_e != hipSuccess) { \
        fprintf(stderr, "  [hip] %s:%d %s -> %s (%d)\n", \
                __FILE__, __LINE__, #expr, hipGetErrorString(_e), (int)_e); \
    } \
} while (0)

static void print_devices() {
    int count = 0;
    HIP_CHECK(hipGetDeviceCount(&count));
    printf("  hipGetDeviceCount: %d\n", count);
    for (int d = 0; d < count; ++d) {
        hipDeviceProp_t p;
        if (hipGetDeviceProperties(&p, d) != hipSuccess) {
            printf("  device#%d: (properties unavailable)\n", d);
            continue;
        }
        printf("  device#%d  %s\n", d, p.name);
        printf("    gcnArchName:  %s\n", p.gcnArchName);
        printf("    totalGlobalMem: %llu MB\n",
               (unsigned long long)(p.totalGlobalMem / (1024 * 1024)));
        printf("    pciBusID:     %d\n", p.pciBusID);
    }
    if (count < 2) {
        printf("  [!] Need 2 devices for the peer test; got %d.\n", count);
    }
}

static void test_peer_copy() {
    int canAccess01 = 0, canAccess10 = 0;
    hipError_t e01 = hipDeviceCanAccessPeer(&canAccess01, 0, 1);
    hipError_t e10 = hipDeviceCanAccessPeer(&canAccess10, 1, 0);
    printf("  hipDeviceCanAccessPeer(0->1): %d (err=%d)\n", canAccess01, (int)e01);
    printf("  hipDeviceCanAccessPeer(1->0): %d (err=%d)\n", canAccess10, (int)e10);

    // Allocate small buffers on each device.
    int* d0_buf = nullptr;   // iGPU
    int* d1_buf = nullptr;   // dGPU
    HIP_CHECK(hipSetDevice(0));
    HIP_CHECK(hipMalloc(&d0_buf, N * sizeof(int)));
    HIP_CHECK(hipSetDevice(1));
    HIP_CHECK(hipMalloc(&d1_buf, N * sizeof(int)));

    // Fill d1_buf with the pattern via a host staging fill.
    int* host_fill = (int*)malloc(N * sizeof(int));
    for (size_t i = 0; i < N; ++i) host_fill[i] = PATTERN;
    HIP_CHECK(hipSetDevice(1));
    HIP_CHECK(hipMemcpy(d1_buf, host_fill, N * sizeof(int), hipMemcpyHostToDevice));
    free(host_fill);

    // Attempt peer access enable + peer copy.
    // On non-peers, hipDeviceEnablePeerAccess fails, but hipMemcpyPeer may
    // transparently fall back to host-memory staging (HIP SDK 7.1.0 does this).
    hipError_t enableErr = hipDeviceEnablePeerAccess(1, 0);
    printf("  hipDeviceEnablePeerAccess(1,0): err=%d (%s)\n",
           (int)enableErr, hipGetErrorString(enableErr));

    hipError_t copyErr = hipMemcpyPeer(d0_buf, 0, d1_buf, 1, N * sizeof(int));
    printf("  hipMemcpyPeer(d0<-d1): err=%d (%s)\n",
           (int)copyErr, hipGetErrorString(copyErr));

    // Verify the peer copy actually delivered correct data (even if staged).
    int* verify = (int*)malloc(N * sizeof(int));
    HIP_CHECK(hipSetDevice(0));
    HIP_CHECK(hipMemcpy(verify, d0_buf, N * sizeof(int), hipMemcpyDeviceToHost));
    bool peerDataOk = true;
    for (size_t i = 0; i < N; ++i) {
        if (verify[i] != PATTERN) { peerDataOk = false; break; }
    }
    free(verify);

    if (copyErr == hipSuccess && peerDataOk) {
        if (canAccess01 || canAccess10) {
            printf("PEER COPY: PASS (direct peer access)\n");
        } else {
            printf("PEER COPY: PASS (transparent host staging by HIP runtime)\n");
        }
    } else {
        printf("PEER COPY: FAIL (err=%d, dataOk=%d)\n", (int)copyErr, (int)peerDataOk);
    }

    HIP_CHECK(hipFree(d0_buf));
    HIP_CHECK(hipFree(d1_buf));
}

static void test_staging_copy() {
    // d1_buf (dGPU) -> host pinned -> d0_buf (iGPU) -> host verify
    int* d0_buf = nullptr;
    int* d1_buf = nullptr;
    int* pinned = nullptr;

    HIP_CHECK(hipSetDevice(1));
    HIP_CHECK(hipMalloc(&d1_buf, N * sizeof(int)));
    HIP_CHECK(hipSetDevice(0));
    HIP_CHECK(hipMalloc(&d0_buf, N * sizeof(int)));

    // hipHostMalloc gives a host-accessible pinned buffer.
    hipError_t pinErr = hipHostMalloc((void**)&pinned, N * sizeof(int), hipHostMallocDefault);
    if (pinErr != hipSuccess) {
        printf("  [!] hipHostMalloc failed (%d); falling back to hipMallocHost\n", (int)pinErr);
        HIP_CHECK(hipMallocHost((void**)&pinned, N * sizeof(int)));
    }

    // Fill d1_buf with the pattern.
    for (size_t i = 0; i < N; ++i) pinned[i] = PATTERN;
    HIP_CHECK(hipSetDevice(1));
    HIP_CHECK(hipMemcpy(d1_buf, pinned, N * sizeof(int), hipMemcpyHostToDevice));

    // Stage 1: dGPU -> host pinned.
    HIP_CHECK(hipSetDevice(1));
    HIP_CHECK(hipMemcpy(pinned, d1_buf, N * sizeof(int), hipMemcpyDeviceToHost));

    // Stage 2: host pinned -> iGPU.
    HIP_CHECK(hipSetDevice(0));
    HIP_CHECK(hipMemcpy(d0_buf, pinned, N * sizeof(int), hipMemcpyHostToDevice));

    // Verify: read d0_buf back to a fresh host buffer.
    int* verify = (int*)malloc(N * sizeof(int));
    HIP_CHECK(hipSetDevice(0));
    HIP_CHECK(hipMemcpy(verify, d0_buf, N * sizeof(int), hipMemcpyDeviceToHost));

    bool ok = true;
    for (size_t i = 0; i < N; ++i) {
        if (verify[i] != PATTERN) { ok = false; break; }
    }
    free(verify);

    if (ok) {
        printf("STAGING COPY: PASS\n");
    } else {
        printf("STAGING COPY: FAIL\n");
    }

    HIP_CHECK(hipFree(d0_buf));
    HIP_CHECK(hipFree(d1_buf));
    if (pinErr == hipSuccess) {
        HIP_CHECK(hipHostFree(pinned));
    } else {
        HIP_CHECK(hipFreeHost(pinned));
    }
}

int main() {
    printf("=== peer_vram_test ===\n");
    printf("  N=%zu ints, PATTERN=0x%X\n", N, PATTERN);
    printf("\n");
    printf("--- device enumeration ---\n");
    print_devices();

    int count = 0;
    if (hipGetDeviceCount(&count) != hipSuccess || count < 2) {
        printf("\n  [!] Skipping peer + staging tests: need 2 devices.\n");
        printf("PEER COPY: SKIP\n");
        printf("STAGING COPY: SKIP\n");
        return 2;
    }

    printf("\n--- peer copy attempt (expected to fail on non-peers) ---\n");
    test_peer_copy();

    printf("\n--- host-memory staging workaround (expected to pass) ---\n");
    test_staging_copy();

    printf("\n=== done ===\n");
    return 0;
}