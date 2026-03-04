#Requires -Version 5.1
<#
.SYNOPSIS
    SecurityTool.ps1 - システムジャンク、レジストリ、追加コンポーネントの監視・修復ツール

.DESCRIPTION
    SecurityEngine.dll (C++) を P/Invoke で呼び出し、従来のジャンクファイル・レジストリ修復機能に加え、
    Docker、機械学習モデルキャッシュ、追加のWindows保守機能のスキャン・クリーンアップを提供します。

.PARAMETER Action
    scan       : スキャンのみ実行（デフォルト）
    cleanup    : ジャンクファイルや追加ターゲットをクリーンアップ
    fix        : レジストリ問題を修復
    full       : スキャン → クリーン → 修復 をすべて実行
    report     : スキャン結果を HTML レポートとして出力

.PARAMETER Target
    クリーンアップ対象を指定します (Actionがcleanupの場合のみ有効)。
    junk          : 従来のシステムジャンクファイル (デフォルト)
    docker        : Dockerの不要なコンテナ、イメージ、ボリューム
    models        : 機械学習モデルのキャッシュ (HuggingFace, Torch, Pip)
    windows_extra : Windows Updateキャッシュ、古いドライバなど
    all           : 上記すべてを対象

.PARAMETER DryRun
    処理を実行せず、プレビューのみ表示します。

.PARAMETER Confirm
    各クリーンアップ処理の前に実行確認を求めます。

.PARAMETER Aggressive
    より積極的なクリーンアップを実行します (例: Dockerビルドキャッシュ全体)。

.PARAMETER DllPath
    SecurityEngine.dll のパス（省略時はスクリプトと同じフォルダを検索）

.PARAMETER OutputDir
    レポート出力先ディレクトリ（デフォルト: スクリプトと同じフォルダ）

.EXAMPLE
    # Dockerのクリーンアップをプレビューのみ実行
    .\SecurityTool.ps1 -Action cleanup -Target docker -DryRun

    # MLキャッシュを対話的に確認しながら削除
    .\SecurityTool.ps1 -Action cleanup -Target models -Confirm

    # すべてのクリーンアップターゲットを非対話的に実行
    .\SecurityTool.ps1 -Action cleanup -Target all
#>

[CmdletBinding()]
param(
    [ValidateSet('scan','cleanup','fix','full','report')]
    [string]$Action = 'scan',

    [ValidateSet('junk', 'registry', 'docker', 'models', 'windows_extra', 'all')]
    [string]$Target = 'all',

    [switch]$DryRun,

    [switch]$Confirm,

    [switch]$Aggressive,

    [string]$DllPath = '',

    [string]$OutputDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# 定数・設定
# ============================================================
$TOOL_VERSION  = '1.1.0' # バージョンアップ
$MAX_JUNK      = 8192
$MAX_REG       = 4096
$SCRIPT_DIR    = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = "$env:USERPROFILE\Desktop\SecurityTool_Log_$(Get-Date -Format 'yyyyMMdd_HHmm').log"

if ([string]::IsNullOrEmpty($DllPath)) {
    # スクリプトの場所基準でDLLパスを解決
    $potentialPath = Join-Path $SCRIPT_DIR "..\output\SecurityEngine.dll"
    if(Test-Path $potentialPath) {
        $DllPath = $potentialPath
    } else {
        $DllPath = Join-Path $SCRIPT_DIR 'SecurityEngine.dll' # フォールバック
    }
}
if ([string]::IsNullOrEmpty($OutputDir)) {
    $OutputDir = $SCRIPT_DIR
}

# ============================================================
# カラー出力ヘルパー & ロギング
# ============================================================
function Log { 
    param([string]$msg, [string]$Level = 'Info')
    $logMsg = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $msg"
    Write-Host $logMsg
    $logMsg | Out-File $logFile -Append
}

function Write-Header([string]$msg) {
    $line = '=' * 60
    Log "`n$line" 'Header'
    Log "  $msg" 'Header'
    Log $line 'Header'
}

function Write-Step([string]$msg) {
    Log $msg 'Step'
}

function Write-OK([string]$msg) {
    Log $msg 'OK'
}

function Write-Warn([string]$msg) {
    Log $msg 'Warn'
}

function Write-Info([string]$msg) {
    Log $msg 'Detail'
}

# ============================================================
# DLL の P/Invoke 型定義 (既存のまま)
# ============================================================
function Initialize-DllTypes {
    param([string]$dllPath)

    if (-not (Test-Path $dllPath)) {
        throw "DLL が見つかりません: $dllPath"
    }

    # 構造体 JunkFileInfo
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct JunkFileInfo {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
    public string Path;
    public long SizeBytes;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
    public string Category;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct RegistryIssue {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 512)]
    public string KeyPath;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
    public string ValueName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
    public string IssueType;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 512)]
    public string Description;
    public int Severity;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct ScanSummary {
    public int JunkFileCount;
    public long TotalJunkBytes;
    public int RegistryIssueCount;
    public int CriticalIssues;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
    public string ScanTime;
}

public static class SecurityEngineNative {
    [DllImport(@"$($dllPath -replace '\\', '\\\\')", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    public static extern int ScanJunkFiles([Out] JunkFileInfo[] buffer, int maxCount);

    [DllImport(@"$($dllPath -replace '\\', '\\\\')", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CleanJunkFiles([In] JunkFileInfo[] items, int count, out long bytesFreed);

    [DllImport(@"$($dllPath -replace '\\', '\\\\')", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    public static extern long GetTotalJunkSize();

    [DllImport(@"$($dllPath -replace '\\', '\\\\')", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    public static extern int ScanRegistryIssues([Out] RegistryIssue[] buffer, int maxCount);

    [DllImport(@"$($dllPath -replace '\\', '\\\\')", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FixRegistryIssue([In] ref RegistryIssue issue);

    [DllImport(@"$($dllPath -replace '\\', '\\\\')", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FixAllRegistryIssues([In] RegistryIssue[] issues, int count, out int fixedCount);

    [DllImport(@"$($dllPath -replace '\\', '\\\\')", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetScanSummary(out ScanSummary summary);

    [DllImport(@"$($dllPath -replace '\\', '\\\\')", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr GetEngineVersion();

    [DllImport(@"$($dllPath -replace '\\', '\\\\')", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsAdminPrivilege();
}
"@ -Language CSharp
}

# ============================================================
# ユーティリティ関数
# ============================================================
function Format-Bytes([long]$bytes) {
    if ($bytes -ge 1GB) { return "{0:F2} GB" -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return "{0:F2} MB" -f ($bytes / 1MB) }
    if ($bytes -ge 1KB) { return "{0:F2} KB" -f ($bytes / 1KB) }
    return "$bytes B"
}

function Get-SeverityLabel([int]$sev) {
    switch ($sev) {
        3 { return '高' }
        2 { return '中' }
        1 { return '低' }
        default { return '不明' }
    }
}

# 新規: フォルダサイズ計算を共通化
function Get-FolderSizeMB {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    try {
        (Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue |
         Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum / 1MB
    } catch { 0 }
}

# ============================================================
# スキャン機能 (既存のまま)
# ============================================================
function Invoke-JunkScan {
    Write-Step "ジャンクファイルをスキャン中..."
    $buffer = New-Object JunkFileInfo[] $MAX_JUNK
    $count  = [SecurityEngineNative]::ScanJunkFiles($buffer, $MAX_JUNK)

    $results = @()
    for ($i = 0; $i -lt $count; $i++) {
        $results += $buffer[$i]
    }

    Write-OK "ジャンクファイル検出数: $count 件"

    # カテゴリ別集計
    $grouped = $results | Group-Object Category
    foreach ($g in $grouped) {
        $totalSize = ($g.Group | Measure-Object SizeBytes -Sum).Sum
        Write-Info ("[{0}] {1} 件  合計: {2}" -f $g.Name, $g.Count, (Format-Bytes $totalSize))
    }

    $totalBytes = ($results | Measure-Object SizeBytes -Sum).Sum
    Write-OK ("合計ジャンクサイズ: " + (Format-Bytes $totalBytes))

    return $results
}

function Invoke-RegistryScan {
    Write-Step "レジストリをスキャン中..."
    $buffer = New-Object RegistryIssue[] $MAX_REG
    $count  = [SecurityEngineNative]::ScanRegistryIssues($buffer, $MAX_REG)

    $results = @()
    for ($i = 0; $i -lt $count; $i++) {
        $results += $buffer[$i]
    }

    Write-OK "レジストリ問題検出数: $count 件"

    foreach ($issue in $results) {
        $sev = Get-SeverityLabel $issue.Severity
        Write-Info ("[深刻度:{0}] [{1}] {2}" -f $sev, $issue.IssueType, $issue.KeyPath)
        Write-Info ("  値名: {0}" -f $issue.ValueName)
        Write-Info ("  説明: {0}" -f $issue.Description)
    }

    return $results
}

# ============================================================
# クリーンアップ機能 (既存)
# ============================================================
function Invoke-JunkClean([array]$junkItems) {
    if ($junkItems.Count -eq 0) {
        Write-Warn "クリーンアップ対象がありません"
        return 0
    }

    Write-Step ("ジャンクファイルをクリーンアップ中... ({0} 件)" -f $junkItems.Count)

    $arr = [JunkFileInfo[]]$junkItems
    [long]$freed = 0
    $ok = [SecurityEngineNative]::CleanJunkFiles($arr, $arr.Length, [ref]$freed)

    if ($ok) {
        Write-OK ("クリーンアップ完了: " + (Format-Bytes $freed) + " 解放")
    } else {
        Write-Warn "クリーンアップ中にエラーが発生しました"
    }
    return $freed
}

# ============================================================
# レジストリ修復機能 (既存)
# ============================================================
function Invoke-RegistryFix([array]$issues) {
    if ($issues.Count -eq 0) {
        Write-Warn "修復対象のレジストリ問題がありません"
        return 0
    }

    Write-Step ("レジストリ問題を修復中... ({0} 件)" -f $issues.Count)

    $arr = [RegistryIssue[]]$issues
    [int]$fixedCount = 0
    $ok = [SecurityEngineNative]::FixAllRegistryIssues($arr, $arr.Length, [ref]$fixedCount)

    if ($ok) {
        Write-OK ("修復完了: $fixedCount 件を修復しました")
    } else {
        Write-Warn "修復中にエラーが発生しました"
    }
    return $fixedCount
}

# ============================================================
# 新規: 追加クリーンアップ機能
# ============================================================

# Dockerクリーンアップ機能
function Cleanup-Docker {
    if (!(Get-Command docker -ErrorAction SilentlyContinue)) { 
        Write-Warn "Dockerが見つかりません。スキップ。"
        return 
    }
    
    Write-Step "Docker クリーンアップ プレビュー"
    $dockerDf = docker system df --format "{{.Type}}\t{{.TotalSize}}\t{{.Reclaimable}}"
    $dockerDf | ForEach-Object { Write-Info $_ }

    if ($Confirm) {
        $proceed = Read-Host "Docker不要ファイルを削除しますか？ (Y/N)"
        if ($proceed -notin 'Y','y') { 
            Write-Warn "Dockerクリーンアップをスキップしました。"
            return 
        }
    }

    if (-not $DryRun) {
        Write-Step "→ 実行: container prune"
        docker container prune -f 2>&1 | ForEach-Object { Write-Info $_ }
        
        Write-Step "→ 実行: image prune"
        docker image prune -f 2>&1 | ForEach-Object { Write-Info $_ }
        
        Write-Step "→ 実行: volume prune"
        docker volume prune -f 2>&1 | ForEach-Object { Write-Info $_ }
        
        if ($Aggressive) {
            Write-Step "→ Aggressive: builder prune 全キャッシュ"
            docker builder prune -a -f 2>&1 | ForEach-Object { Write-Info $_ }
        }
        Write-OK "Dockerのクリーンアップが完了しました。"
    } else {
        Write-OK "[DryRun] Docker操作はスキップされました。"
    }
}

# ML/モデルキャッシュクリーンアップ機能
function Cleanup-Models {
    Write-Step "ML/モデルキャッシュ プレビュー"
    $mlPaths = @(
        "$env:USERPROFILE\.cache\huggingface",
        "$env:USERPROFILE\.cache\torch",
        "$env:USERPROFILE\.cache\pip",
        "$env:USERPROFILE\.cache\wandb",
        "$env:USERPROFILE\.cache\mlflow"
    )
    $totalMb = 0
    foreach ($p in $mlPaths) {
        $size = Get-FolderSizeMB $p
        if ($size -gt 0) { Write-Info ("$p : {0:N2} MB" -f $size) }
        $totalMb += $size
    }
    Write-OK ("合計予定削除サイズ: {0:N2} MB" -f $totalMb)

    if ($totalMb -lt 10) { 
        Write-Info "削除対象が10MB未満のため、処理をスキップします。"
        return
    }

    if ($Confirm) {
        $proceed = Read-Host "MLキャッシュを削除しますか？ (Y/N)"
        if ($proceed -notin 'Y','y') { 
            Write-Warn "MLキャッシュのクリーンアップをスキップしました。"
            return
        }
    }

    if (-not $DryRun) {
        foreach ($p in $mlPaths) {
            if (Test-Path $p) {
                Write-Step "削除: $p"
                Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Write-OK "MLキャッシュのクリーンアップが完了しました。"
    } else {
        Write-OK "[DryRun] MLキャッシュの削除はスキップされました。"
    }
}

# 拡張Windows保守機能
function Cleanup-WindowsExtra {
    Write-Step "拡張Windows保守 プレビュー"
    
    $wuPath = "C:\Windows\SoftwareDistribution\Download"
    $wuMb = Get-FolderSizeMB $wuPath
    Write-Info ("Windows Update ダウンロードキャッシュ: {0:N2} MB" -f $wuMb)

    # DriverStoreは全削除が危険なため、プレビューのみに留め、手動操作を促す
    Write-Info "DriverStore全体サイズは計算しません。必要に応じて `pnputil /enum-drivers` で確認してください。"

    if ($Confirm) {
        $proceed = Read-Host "Windows Updateキャッシュなどを削除しますか？ (Y/N)"
        if ($proceed -notin 'Y','y') { 
            Write-Warn "拡張Windows保守をスキップしました。"
            return
        }
    }

    if (-not $DryRun) {
        Write-Step "→ Windows Update キャッシュ削除"
        try {
            Stop-Service -Name wuauserv -Force -ErrorAction Stop
            Remove-Item "$wuPath\*" -Recurse -Force -ErrorAction SilentlyContinue
        } finally {
            Start-Service -Name wuauserv -ErrorAction SilentlyContinue
        }

        Write-Step "→ ディスク最適化 (C:)"
        Optimize-Volume -DriveLetter C -ReTrim -Verbose 4>&1 | ForEach-Object { Write-Info $_ }
        
        Write-OK "拡張Windows保守が完了しました。"
    } else {
        Write-OK "[DryRun] 拡張Windows保守はスキップされました。"
    }
}

# ============================================================
# HTML レポート生成 (既存のまま)
# ============================================================
function New-HtmlReport {
    param(
        [array]$JunkItems,
        [array]$RegIssues,
        [long]$FreedBytes,
        [int]$FixedCount,
        [string]$OutDir
    )

    $timestamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
    $reportFile  = Join-Path $OutDir "SecurityReport_$timestamp.html"
    $scanTime    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    $totalJunk   = ($JunkItems | Measure-Object SizeBytes -Sum).Sum
    $criticalReg = ($RegIssues | Where-Object { $_.Severity -ge 3 }).Count

    # カテゴリ別ジャンク集計
    $junkGrouped = $JunkItems | Group-Object Category | Sort-Object Count -Descending
    $junkTableRows = ($junkGrouped | ForEach-Object {
        $sz = ($_.Group | Measure-Object SizeBytes -Sum).Sum
        "<tr><td>$($_.Name)</td><td>$($_.Count)</td><td>$(Format-Bytes $sz)</td></tr>"
    }) -join "`n"

    # レジストリ問題テーブル
    $regTableRows = ($RegIssues | ForEach-Object {
        $sevLabel = Get-SeverityLabel $_.Severity
        $sevColor = switch ($_.Severity) { 3 {'#ff4444'} 2 {'#ffaa00'} default {'#44bb44'} }
        "<tr>
            <td style='color:$sevColor;font-weight:bold'>$sevLabel</td>
            <td>$($_.IssueType)</td>
            <td>$($_.KeyPath)</td>
            <td>$($_.ValueName)</td>
            <td>$($_.Description)</td>
        </tr>"
    }) -join "`n"

    $html = @"
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>SecurityTool スキャンレポート</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Segoe UI', Meiryo, sans-serif; background: #0f1117; color: #e0e0e0; padding: 24px; }
  h1 { font-size: 1.8em; color: #00d4ff; margin-bottom: 4px; }
  .subtitle { color: #888; font-size: 0.9em; margin-bottom: 24px; }
  .summary-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; margin-bottom: 32px; }
  .card { background: #1a1d2e; border-radius: 12px; padding: 20px; text-align: center; border: 1px solid #2a2d3e; }
  .card .value { font-size: 2.2em; font-weight: bold; color: #00d4ff; }
  .card .label { font-size: 0.85em; color: #888; margin-top: 6px; }
  .card.warn .value { color: #ffaa00; }
  .card.danger .value { color: #ff4444; }
  .card.ok .value { color: #44bb44; }
  section { margin-bottom: 32px; }
  h2 { font-size: 1.2em; color: #00d4ff; border-bottom: 1px solid #2a2d3e; padding-bottom: 8px; margin-bottom: 16px; }
  table { width: 100%; border-collapse: collapse; font-size: 0.88em; }
  th { background: #1a1d2e; color: #00d4ff; padding: 10px 12px; text-align: left; }
  td { padding: 8px 12px; border-bottom: 1px solid #1a1d2e; }
  tr:hover td { background: #1a1d2e; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 0.8em; font-weight: bold; }
  .footer { color: #555; font-size: 0.8em; margin-top: 32px; text-align: center; }
</style>
</head>
<body>
<h1>SecurityTool スキャンレポート</h1>
<div class="subtitle">スキャン日時: $scanTime &nbsp;|&nbsp; バージョン: $TOOL_VERSION</div>

<div class="summary-grid">
  <div class="card warn">
    <div class="value">$($JunkItems.Count)</div>
    <div class="label">ジャンクファイル</div>
  </div>
  <div class="card warn">
    <div class="value">$(Format-Bytes $totalJunk)</div>
    <div class="label">ジャンク合計サイズ</div>
  </div>
  <div class="card $(if($criticalReg -gt 0){'danger'}else{'warn'})" >
    <div class="value">$($RegIssues.Count)</div>
    <div class="label">レジストリ問題</div>
  </div>
  <div class="card ok">
    <div class="value">$FixedCount</div>
    <div class="label">修復済み</div>
  </div>
</div>

<section>
  <h2>ジャンクファイル カテゴリ別集計</h2>
  <table>
    <tr><th>カテゴリ</th><th>ファイル数</th><th>合計サイズ</th></tr>
    $junkTableRows
  </table>
</section>

<section>
  <h2>レジストリ問題一覧</h2>
  $(if($RegIssues.Count -eq 0) {
    '<p style="color:#44bb44">問題は検出されませんでした。</p>'
  } else {
    "<table>
      <tr><th>深刻度</th><th>種別</th><th>キーパス</th><th>値名</th><th>説明</th></tr>
      $regTableRows
    </table>"
  })
</section>

<div class="footer">Generated by SecurityTool v$TOOL_VERSION &copy; 2026</div>
</body>
</html>
"@

    $html | Out-File -FilePath $reportFile -Encoding UTF8
    return $reportFile
}

# ============================================================
# メイン処理
# ============================================================
Write-Header "SecurityTool v$TOOL_VERSION - 拡張システムメンテナンスツール"

# 管理者権限チェック
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warn "管理者権限なしで実行中です。一部の機能が制限される場合があります。"
} else {
    Write-OK "管理者権限で実行中"
}

# DLL 型定義の読み込み (従来機能で必要な場合)
if ($Action -in 'scan', 'clean', 'fix', 'full', 'report' -and $Target -in 'junk', 'registry', 'all') {
    Write-Step "SecurityEngine.dll を読み込み中: $DllPath"
    try {
        Initialize-DllTypes -dllPath $DllPath
        Write-OK "DLL 読み込み完了"
    } catch {
        Write-Warn "DLL 読み込みエラー: $_"
        Write-Warn "DLL が Windows 環境に存在することを確認してください。"
        # DLL必須のアクションでなければ続行
        if ($Target -in 'junk', 'registry') { exit 1 }
    }
}

# アクション実行
$junkItems = @()
$regIssues = @()
$freedBytes = 0
$fixedCount = 0

switch ($Action) {
    'scan' {
        $junkItems = Invoke-JunkScan
        $regIssues = Invoke-RegistryScan
    }
    'cleanup' {
        Write-Step "クリーンアップ開始 - Target: $Target | DryRun: $DryRun | Confirm: $Confirm | Aggressive: $Aggressive"
        if ($Target -in "all", "junk") { 
            $junkItems = Invoke-JunkScan
            $freedBytes = Invoke-JunkClean $junkItems
        }
        if ($Target -in "all", "docker") { Cleanup-Docker }
        if ($Target -in "all", "models") { Cleanup-Models }
        if ($Target -in "all", "windows_extra") { Cleanup-WindowsExtra }
    }
    'fix' {
        $regIssues = Invoke-RegistryScan
        $fixedCount = Invoke-RegistryFix $regIssues
    }
    'full' {
        $junkItems  = Invoke-JunkScan
        $regIssues  = Invoke-RegistryScan
        $freedBytes = Invoke-JunkClean $junkItems
        $fixedCount = Invoke-RegistryFix $regIssues
        Cleanup-Docker
        Cleanup-Models
        Cleanup-WindowsExtra
    }
    'report' {
        $junkItems = Invoke-JunkScan
        $regIssues = Invoke-RegistryScan
        $reportPath = New-HtmlReport `
            -JunkItems  $junkItems `
            -RegIssues  $regIssues `
            -FreedBytes $freedBytes `
            -FixedCount $fixedCount `
            -OutDir     $OutputDir
        Write-OK "HTMLレポートを生成しました: $reportPath"
    }
}

Write-Header "処理完了"
Write-OK "アクション '$Action' が正常に完了しました。詳細はログファイルを確認してください: $logFile"
