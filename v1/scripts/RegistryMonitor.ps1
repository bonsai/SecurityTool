#Requires -Version 5.1
<#
.SYNOPSIS
    RegistryMonitor.ps1 - リアルタイム レジストリ変更監視

.DESCRIPTION
    WMI (Win32_RegistryValueChangeEvent / Win32_RegistryTreeChangeEvent) を使用して
    重要なレジストリキーへの変更をリアルタイムで監視し、
    疑わしい変更を検出した場合にアラートを発します。

.PARAMETER LogPath
    ログファイルの出力先（デフォルト: スクリプトと同じフォルダ）

.PARAMETER IntervalSeconds
    監視ポーリング間隔（秒）デフォルト: 5

.PARAMETER AlertOnChange
    変更検出時にポップアップ通知を表示するか

.EXAMPLE
    .\RegistryMonitor.ps1 -IntervalSeconds 10 -AlertOnChange
#>

[CmdletBinding()]
param(
    [string]$LogPath        = '',
    [int]$IntervalSeconds   = 5,
    [switch]$AlertOnChange
)

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($LogPath)) {
    $LogPath = Join-Path $SCRIPT_DIR "RegistryMonitor_$(Get-Date -Format 'yyyyMMdd').log"
}

# ============================================================
# 監視対象レジストリキー定義
# ============================================================
$WATCH_KEYS = @(
    # スタートアップ
    @{ Hive='HKEY_LOCAL_MACHINE'; Path='SOFTWARE\Microsoft\Windows\CurrentVersion\Run';      Label='Startup (HKLM)';        Risk='High' },
    @{ Hive='HKEY_CURRENT_USER';  Path='SOFTWARE\Microsoft\Windows\CurrentVersion\Run';      Label='Startup (HKCU)';        Risk='High' },
    @{ Hive='HKEY_LOCAL_MACHINE'; Path='SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';  Label='RunOnce (HKLM)';        Risk='High' },
    # ファイル関連付け
    @{ Hive='HKEY_CURRENT_USER';  Path='SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts'; Label='FileExts (HKCU)'; Risk='Medium' },
    # セキュリティポリシー
    @{ Hive='HKEY_LOCAL_MACHINE'; Path='SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'; Label='Winlogon';           Risk='Critical' },
    # サービス
    @{ Hive='HKEY_LOCAL_MACHINE'; Path='SYSTEM\CurrentControlSet\Services';                  Label='Services';              Risk='High' },
    # アンインストール
    @{ Hive='HKEY_LOCAL_MACHINE'; Path='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Label='Uninstall';            Risk='Low' },
)

# ============================================================
# ログ・通知ヘルパー
# ============================================================
function Write-Log {
    param([string]$Level, [string]$Message)
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $LogPath -Value $line -Encoding UTF8

    $color = switch ($Level) {
        'CRITICAL' { 'Red'     }
        'HIGH'     { 'Magenta' }
        'MEDIUM'   { 'Yellow'  }
        'INFO'     { 'Cyan'    }
        default    { 'White'   }
    }
    Write-Host $line -ForegroundColor $color
}

function Show-Toast {
    param([string]$Title, [string]$Body)
    try {
        [Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime] | Out-Null
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $template.GetElementsByTagName('text')[0].InnerText = $Title
        $template.GetElementsByTagName('text')[1].InnerText = $Body
        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('SecurityTool').Show($toast)
    } catch { <# トースト非対応環境では無視 #> }
}

# ============================================================
# WMI イベント監視セットアップ
# ============================================================
function Register-RegistryWatcher {
    param([hashtable]$KeyDef)

    $hive = switch ($KeyDef.Hive) {
        'HKEY_LOCAL_MACHINE' { 2147483650 }
        'HKEY_CURRENT_USER'  { 2147483649 }
        default              { 2147483650 }
    }

    $escapedPath = $KeyDef.Path -replace '\\', '\\\\'
    $query = @"
SELECT * FROM RegistryTreeChangeEvent
WHERE Hive = '$($KeyDef.Hive)'
AND   RootPath = '$escapedPath'
"@

    $identifier = "RegWatch_$($KeyDef.Label -replace '[^a-zA-Z0-9]','_')"

    try {
        Register-WmiEvent `
            -Query     $query `
            -Namespace 'root\default' `
            -SourceIdentifier $identifier `
            -ErrorAction Stop | Out-Null

        Write-Log 'INFO' "監視開始: [$($KeyDef.Label)] $($KeyDef.Hive)\$($KeyDef.Path)"
        return $identifier
    } catch {
        Write-Log 'INFO' "WMI 監視登録スキップ (権限不足の可能性): $($KeyDef.Label) - $_"
        return $null
    }
}

# ============================================================
# スナップショット比較による変更検出（WMI 非対応環境向けフォールバック）
# ============================================================
function Get-RegistrySnapshot {
    param([hashtable]$KeyDef)

    $snapshot = @{}
    try {
        $regPath = "$($KeyDef.Hive)\$($KeyDef.Path)"
        $key = [Microsoft.Win32.Registry]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]($KeyDef.Hive -replace 'HKEY_',''),
            [Microsoft.Win32.RegistryView]::Registry64
        )
        # PowerShell の Get-ItemProperty を使用
        $psPath = $regPath -replace 'HKEY_LOCAL_MACHINE','HKLM:' -replace 'HKEY_CURRENT_USER','HKCU:'
        if (Test-Path $psPath) {
            $props = Get-ItemProperty -Path $psPath -ErrorAction SilentlyContinue
            if ($props) {
                $props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object {
                    $snapshot[$_.Name] = $_.Value
                }
            }
        }
    } catch { }
    return $snapshot
}

function Compare-Snapshots {
    param(
        [hashtable]$Before,
        [hashtable]$After,
        [hashtable]$KeyDef
    )

    $changes = @()

    # 追加・変更
    foreach ($key in $After.Keys) {
        if (-not $Before.ContainsKey($key)) {
            $changes += [PSCustomObject]@{
                Type      = 'Added'
                ValueName = $key
                OldValue  = $null
                NewValue  = $After[$key]
                KeyDef    = $KeyDef
            }
        } elseif ($Before[$key] -ne $After[$key]) {
            $changes += [PSCustomObject]@{
                Type      = 'Modified'
                ValueName = $key
                OldValue  = $Before[$key]
                NewValue  = $After[$key]
                KeyDef    = $KeyDef
            }
        }
    }

    # 削除
    foreach ($key in $Before.Keys) {
        if (-not $After.ContainsKey($key)) {
            $changes += [PSCustomObject]@{
                Type      = 'Deleted'
                ValueName = $key
                OldValue  = $Before[$key]
                NewValue  = $null
                KeyDef    = $KeyDef
            }
        }
    }

    return $changes
}

# ============================================================
# メイン監視ループ
# ============================================================
Write-Host "`n$('=' * 60)" -ForegroundColor Cyan
Write-Host "  RegistryMonitor v1.0.0 - リアルタイム レジストリ監視" -ForegroundColor Cyan
Write-Host "$('=' * 60)" -ForegroundColor Cyan
Write-Log 'INFO' "監視開始 | ポーリング間隔: ${IntervalSeconds}秒 | ログ: $LogPath"

# 初期スナップショット取得
Write-Host "[*] 初期スナップショットを取得中..." -ForegroundColor Yellow
$snapshots = @{}
foreach ($keyDef in $WATCH_KEYS) {
    $id = "$($keyDef.Hive)_$($keyDef.Path)"
    $snapshots[$id] = Get-RegistrySnapshot -KeyDef $keyDef
    Write-Host "    [OK] $($keyDef.Label)" -ForegroundColor Gray
}
Write-Host "[+] スナップショット取得完了。監視を開始します..." -ForegroundColor Green
Write-Host "    Ctrl+C で停止`n" -ForegroundColor Gray

# 監視ループ
$iteration = 0
try {
    while ($true) {
        Start-Sleep -Seconds $IntervalSeconds
        $iteration++

        foreach ($keyDef in $WATCH_KEYS) {
            $id      = "$($keyDef.Hive)_$($keyDef.Path)"
            $before  = $snapshots[$id]
            $after   = Get-RegistrySnapshot -KeyDef $keyDef
            $changes = Compare-Snapshots -Before $before -After $after -KeyDef $keyDef

            foreach ($change in $changes) {
                $msg = "[{0}] {1}\{2} | 値名: {3}" -f `
                    $change.Type, $keyDef.Hive, $keyDef.Path, $change.ValueName

                if ($change.OldValue) { $msg += " | 旧値: $($change.OldValue)" }
                if ($change.NewValue) { $msg += " | 新値: $($change.NewValue)" }

                Write-Log $keyDef.Risk $msg

                if ($AlertOnChange) {
                    Show-Toast `
                        -Title "SecurityTool: レジストリ変更検出 [$($keyDef.Risk)]" `
                        -Body  $msg
                }
            }

            # スナップショット更新
            $snapshots[$id] = $after
        }

        # 定期ステータス表示（1分ごと）
        if ($iteration % ([Math]::Max(1, [int](60 / $IntervalSeconds))) -eq 0) {
            Write-Log 'INFO' "監視中... (チェック回数: $iteration)"
        }
    }
} finally {
    Write-Log 'INFO' "監視を停止しました"
    # WMI イベント登録解除
    Get-EventSubscriber | Where-Object { $_.SourceIdentifier -like 'RegWatch_*' } |
        Unregister-Event
}
