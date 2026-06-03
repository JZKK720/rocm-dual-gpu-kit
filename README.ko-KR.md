<!--
  rocm-dual-gpu-kit
  Copyright 2026 cubecloud Limited (https://cubecloud.io)
  SPDX-License-Identifier: Apache-2.0
-->

# ROCm 듀얼 GPU 설정 — 방법 및 툴킷

**Copyright 2026 cubecloud Limited (https://cubecloud.io)** · [Apache License 2.0](LICENSE) 라이선스 적용

본 툴킷은 **Option 2** 듀얼 GPU 패턴을 재현합니다. 지원 대상:

- **iGPU** (예: Strix Halo gfx1151, Strix Point gfx1155, Phoenix gfx1103, Rembrandt gfx1103, Van Gogh gfx1035 등) — **TheRock pip wheels** 사용
- **dGPU** (예: Navi 31/32/33 = gfx1100/1101/1102, RDNA 4 = gfx1200/1201) — **시스템 HIP SDK** 사용

레시피는 다음 환경에서 개발 및 검증되었습니다:
- AMD Adrenalin 드라이버 32.0.31019.2002 (Windows)
- AMD HIP SDK 7.1.0 (`C:\Program Files\AMD\ROCm\7.1\`)
- TheRock Python 휠 (`https://repo.amd.com/rocm/whl/<target>/`, 본 문서 작성 시점 7.13.0)
- Python 3.12.10 (시스템)
- Visual Studio 2022 BuildTools (C++ 워크로드, Windows SDK 10.0.26100)

**디스크 사용량**: TheRock venv당 약 22 GB, HIP SDK 약 3 GB. dGPU 측은 HIP SDK를 재사용하고, iGPU 측은 venv에서 실행.

**본 툴킷을 재사용하는 시점에 버전이 변경되었을 수 있습니다 — `https://repo.amd.com/rocm/whl/<target>/`의 휠은 변경됩니다. 아래 방법은 버전에 의존하지 않습니다; 예제 명령의 URL은 설명용입니다.**

## 방법 (6단계)

### 단계 0 — 사전 준비

1. **드라이버**: AMD Adrenalin PRO / Adrenalin (최신 WHQL) 설치. 두 GPU를 사용자 모드에 노출하고 `hipInfo` 데이터를 제공합니다.
2. **HIP SDK 7.1.0** (또는 현재 버전): 8개 컴포넌트 모두 설치. 기본 설치 경로는 `C:\Program Files\AMD\ROCm\7.1\`.
3. **Python 3.12.x** (시스템, 예: `C:\Program Files\Python312`).
4. **VS 2022 BuildTools** (C++ 워크로드 + Windows SDK), 경로 `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\`. dGPU C++ 컴파일이 필요할 때만 필수.
5. `hipInfo.exe`를 (`C:\Program Files\AMD\ROCm\7.1\bin\`에서) 실행하고 **각 디바이스의 `gcnArchName`을 기록**. 이것이 dGPU의 타겟입니다. 예:

   ```
   device#0  Name: AMD Radeon(TM) 8060S Graphics     gcnArchName: gfx1151   87.87 GB   <- Strix Halo iGPU
   device#1  Name: AMD Radeon RX 7900 XTX             gcnArchName: gfx1100   23.98 GB   <- RDNA3 dGPU
   ```

   **드라이버는 두 GPU를 모두 봅니다; 하나는 iGPU 타겟, 다른 하나는 dGPU 타겟입니다.**

### 단계 1 — iGPU venv (TheRock pip 휠)

이 단계에서는 iGPU 측을 설정합니다. 타겟 family는 iGPU의 `gcnArchName`에서 결정됩니다. **iGPU를 적절한 TheRock 휠 인덱스에 매핑하세요:**

| iGPU | 아키텍처 | TheRock 인덱스 |
|---|---|---|
| Strix Halo (Ryzen AI MAX 395) | gfx1151 | `gfx1151` |
| Strix Point (Ryzen AI HX 370/470) | gfx1155 | `gfx1151` 또는 `gfx12-generic` (AMD 제공 상황에 따라) |
| Phoenix (Ryzen 7040HS) | gfx1103 | `gfx110X-all` (광범위) |
| Rembrandt (Ryzen 6000) | gfx1103 | `gfx110X-all` |
| Van Gogh (Steam Deck) | gfx1035 | `gfx103X-all` |

잘 모를 경우 `https://repo.amd.com/rocm/whl/`을 방문하여 AMD가 휠을 제공하는 타겟을 확인하세요.

```powershell
$ErrorActionPreference = 'Stop'
$INDEX = 'https://repo.amd.com/rocm/whl/gfx1151/'    # <-- iGPU 타겟으로 설정
$VENV  = 'C:\rocm-sdk'
$PY    = 'C:\Program Files\Python312\python.exe'

# 1. venv 생성
& $PY -m venv $VENV\.venv
& "$VENV\.venv\Scripts\python.exe" -m pip install --upgrade pip wheel setuptools

# 2. 로컬 캐시에 휠 사전 다운로드
$cache = "$VENV\cache"
New-Item -ItemType Directory -Force -Path $cache | Out-Null
& $VENV\.venv\Scripts\python.exe -m pip download --no-deps --no-build-isolation `
    --index-url "$INDEX" --dest $cache `
    rocm_bootstrap rocm-sdk-core rocm-sdk-devel rocm-sdk-libraries-<당신의_타겟> rocm

# 3. 로컬 캐시에서 설치 (네트워크 불필요, 휠-찾기-못함 경쟁 회피)
& $VENV\.venv\Scripts\python.exe -m pip install --no-index --find-links $cache --no-build-isolation --no-cache-dir `
    rocm_bootstrap==0.1.0 rocm-sdk-core==<버전> rocm-sdk-devel=<버전> rocm-sdk-libraries-<당신의_타겟>==<버전>
& $VENV\.venv\Scripts\python.exe -m pip install --no-index --find-links $cache --no-build-isolation --no-cache-dir rocm

# 4. 스모크 테스트
& $VENV\.venv\Scripts\python.exe -m rocm_sdk version          # <버전>
& $VENV\.venv\Scripts\python.exe -m rocm_sdk targets          # iGPU 아키텍처
& $VENV\.venv\Scripts\python.exe -m rocm_sdk test            # 26/26 (Linux용 1개 skip)
& $VENV\.venv\bin\hipInfo.exe                                # 두 GPU 모두 나열, iGPU gcnArch 일치
```

**중요한 설치 순서**: 3개의 휠을 먼저 설치하고, 마지막에 `rocm` 메타 sdist를 설치. 메타 패키지가 import 가능한 `rocm_sdk` 모듈을 제공합니다 — 없으면 `python -m rocm_sdk`가 "No module named rocm_sdk" 오류를 냅니다.

### 단계 2 — iGPU 환경 재배선 (머신 스코프, UAC 필요)

```powershell
# 현재 환경 백업
[Environment]::GetEnvironmentVariables('User')    | Export-Clixml "$VENV\env-backup.xml"
[Environment]::GetEnvironmentVariables('Machine') | Export-Clixml "$VENV\env-backup-machine.xml"

# 사용자 스코프
[Environment]::SetEnvironmentVariable('HIP_PATH',  "$VENV\.venv\Lib\site-packages\_rocm_sdk_core", 'User')
[Environment]::SetEnvironmentVariable('LLVM_PATH', "$VENV\.venv\Lib\site-packages\_rocm_sdk_devel\lib\llvm", 'User')
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
$prepend = "$VENV\.venv\Scripts;$VENV\.venv\Lib\site-packages\_rocm_sdk_core\bin;$VENV\.venv\Lib\site-packages\_rocm_sdk_devel\lib\llvm\bin"
[Environment]::SetEnvironmentVariable('PATH', $prepend + ';' + $userPath, 'User')

# 머신 스코프 (UAC)
$msiPath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
Start-Process powershell -ArgumentList '-NoProfile','-Command',`
    "[Environment]::SetEnvironmentVariable('HIP_PATH','$VENV\.venv\Lib\site-packages\_rocm_sdk_core','Machine'); " + `
    "[Environment]::SetEnvironmentVariable('PATH','$VENV\.venv\Scripts;$VENV\.venv\Lib\site-packages\_rocm_sdk_core\bin;' + `$msiPath,'Machine')" `
    -Verb RunAs -Wait

# 새 셸에서 검증
Start-Process pwsh -ArgumentList '-NoProfile','-Command','Get-Command hipconfig,hipcc,rocm-sdk,clang | Select-Object Name,Source' -Wait -NoNewWindow
```

### 단계 3 — dGPU 환경 (HIP SDK, 온디맨드 활성화)

dGPU 측은 **별도의 venv가 필요하지 않습니다**. 시스템 HIP SDK 7.1.0이 이미 dGPU를 인식합니다. 활성화 스크립트는 단순히 iGPU venv의 `HIP_PATH` 섀도잉을 해제하고, HIP SDK의 `bin`/`lib`을 PATH 맨 앞에 추가합니다.

본 툴킷의 `activate-dgpu.ps1`과 `deactivate-dgpu.ps1`을 임의의 디렉터리(예: `C:\rocm-sdk-dgpu\`)에 배치하세요. 활성화 시 현재 환경을 스냅샷하고, 비활성화 시 복원합니다.

### 단계 4 — dGPU C++ 컴파일 (필요 시)

두 가지 패턴:

**패턴 A: 미리 빌드된 .exe 실행** (커널이 이미 컴파일됨). `activate-dgpu.ps1` 실행 후 `HIP_VISIBLE_DEVICES=1 my_program.exe`.

**패턴 B: 소스에서 컴파일**. HIP SDK 7.1.0의 `clang.exe`는 **MSVC 통합을 포함하지 않습니다**. 로컬의 Visual Studio BuildTools와 Windows SDK 경로를 알려줘야 합니다. 본 툴킷의 `dgpu-build-template.ps1`을 템플릿으로 사용하세요.

중요한 플래그: `--offload-arch=<당신의 dGPU 아키텍처>`. HIP SDK의 clang는 기본적으로 `gfx906`을 사용하므로, dGPU가 다른 경우 실행 시 "device kernel image is invalid" 오류가 발생합니다.

### 단계 5 — 검증

```powershell
# iGPU (기본 셸, 임의의 터미널)
& C:\rocm-sdk\.venv\Scripts\python.exe -m rocm_sdk test       # 26/26 (Linux용 1개 skip)

# dGPU (activate-dgpu.ps1 실행 후)
hipInfo                                                      # 두 디바이스
$env:HIP_VISIBLE_DEVICES = '1'; hipInfo                      # dGPU만
& C:\rocm-sdk-dgpu\vector_add.exe                            # 빌드된 커널, gfx1100
```

## 다른 하드웨어에 적용

| 하드웨어 | 변경 사항 | 불변 |
|---|---|---|
| **Strix Point (HX 370/470) iGPU (gfx1155)** | TheRock 인덱스: `gfx1151` (시도) 또는 `gfx12-generic` (가능 시); `-libraries-gfx1151` 필요할 수 있음 | 단계 1–5 동일 |
| **Rembrandt / Phoenix (gfx1103) iGPU** | TheRock 인덱스: `gfx110X-all`; `-libraries-gfx110x-all` | 단계 1–5 동일 |
| **RX 7600 XT (gfx1100) dGPU** | `--offload-arch=gfx1100`; HIP SDK 7.1.0이 이미 지원 | 단계 4만 |
| **RX 9070 / 9070 XT (RDNA 4, gfx1201) dGPU** | `--offload-arch=gfx1201`; HIP SDK가 gfx1201 지원 여부 확인 (7.1.0+ 업데이트 필요할 수 있음) | 단계 4만; HIP SDK 업그레이드 필요할 수 있음 |
| **RDNA 2 (gfx1031, 예: RX 6600) dGPU** | `--offload-arch=gfx1031`; HIP SDK 지원 확인 | 단계 4만 |
| **Visual Studio BuildTools 없음** | dGPU C++ 컴파일 불가; Python venv는 영향 없음 | 단계 4 실패, 런타임은 동작 |
| **시스템 HIP SDK 없음** | dGPU 폴백 없음; dGPU 타겟용 TheRock 휠만 있다면 단계 1과 같은 방식으로 TheRock dGPU venv 설치 | 해당 없음 |

## 핵심 제약 / 불변 조건

- **`gcnArchName`의 신뢰할 수 있는 출처는 드라이버**. 설정을 결정하기 전에 항상 각 ROCm 설치에서 `hipInfo`를 실행하여 타겟을 확인하세요.
- **드라이버 레벨 non-peer**: 두 GPU가 모두 보여도 AMD는 대부분의 iGPU/dGPU 쌍을 `non-peers`로 표시합니다 (예: Strix Halo + RX 7900 XTX, gfx1151 + gfx1100). GPU-GPU 직접 복사 불가. 호스트 메모리 경유 스테이징 필요.
- **TheRock sdist 플레이버**: `https://repo.amd.com/rocm/whl/<target>/`의 `rocm-7.X.tar.gz`는 **타겟 특정** (인덱스마다 MD5가 다름). 항상 libraries 휠과 **같은** 인덱스에서 sdist를 다운로드하세요.
- **휠 인덱스 캐시 오염**: `pip install --find-links`가 "No such file or directory: <abs_path>" 오류를 내면, 캐시에 남은 `*_index.html` 파일을 삭제하세요 — pip가 그것들을 `../` 상대 경로의 PEP 503 simple 페이지로 오인합니다.
- **HIP_PATH 섀도잉**: HIP SDK 7.1.0의 `hipconfig`는 환경에서 `HIP_PATH`를 읽습니다. iGPU venv가 `HIP_PATH`를 설정하면, HIP SDK의 `hipconfig`가 iGPU venv 경로를 보고합니다. 활성화 스크립트는 `HIP_PATH`를 지우고 HIP SDK 디렉터리를 가리켜야 합니다.
- **공백이 포함된 경로의 `hipcc.bat`은 작동하지 않음** (공백으로 토큰화됨). `--driver-mode=g++ --hip-link`로 `clang.exe`를 직접 호출하세요.

## 툴킷 파일 목록

```
C:\therock\rocm-dual-gpu-kit\
├── README.md                  <- 영어 (메인)
├── README.zh-CN.md            <- 중국어 간체
├── README.ja-JP.md            <- 일본어
├── README.ko-KR.md            <- 한국어 (본 파일)
├── LICENSE                    <- Apache License 2.0 (전문)
├── NOTICE                     <- 저작권 및 귀속
├── kit.json                   <- 툴킷 메타데이터
├── install-igpu-venv.ps1      <- 단계 1: 자동 감지 + 설치
├── rewire-igpu.ps1            <- 단계 2: 머신 스코프 환경 (UAC)
├── activate-dgpu.ps1          <- 단계 3: HIP SDK 활성화
├── deactivate-dgpu.ps1        <- 단계 3: 복원
├── dgpu-build-template.ps1    <- 단계 4: dGPU용 복제 및 커스터마이즈
├── detect-hardware.ps1        <- iGPU/dGPU + gcnArchName + HIP SDK 감지
└── validate.ps1               <- 단계 5: 엔드투엔드 스모크 테스트
```

## 라이선스 및 저작권

본 툴킷은 **Copyright 2026 cubecloud Limited (https://cubecloud.io)**이며, **Apache License, Version 2.0** 하에 라이선스됩니다.

전체 라이선스 전문은 [LICENSE](LICENSE)를, 상표 및 귀속 정보는 [NOTICE](NOTICE)를 참조하세요.

### 왜 Apache 2.0인가

| 이유 | cubecloud에 대한 이점 |
|---|---|
| AMD ROCm 및 TheRock과 동일한 라이선스 | 같은 생태계 내 라이선스 충돌 없음 |
| 명시적 특허 부여 + 보복 조항 | 다운스트림 사용자의 특허 소송으로부터 보호 |
| 관대한 라이선스: 상업용, 수정, 배포, 사적 사용 | cubecloud의 내부 상업적 사용을 막지 않음 |
| GPLv3 호환 | 다운스트림이 GPL로 재라이선스 가능 |
| 하드웨어/컴퓨팅 툴의 업계 표준 | 엔터프라이즈 사용자가 인식하고 신뢰 |
| 저작권 및 라이선스 보존 요구 | 모든 사본에 cubecloud 저작자 표시 유지 |
| 상표(AMD, Radeon 등)는 라이선스 부여 안 됨 | AMD 상표를 양도하지 않음; 사용법만 문서화 |

### 상표 / 귀속

- AMD, Radeon, ROCm, HIP, Adrenalin, Strix Halo, RDNA는 Advanced Micro Devices, Inc.의 상표입니다.
- 본 툴킷은 AMD와 제휴하지 않으며 AMD의 보증이나 후원을 받지 않습니다.
- "cubecloud" 및 "cubecloud.io"는 cubecloud Limited의 상표입니다.

### 제3자 컴포넌트 (본 툴킷은 재배포하지 않음)

본 툴킷은 ROCm, TheRock, HIP SDK 또는 AMD 바이너리를 포함하지 않습니다. AMD의 공식 설치 경로와 공식 Python 휠 인덱스를 가리키는 설정 / 오케스트레이션 계층입니다. 각 컴포넌트의 라이선스를 참조하세요.

| 컴포넌트 | 라이선스 | 출처 |
|---|---|---|
| AMD ROCm / TheRock | Apache 2.0 | https://github.com/ROCm/TheRock |
| AMD HIP SDK | MIT (AMD 설치 프로그램 EULA) | AMD 설치 프로그램 |
| Python 3.12 | PSF 라이선스 | https://www.python.org |
| Visual Studio BuildTools | Microsoft EULA | https://visualstudio.microsoft.com |

본 툴킷을 포크하거나 상업적으로 재사용할 경우, `cubecloud Limited` 저작권 표시, `LICENSE` 파일, `NOTICE` 파일을 보존해 주세요.
