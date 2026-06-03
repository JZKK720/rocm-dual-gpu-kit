<!--
  rocm-dual-gpu-kit
  Copyright 2026 cubecloud Limited (https://cubecloud.io)
  SPDX-License-Identifier: Apache-2.0
-->

# ROCm デュアル GPU セットアップ — 方法とツールキット

**Copyright 2026 cubecloud Limited (https://cubecloud.io)** · [Apache License 2.0](LICENSE) の下でライセンス

本ツールキットは **Option 2** デュアル GPU パターンを再現します。対応ハードウェア：

- **iGPU**（Strix Halo gfx1151、Strix Point gfx1155、Phoenix gfx1103、Rembrandt gfx1103、Van Gogh gfx1035 など）— **TheRock pip wheels** を使用
- **dGPU**（Navi 31/32/33 = gfx1100/1101/1102、RDNA 4 = gfx1200/1201 など）— **システム HIP SDK** を使用

レシピは以下の環境で開発・検証されました：
- AMD Adrenalin ドライバ 32.0.31019.2002（Windows）
- AMD HIP SDK 7.1.0（`C:\Program Files\AMD\ROCm\7.1\`）
- TheRock Python ホイール（`https://repo.amd.com/rocm/whl/<target>/`、本ドキュメント執筆時点で 7.13.0）
- Python 3.12.10（システム）
- Visual Studio 2022 BuildTools（C++ ワークロード、Windows SDK 10.0.26100）

**ディスク使用量**：TheRock 仮想環境あたり約 22 GB、HIP SDK  約 3 GB。dGPU 側は HIP SDK を再利用し、iGPU 側は仮想環境で動作。

**本ツールキットを再利用する時点でバージョンが更新されている可能性があります。`https://repo.amd.com/rocm/whl/<target>/` のホイールは更新されます。下記メソッドはバージョンに依存しません。サンプルコマンドの URL は説明用です。**

## メソッド（6 フェーズ）

### フェーズ 0 — 事前準備

1. **ドライバ**：AMD Adrenalin PRO / Adrenalin（最新 WHQL）をインストール。両方の GPU をユーザーモードに公開し、`hipInfo` データを提供します。
2. **HIP SDK 7.1.0**（または現行版）：8 つのコンポーネントをすべてインストール。デフォルトのインストール先は `C:\Program Files\AMD\ROCm\7.1\`。
3. **Python 3.12.x**（システム、例：`C:\Program Files\Python312`）。
4. **VS 2022 BuildTools**（C++ ワークロード + Windows SDK）、`C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\`。dGPU の C++ コンパイルを行う場合のみ必須。
5. `hipInfo.exe`（`C:\Program Files\AMD\ROCm\7.1\bin\`）を実行し、**各デバイスの `gcnArchName` を記録**。これが dGPU のターゲットです。例：

   ```
   device#0  Name: AMD Radeon(TM) 8060S Graphics     gcnArchName: gfx1151   87.87 GB   <- Strix Halo iGPU
   device#1  Name: AMD Radeon RX 7900 XTX             gcnArchName: gfx1100   23.98 GB   <- RDNA3 dGPU
   ```

   **ドライバは両方の GPU を見えます；一方が iGPU ターゲット、もう一方が dGPU ターゲットです。**

### フェーズ 1 — iGPU 仮想環境（TheRock pip ホイール）

このフェーズでは iGPU 側をセットアップします。ターゲット family は iGPU の `gcnArchName` から決まります。**iGPU を適切な TheRock ホイールインデックスにマッピングしてください：**

| iGPU | アーキテクチャ | TheRock インデックス |
|---|---|---|
| Strix Halo（Ryzen AI MAX 395） | gfx1151 | `gfx1151` |
| Strix Point（Ryzen AI HX 370/470） | gfx1155 | `gfx1151` または `gfx12-generic`（AMD 提供状況による） |
| Phoenix（Ryzen 7040HS） | gfx1103 | `gfx110X-all`（広範） |
| Rembrandt（Ryzen 6000） | gfx1103 | `gfx110X-all` |
| Van Gogh（Steam Deck） | gfx1035 | `gfx103X-all` |

不明な場合は `https://repo.amd.com/rocm/whl/` を確認し、AMD がホイールを提供しているターゲットを確認してください。

```powershell
$ErrorActionPreference = 'Stop'
$INDEX = 'https://repo.amd.com/rocm/whl/gfx1151/'    # <-- iGPU ターゲットに設定
$VENV  = 'C:\rocm-sdk'
$PY    = 'C:\Program Files\Python312\python.exe'

# 1. 仮想環境の作成
& $PY -m venv $VENV\.venv
& "$VENV\.venv\Scripts\python.exe" -m pip install --upgrade pip wheel setuptools

# 2. ローカルキャッシュへホイールを事前ダウンロード
$cache = "$VENV\cache"
New-Item -ItemType Directory -Force -Path $cache | Out-Null
& $VENV\.venv\Scripts\python.exe -m pip download --no-deps --no-build-isolation `
    --index-url "$INDEX" --dest $cache `
    rocm_bootstrap rocm-sdk-core rocm-sdk-devel rocm-sdk-libraries-<あなたのターゲット> rocm

# 3. ローカルキャッシュからインストール（ネットワーク不要、ホイール未発見競合を回避）
& $VENV\.venv\Scripts\python.exe -m pip install --no-index --find-links $cache --no-build-isolation --no-cache-dir `
    rocm_bootstrap==0.1.0 rocm-sdk-core==<バージョン> rocm-sdk-devel=<バージョン> rocm-sdk-libraries-<あなたのターゲット>==<バージョン>
& $VENV\.venv\Scripts\python.exe -m pip install --no-index --find-links $cache --no-build-isolation --no-cache-dir rocm

# 4. スモークテスト
& $VENV\.venv\Scripts\python.exe -m rocm_sdk version          # <バージョン>
& $VENV\.venv\Scripts\python.exe -m rocm_sdk targets          # iGPU アーキテクチャ
& $VENV\.venv\Scripts\python.exe -m rocm_sdk test            # 26/26（Linux 用 1 件 skip）
& $VENV\.venv\bin\hipInfo.exe                                # 両方の GPU を列挙、iGPU の gcnArch が一致
```

**重要なインストール順序**：3 つのホイールを先にインストールし、最後に `rocm` メタ sdist をインストール。メタパッケージが import 可能な `rocm_sdk` モジュールを提供します — これがないと `python -m rocm_sdk` は "No module named rocm_sdk" エラーになります。

### フェーズ 2 — iGPU 環境再配線（マシンスコープ、UAC 必要）

```powershell
# 現在の環境をバックアップ
[Environment]::GetEnvironmentVariables('User')    | Export-Clixml "$VENV\env-backup.xml"
[Environment]::GetEnvironmentVariables('Machine') | Export-Clixml "$VENV\env-backup-machine.xml"

# ユーザースコープ
[Environment]::SetEnvironmentVariable('HIP_PATH',  "$VENV\.venv\Lib\site-packages\_rocm_sdk_core", 'User')
[Environment]::SetEnvironmentVariable('LLVM_PATH', "$VENV\.venv\Lib\site-packages\_rocm_sdk_devel\lib\llvm", 'User')
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
$prepend = "$VENV\.venv\Scripts;$VENV\.venv\Lib\site-packages\_rocm_sdk_core\bin;$VENV\.venv\Lib\site-packages\_rocm_sdk_devel\lib\llvm\bin"
[Environment]::SetEnvironmentVariable('PATH', $prepend + ';' + $userPath, 'User')

# マシンスコープ（UAC）
$msiPath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
Start-Process powershell -ArgumentList '-NoProfile','-Command',`
    "[Environment]::SetEnvironmentVariable('HIP_PATH','$VENV\.venv\Lib\site-packages\_rocm_sdk_core','Machine'); " + `
    "[Environment]::SetEnvironmentVariable('PATH','$VENV\.venv\Scripts;$VENV\.venv\Lib\site-packages\_rocm_sdk_core\bin;' + `$msiPath,'Machine')" `
    -Verb RunAs -Wait

# 新しいシェルで検証
Start-Process pwsh -ArgumentList '-NoProfile','-Command','Get-Command hipconfig,hipcc,rocm-sdk,clang | Select-Object Name,Source' -Wait -NoNewWindow
```

### フェーズ 3 — dGPU 環境（HIP SDK、オンデマンド有効化）

dGPU 側は **仮想環境を必要としません**。システム HIP SDK 7.1.0 がすでに dGPU を認識します。有効化スクリプトは iGPU 仮想環境の `HIP_PATH` シャドウをクリアし、HIP SDK の `bin`/`lib` を PATH の先頭に追加するだけです。

本ツールキットの `activate-dgpu.ps1` と `deactivate-dgpu.ps1` を任意のディレクトリ（例：`C:\rocm-sdk-dgpu\`）に配置してください。有効化時に現在の環境をスナップショットし、無効化時に復元します。

### フェーズ 4 — dGPU C++ コンパイル（必要な場合）

2 つのパターン：

**パターン A：ビルド済み .exe を実行**（カーネル既にコンパイル済み）。`activate-dgpu.ps1` を実行し、`HIP_VISIBLE_DEVICES=1 my_program.exe`。

**パターン B：ソースからコンパイル**。HIP SDK 7.1.0 の `clang.exe` には **MSVC 統合が含まれていません**。ローカルの Visual Studio BuildTools と Windows SDK のパスを指定する必要があります。本ツールキットの `dgpu-build-template.ps1` をテンプレートとしてご利用ください。

重要なフラグ：`--offload-arch=<あなたの dGPU アーキテクチャ>`。HIP SDK の clang はデフォルトで `gfx906` を使うため、dGPU がそれ以外だと実行時に "device kernel image is invalid" が発生します。

### フェーズ 5 — 検証

```powershell
# iGPU（デフォルトシェル、任意のターミナル）
& C:\rocm-sdk\.venv\Scripts\python.exe -m rocm_sdk test       # 26/26（Linux 用 1 件 skip）

# dGPU（activate-dgpu.ps1 実行後）
hipInfo                                                      # 両デバイス
$env:HIP_VISIBLE_DEVICES = '1'; hipInfo                      # dGPU のみ
& C:\rocm-sdk-dgpu\vector_add.exe                            # ビルド済みカーネル、gfx1100
```

## 他のハードウェアへの適応

| ハードウェア | 変更内容 | 不変 |
|---|---|---|
| **Strix Point（HX 370/470）iGPU（gfx1155）** | TheRock インデックス：`gfx1151`（試行）または `gfx12-generic`（利用可能な場合）；`-libraries-gfx1151` が必要な場合あり | フェーズ 1–5 同じ |
| **Rembrandt / Phoenix（gfx1103）iGPU** | TheRock インデックス：`gfx110X-all`；`-libraries-gfx110x-all` | フェーズ 1–5 同じ |
| **RX 7600 XT（gfx1100）dGPU** | `--offload-arch=gfx1100`；HIP SDK 7.1.0 は既にサポート | フェーズ 4 のみ |
| **RX 9070 / 9070 XT（RDNA 4、gfx1201）dGPU** | `--offload-arch=gfx1201`；HIP SDK 7.1.0+ が gfx1201 をサポートするか確認 | フェーズ 4 のみ；HIP SDK のアップグレードが必要な場合あり |
| **RDNA 2（gfx1031、例：RX 6600）dGPU** | `--offload-arch=gfx1031`；HIP SDK のサポートを確認 | フェーズ 4 のみ |
| **Visual Studio BuildTools がない** | dGPU C++ コンパイルは不可；Python 仮想環境側は影響なし | フェーズ 4 失敗、ランタイムは動作 |
| **システム HIP SDK がない** | dGPU 側にフォールバックなし；dGPU ターゲット用の TheRock ホイールしかない場合は、フェーズ 1 と同じ方法で TheRock dGPU 仮想環境をインストール | 該当なし |

## 重要な制約 / 不変条件

- **`gcnArchName` の信頼できる情報源はドライバ**。セットアップを決める前に、必ず各 ROCm インストールから `hipInfo` を実行してターゲットを確認してください。
- **ドライバレベル non-peer**：両方の GPU が見えても、AMD はほとんどの iGPU/dGPU ペアを `non-peers` としてマークします（例：Strix Halo + RX 7900 XTX、gfx1151 + gfx1100）。GPU-GPU 直接コピーは不可。ホストメモリ経由でのステージングが必要。
- **TheRock sdist のフレーバー**：`https://repo.amd.com/rocm/whl/<target>/` の `rocm-7.X.tar.gz` は**ターゲット固有**（インデックスごとに MD5 が異なる）。必ず libraries ホイールと**同じ**インデックスから sdist をダウンロードしてください。
- **ホイールインデックスのキャッシュ汚染**：`pip install --find-links` が "No such file or directory: <abs_path>" を出す場合、キャッシュに残った `*_index.html` ファイルを削除してください — pip はそれらを `../` 相対パスを持つ PEP 503 simple ページと誤認します。
- **HIP_PATH のシャドウイング**：HIP SDK 7.1.0 の `hipconfig` は環境から `HIP_PATH` を読みます。iGPU 仮想環境が `HIP_PATH` を設定していると、HIP SDK の `hipconfig` は iGPU 仮想環境の経路を報告します。有効化スクリプトは `HIP_PATH` をクリアし、HIP SDK ディレクトリを指すように設定する必要があります。
- **パスに空白を含む `hipcc.bat` は動作しない**（空白でトークン化される）。`--driver-mode=g++ --hip-link` を指定して `clang.exe` を直接呼び出してください。

## ツールキット内のファイル

```
C:\therock\rocm-dual-gpu-kit\
├── README.md                  <- 英語版（メイン）
├── README.zh-CN.md            <- 簡体字中国語
├── README.ja-JP.md            <- 日本語（本ファイル）
├── README.ko-KR.md            <- 韓国語
├── LICENSE                    <- Apache License 2.0（全文）
├── NOTICE                     <- 著作権・帰属
├── kit.json                   <- ツールキットメタデータ
├── install-igpu-venv.ps1      <- フェーズ 1：自動検出 + インストール
├── rewire-igpu.ps1            <- フェーズ 2：マシンスコープ環境（UAC）
├── activate-dgpu.ps1          <- フェーズ 3：HIP SDK 有効化
├── deactivate-dgpu.ps1        <- フェーズ 3：復元
├── dgpu-build-template.ps1    <- フェーズ 4：あなたの dGPU 用にクローンして編集
├── detect-hardware.ps1        <- iGPU/dGPU + gcnArchName + HIP SDK の検出
└── validate.ps1               <- フェーズ 5：エンドツーエンドスモークテスト
```

## ライセンスと著作権

本ツールキットは **Copyright 2026 cubecloud Limited (https://cubecloud.io)** であり、**Apache License, Version 2.0** の下でライセンスされています。

完全なライセンス条項は [LICENSE](LICENSE) を、商標・帰属情報は [NOTICE](NOTICE) を参照してください。

### なぜ Apache 2.0 か

| 理由 | cubecloud への利点 |
|---|---|
| AMD ROCm や TheRock と同じライセンス | 同じエコシステム内でライセンスの不整合がない |
| 明示的な特許付与 + 反訴条項 | 下流ユーザーからの特許訴訟から身を守る |
| 寛容なライセンス：商用・改変・配布・私的使用 | cubecloud が本ツールキットを内部で商用利用するのを妨げない |
| GPLv3 互換 | 下流は GPL で再ライセンス可能 |
| ハードウェア/計算ツールの業界標準 | エンタープライズユーザーに認知・信頼されている |
| 著作権とライセンスの保持を要求 | すべてのコピーとフォークに cubecloud の著者性が保持される |
| 商標（AMD、Radeon など）はライセンス対象外 | AMD の商標を他者に譲渡しない；その使い方を文書化するだけ |

### 商標 / 帰属

- AMD、Radeon、ROCm、HIP、Adrenalin、Strix Halo、RDNA は Advanced Micro Devices, Inc. の商標です。
- 本ツールキットは AMD とは無関係であり、AMD の承認や支援を受けたものではありません。
- 「cubecloud」および「cubecloud.io」は cubecloud Limited の商標です。

### 第三者コンポーネント（本ツールキットでは再配布していません）

本ツールキットは ROCm、TheRock、HIP SDK、その他の AMD バイナリを含みません。AMD 公式のインストールパスと公式の Python ホイールインデックスを指す設定 / オーケストレーション層です。各コンポーネントのライセンスを参照してください。

| コンポーネント | ライセンス | ソース |
|---|---|---|
| AMD ROCm / TheRock | Apache 2.0 | https://github.com/ROCm/TheRock |
| AMD HIP SDK | MIT（AMD インストーラー EULA 準拠） | AMD インストーラー |
| Python 3.12 | PSF ライセンス | https://www.python.org |
| Visual Studio BuildTools | Microsoft EULA | https://visualstudio.microsoft.com |

本ツールキットをフォークしたり商用で再利用したりする場合は、`cubecloud Limited` の著作権表示、`LICENSE` ファイル、`NOTICE` ファイルを保持してください。
