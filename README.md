# SecurityTool v1.0.0

Windows 向け **システムジャンク クリーンアップ** および **壊れたレジストリ 監視・修復** ツールです。
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
│   ├── SecurityTool.ps1        # メイン PowerShell スクリプト
│   ├── RegistryMonitor.ps1     # リアルタイム レジストリ監視
│   └── Install.ps1             # インストーラー
└── CMakeLists.txt              # CMake ビルド設定
```

### 処理フロー

```
PowerShell (.ps1)
    │  Add-Type (P/Invoke)
    ▼
SecurityEngine.dll (C++)
    ├── ScanJunkFiles()          → %TEMP%, Windows Temp, Prefetch, ブラウザキャッシュ, ごみ箱
    ├── CleanJunkFiles()         → DeleteFile / SHEmptyRecycleBin
    ├── ScanRegistryIssues()     → スタートアップ / アンインストール / ファイル関連付け
    ├── FixRegistryIssue()       → RegDeleteValue（孤立エントリ削除）
    └── GetScanSummary()         → 統合サマリー
```

---

## 機能一覧

### 1. システムジャンク スキャン・クリーンアップ

| カテゴリ | 対象パス |
|---|---|
| TempFiles | `%TEMP%` |
| WindowsTemp | `%WINDIR%\Temp` |
| Prefetch | `%WINDIR%\Prefetch` |
| BrowserCache_Chrome | `%LOCALAPPDATA%\Google\Chrome\...\Cache` |
| BrowserCache_Edge | `%LOCALAPPDATA%\Microsoft\Edge\...\Cache` |
| RecycleBin | ごみ箱 (`$RECYCLE.BIN`) |

### 2. レジストリ 問題検出・修復

| 種別 | 説明 | 深刻度 |
|---|---|---|
| OrphanedStartup | スタートアップエントリが存在しないファイルを参照 | 中 |
| OrphanedUninstall | アンインストールエントリの参照先が存在しない | 低 |
| InvalidFileAssociation | ファイル拡張子の ProgId が HKCR に存在しない | 中 |

### 3. リアルタイム レジストリ監視 (`RegistryMonitor.ps1`)

スナップショット比較方式で以下のキーを定期監視します:

- `HKLM\SOFTWARE\...\Run` / `RunOnce` (スタートアップ)
- `HKLM\SYSTEM\CurrentControlSet\Services` (サービス)
- `HKLM\SOFTWARE\...\Winlogon` (ログオン設定)
- `HKCU\SOFTWARE\...\FileExts` (ファイル関連付け)

---

## 使用方法

### 前提条件

- Windows 10 / 11 (x64)
- PowerShell 5.1 以上
- 管理者権限推奨（一部機能に必要）

### インストール

```powershell
# 管理者 PowerShell で実行
.\scripts\Install.ps1 -InstallDir "C:\SecurityTool" -ScheduleScan
```

### スキャン実行

```powershell
# スキャンのみ（デフォルト）
.\SecurityTool.ps1 -Action scan

# ジャンクファイルのクリーンアップ
.\SecurityTool.ps1 -Action clean

# レジストリ問題の修復
.\SecurityTool.ps1 -Action fix

# スキャン + クリーン + 修復 すべて実行
.\SecurityTool.ps1 -Action full

# HTML レポート生成
.\SecurityTool.ps1 -Action report -OutputDir C:\Reports
```

### リアルタイム監視

```powershell
# 5秒ごとに監視（デフォルト）
.\RegistryMonitor.ps1

# 10秒ごと + 変更時に通知
.\RegistryMonitor.ps1 -IntervalSeconds 10 -AlertOnChange
```

---

## ビルド方法

### Windows (MSVC)

```cmd
cl /LD src\SecurityEngine.cpp /DSECURITYENGINE_EXPORTS ^
   /I include ^
   /link advapi32.lib shlwapi.lib shell32.lib ^
   /OUT:output\SecurityEngine.dll
```

### Linux クロスコンパイル (MinGW)

```bash
x86_64-w64-mingw32-g++ -shared \
  -o output/SecurityEngine.dll \
  src/SecurityEngine.cpp \
  -I include \
  -DSECURITYENGINE_EXPORTS \
  -DWINVER=0x0601 -D_WIN32_WINNT=0x0601 \
  -ladvapi32 -lshlwapi -lshell32 \
  -static-libgcc -static-libstdc++ \
  -std=c++17
```

### CMake

```bash
cmake -B build -DCMAKE_TOOLCHAIN_FILE=mingw-toolchain.cmake
cmake --build build
```

---

## DLL エクスポート関数リファレンス

| 関数 | 説明 | 戻り値 |
|---|---|---|
| `ScanJunkFiles(buf, max)` | ジャンクファイルをスキャン | 検出件数 |
| `CleanJunkFiles(items, n, freed)` | ジャンクファイルを削除 | BOOL |
| `GetTotalJunkSize()` | ジャンク合計バイト数 | LONGLONG |
| `ScanRegistryIssues(buf, max)` | レジストリ問題をスキャン | 検出件数 |
| `FixRegistryIssue(issue)` | 1件のレジストリ問題を修復 | BOOL |
| `FixAllRegistryIssues(issues, n, fixed)` | 全問題を一括修復 | BOOL |
| `GetScanSummary(summary)` | スキャン結果サマリー取得 | BOOL |
| `GetEngineVersion()` | エンジンバージョン文字列 | const wchar_t* |
| `IsAdminPrivilege()` | 管理者権限チェック | BOOL |

---

## ライセンス

MIT License - 学習・研究・個人利用目的で自由に使用可能です。
