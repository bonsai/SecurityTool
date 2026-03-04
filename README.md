# SecurityTool v1.1.0

Windows 向け **拡張システムメンテナンスツール** です。
従来のシステムジャンク・レジストリ修復機能に加え、**Docker**、**機械学習キャッシュ**、**追加のWindows保守機能** のスキャンとクリーンアップをサポートします。
C++ DLL をコアエンジンとし、PowerShell スクリプトから呼び出す構成になっています。

---

## アーキテクチャ

```
SecurityTool/
├── src/
│   └── SecurityEngine.cpp      # C++ コアエンジン（DLL ソース）
├── include/
│   └── SecurityEngine.h        # エクスポート関数・構造体定義
├── output/
│   └── SecurityEngine.dll      # コンパイル済み DLL (x64)
├── scripts/
│   ├── SecurityTool.ps1        # メイン PowerShell スクリプト (★拡張)
│   ├── KimuraSanCleanup.js     # (新規) LLM連携用スキル
│   ├── RegistryMonitor.ps1     # リアルタイム レジストリ監視
│   └── Install.ps1             # インストーラー
└── CMakeLists.txt              # CMake ビルド設定
```

### 処理フロー

```
PowerShell (.ps1)
    │
    ├─ Add-Type (P/Invoke) → SecurityEngine.dll (C++)
    │   ├── ScanJunkFiles()          → %TEMP%, ブラウザキャッシュ, ごみ箱など
    │   ├── CleanJunkFiles()         → ファイル削除
    │   ├── ScanRegistryIssues()     → 孤立したスタートアップ、アンインストール項目
    │   └── FixRegistryIssue()       → レジストリキー削除
    │
    └─ (New) Native PowerShell Functions
        ├── Cleanup-Docker()         → docker system prune, docker image prune など
        ├── Cleanup-Models()         → HuggingFace, Torch, Pip キャッシュ削除
        └── Cleanup-WindowsExtra()   → Windows Updateキャッシュ削除, ディスク最適化
```

---

## 機能一覧

### 1. システムジャンク スキャン・クリーンアップ (従来機能)

DLLベースの高速スキャン・削除機能です。

| カテゴリ | 対象パス |
|---|---|
| TempFiles | `%TEMP%` |
| WindowsTemp | `%WINDIR%\Temp` |
| Prefetch | `%WINDIR%\Prefetch` |
| BrowserCache | Chrome, Edge 等のキャッシュ |
| RecycleBin | ごみ箱 (`$RECYCLE.BIN`) |

### 2. レジストリ 問題検出・修復 (従来機能)

| 種別 | 説明 | 深刻度 |
|---|---|---|
| OrphanedStartup | スタートアップエントリが存在しないファイルを参照 | 中 |
| OrphanedUninstall | アンインストールエントリの参照先が存在しない | 低 |
| InvalidFileAssociation | ファイル拡張子の ProgId が存在しない | 中 |

### 3. (新規) 拡張クリーンアップ機能

PowerShellで実装された追加のクリーンアップ機能です。`-Action cleanup` と共に使用します。

| Target | 説明 | 安全対策 |
|---|---|---|
| `docker` | 不要なコンテナ、イメージ、ボリューム、ネットワークを削除 | `-DryRun`, `-Confirm` 対応 |
| `models` | HuggingFace, PyTorch, Pip 等の機械学習モデルキャッシュを削除 | `-DryRun`, `-Confirm` 対応 |
| `windows_extra` | Windows Update のダウンロードキャッシュ削除、ディスクの最適化 | `-DryRun`, `-Confirm` 対応 |

### 4. リアルタイム レジストリ監視 (`RegistryMonitor.ps1`)

スナップショット比較方式で主要なレジストリキーを定期監視します。

---

## 使用方法

### 前提条件

- Windows 10 / 11 (x64)
- PowerShell 5.1 以上
- 管理者権限推奨
- (拡張機能) `docker` を使用する場合は Docker Desktop が必要です。

### インストール

```powershell
# 管理者 PowerShell で実行
.\scripts\Install.ps1 -InstallDir "C:\SecurityTool"
```

### スキャン・修復実行

#### 従来のスキャン

```powershell
# ジャンクファイルとレジストリをスキャン
.\SecurityTool.ps1 -Action scan

# ジャンクファイルをクリーンアップ
.\SecurityTool.ps1 -Action clean -Target junk

# レジストリ問題を修復
.\SecurityTool.ps1 -Action fix
```

#### (新規) 拡張クリーンアップ

```powershell
# Dockerの不要ファイルをプレビュー表示 (実行はしない)
.\SecurityTool.ps1 -Action cleanup -Target docker -DryRun

# 機械学習モデルのキャッシュを対話的に確認しながら削除
.\SecurityTool.ps1 -Action cleanup -Target models -Confirm

# Windowsの追加メンテナンス項目をプレビュー
.\SecurityTool.ps1 -Action cleanup -Target windows_extra -DryRun

# すべてのクリーンアップ項目を非対話的に実行 (DLL機能 + 拡張機能)
.\SecurityTool.ps1 -Action cleanup -Target all
```

### (新規) LLM (Qwen Code) との連携

`scripts/KimuraSanCleanup.js` は、ローカルで実行されるLLM (例: Ollama + Qwen) のスキルとして利用できます。
これにより、自然言語でクリーンアップ処理を呼び出すことが可能になります。

**セットアップ例:**
1. Ollama等でQwen Codeモデルをローカルで実行します。
2. LLMエージェントのスキルとして `KimuraSanCleanup.js` を登録します。
3. スキル内の `scriptPath` をご自身の環境に合わせて修正します。

**実行例 (チャットUI):**
> 「木村さん、Dockerの掃除をプレビューして」

---

## ビルド方法

C++ DLL (`SecurityEngine.dll`) のビルド方法は従来通りです。

### CMake (推奨)

```bash
# MinGW環境の場合
cmake -B build -DCMAKE_TOOLCHAIN_FILE=mingw-toolchain.cmake
cmake --build build
```

---

## DLL エクスポート関数リファレンス

DLLのAPIに変更はありません。

| 関数 | 説明 |
|---|---|
| `ScanJunkFiles(buf, max)` | ジャンクファイルをスキャン |
| `CleanJunkFiles(items, n, freed)` | ジャンクファイルを削除 |
| `ScanRegistryIssues(buf, max)` | レジストリ問題をスキャン |
| `FixAllRegistryIssues(issues, n, fixed)` | 全問題を一括修復 |

---

## ライセンス

MIT License
