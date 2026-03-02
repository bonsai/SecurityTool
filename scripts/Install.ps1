#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install.ps1 - SecurityTool インストーラー

.DESCRIPTION
    SecurityTool をシステムにインストールし、
    スケジュールタスクとして定期スキャンを設定します。

.PARAMETER InstallDir
    インストール先ディレクトリ（デフォルト: C:\SecurityTool）

.PARAMETER ScheduleScan
    定期スキャンのスケジュールタスクを登録するか

.PARAMETER ScanInterval
    スキャン間隔（Daily / Weekly）デフォルト: Daily
#>

[CmdletBinding()]
param(
    [string]$InstallDir    = 'C:\SecurityTool',
    [switch]$ScheduleScan,
    [ValidateSet('Daily','Weekly')]
    [string]$ScanInterval  = 'Daily'
)

$SCRIPT_DIR  = Split-Path -Parent $MyInvocation.MyCommand.Path
$SOURCE_DIR  = Split-Path -Parent $SCRIPT_DIR  # SecurityTool ルート

function Write-Step([string]$msg) { Write-Host "[*] $msg" -ForegroundColor Yellow }
function Write-OK([string]$msg)   { Write-Host "[+] $msg" -ForegroundColor Green  }
function Write-Warn([string]$msg) { Write-Host "[!] $msg" -ForegroundColor Red    }

Write-Host "`n$('=' * 60)" -ForegroundColor Cyan
Write-Host "  SecurityTool インストーラー" -ForegroundColor Cyan
Write-Host "$('=' * 60)" -ForegroundColor Cyan

# インストール先ディレクトリ作成
Write-Step "インストール先を作成: $InstallDir"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Write-OK "ディレクトリ作成完了"

# ファイルコピー
Write-Step "ファイルをコピー中..."
$filesToCopy = @(
    'output\SecurityEngine.dll',
    'scripts\SecurityTool.ps1',
    'scripts\RegistryMonitor.ps1'
)
foreach ($f in $filesToCopy) {
    $src = Join-Path $SOURCE_DIR $f
    $dst = Join-Path $InstallDir (Split-Path -Leaf $f)
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $dst -Force
        Write-OK "コピー: $dst"
    } else {
        Write-Warn "ファイルが見つかりません: $src"
    }
}

# PowerShell 実行ポリシー設定
Write-Step "実行ポリシーを設定中..."
try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
    Write-OK "実行ポリシー: RemoteSigned"
} catch {
    Write-Warn "実行ポリシーの設定に失敗しました: $_"
}

# スケジュールタスク登録
if ($ScheduleScan) {
    Write-Step "スケジュールタスクを登録中..."

    $taskName    = 'SecurityTool_DailyScan'
    $scriptPath  = Join-Path $InstallDir 'SecurityTool.ps1'
    $dllPath     = Join-Path $InstallDir 'SecurityEngine.dll'
    $reportDir   = Join-Path $InstallDir 'Reports'
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -Action report -DllPath `"$dllPath`" -OutputDir `"$reportDir`""

    $trigger = if ($ScanInterval -eq 'Daily') {
        New-ScheduledTaskTrigger -Daily -At '02:00'
    } else {
        New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '02:00'
    }

    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
        -StartWhenAvailable

    $principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest

    try {
        Register-ScheduledTask `
            -TaskName  $taskName `
            -Action    $action `
            -Trigger   $trigger `
            -Settings  $settings `
            -Principal $principal `
            -Force | Out-Null
        Write-OK "スケジュールタスク登録完了: $taskName ($ScanInterval 02:00)"
    } catch {
        Write-Warn "スケジュールタスク登録失敗: $_"
    }
}

# ショートカット作成（デスクトップ）
Write-Step "デスクトップショートカットを作成中..."
try {
    $desktopPath = [Environment]::GetFolderPath('Desktop')
    $shortcutPath = Join-Path $desktopPath 'SecurityTool.lnk'
    $wsh = New-Object -ComObject WScript.Shell
    $sc  = $wsh.CreateShortcut($shortcutPath)
    $sc.TargetPath       = 'powershell.exe'
    $sc.Arguments        = "-ExecutionPolicy Bypass -File `"$(Join-Path $InstallDir 'SecurityTool.ps1')`" -Action scan"
    $sc.WorkingDirectory = $InstallDir
    $sc.Description      = 'SecurityTool - システムスキャン'
    $sc.Save()
    Write-OK "ショートカット作成: $shortcutPath"
} catch {
    Write-Warn "ショートカット作成失敗: $_"
}

Write-Host "`n$('=' * 60)" -ForegroundColor Green
Write-Host "  インストール完了!" -ForegroundColor Green
Write-Host "  インストール先: $InstallDir" -ForegroundColor Green
Write-Host "  使用方法:" -ForegroundColor Green
Write-Host "    スキャン:    .\SecurityTool.ps1 -Action scan" -ForegroundColor Gray
Write-Host "    クリーン:    .\SecurityTool.ps1 -Action clean" -ForegroundColor Gray
Write-Host "    修復:        .\SecurityTool.ps1 -Action fix" -ForegroundColor Gray
Write-Host "    全実行:      .\SecurityTool.ps1 -Action full" -ForegroundColor Gray
Write-Host "    レポート:    .\SecurityTool.ps1 -Action report" -ForegroundColor Gray
Write-Host "    監視:        .\RegistryMonitor.ps1" -ForegroundColor Gray
Write-Host "$('=' * 60)" -ForegroundColor Green
