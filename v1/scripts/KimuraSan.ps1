# KimuraSan.ps1 - PowerShell System Tray Cleaner
# v2(Go版)の機能をPowerShellのみで再現

#region --- 初期設定・アセンブリ読み込み ---

# スクリプトのパスを基準にアイコンパスを設定
$scriptPath = $PSScriptRoot
$iconPath = Join-Path $scriptPath "..\assets\kimura-san.ico" # アイコンはv1/assetsに配置想定
$logFilePath = Join-Path $scriptPath "kimura-san_log.txt"

# Windows Forms と Drawing アセンブリをロード
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Toast通知用のXML操作アセンブリ
Add-Type -AssemblyName System.Xml

#endregion

#region --- グローバル変数・状態管理 ---

$global:kimuraState = [PSCustomObject]@{
    LastScanItems = @{}
    LastScanTime = $null
    LastCleanTime = $null
    IsScanning = $false
    IsCleaning = $false
}

#endregion

#region --- コア機能: スキャナー・クリーナー ---

# ジャンクファイルスキャナー
function Invoke-ScanJunkFiles {
    Write-Log "ジャンクファイルのスキャンを開始..."
    $items = @()
    $junkPaths = @(
        $env:TEMP,
        Join-Path $env:LOCALAPPDATA "Temp"
    )

    foreach ($path in $junkPaths) {
        if (Test-Path $path) {
            Get-ChildItem -Path $path -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                $items += [PSCustomObject]@{
                    ID = $_.FullName
                    Category = "ジャンクファイル"
                    Description = "一時ファイル"
                    Size = $_.Length
                }
            }
        }
    }
    Write-Log "ジャン_finish"
    return $items
}

# Dockerクリーナー（スキャン）
function Invoke-ScanDocker {
    Write-Log "Dockerのスキャンを開始..."
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Log "Dockerが見つからないためスキップします。"
        return @()
    }
    # `docker system prune` が対象とする項目があるか、という観点で1つのItemを返す
    # 正確なサイズは実行してみないとわからないため、ここでは象徴的なItemとする
    return @([PSCustomObject]@{
        ID = "docker_system_prune"
        Category = "Docker"
        Description = "未使用のDockerリソース (コンテナ, イメージ, etc)"
        Size = 0 # サイズはClean時に計算しない
    })
}

# クリーンアップ実行
function Invoke-Clean {
    param($ItemsToClean)

    $totalFreed = 0
    foreach ($category in $ItemsToClean.Keys) {
        Write-Log "[$category] のクリーンアップを開始..."
        $items = $ItemsToClean[$category]

        if ($category -eq "ジャンクファイル") {
            foreach ($item in $items) {
                try {
                    Remove-Item -Path $item.ID -Force -ErrorAction Stop
                    $totalFreed += $item.Size
                } catch {
                    Write-Log "[ERROR] ファイルの削除に失敗: $($item.ID)"
                }
            }
        } elseif ($category -eq "Docker") {
            try {
                docker system prune -f | Out-Null
                Write-Log "`docker system prune -f` を実行しました。"
            } catch {
                Write-Log "[ERROR] Dockerのクリーンアップに失敗しました。"
            }
        }
    }
    return $totalFreed
}

#endregion

#region --- ユーティリティ: ログ・通知・UI更新 ---

function Write-Log {
    param($Message)
    $logLine = "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) - $Message"
    Add-Content -Path $logFilePath -Value $logLine
}

function Show-Toast {
    param(
        [string]$Title,
        [string]$Message
    )

    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    $template = [Windows.UI.Notifications.ToastTemplateType]::ToastText02
    $toastXml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent($template)
    $toastXml.GetElementsByTagName("text")[0].AppendChild($toastXml.CreateTextNode($Title)) | Out-Null
    $toastXml.GetElementsByTagName("text")[1].AppendChild($toastXml.CreateTextNode($Message)) | Out-Null

    $toast = [Windows.UI.Notifications.ToastNotification]::new($toastXml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("掃除夫 木村さん").Show($toast)
}

function Update-MenuState {
    $totalItems = 0
    $totalSize = 0
    foreach ($category in $global:kimuraState.LastScanItems.Keys) {
        $items = $global:kimuraState.LastScanItems[$category]
        $totalItems += $items.Count
        $totalSize += ($items | Measure-Object -Property Size -Sum).Sum
    }

    if ($totalItems -gt 0) {
        $sizeFormatted = "{0:N1} MB" -f ($totalSize / 1MB)
        $cleanMenuItem.Text = "お掃除を実行 ($totalItems 項目, $sizeFormatted)"
        $cleanMenuItem.Enabled = $true
    } else {
        $cleanMenuItem.Text = "お掃除を実行 (0項目)"
        $cleanMenuItem.Enabled = $false
    }
}

#endregion

#region --- メインロジック: スキャン・クリーンアップの実行制御 ---

function Run-Scan {
    if ($global:kimuraState.IsScanning) { return }
    $global:kimuraState.IsScanning = $true
    $statusMenuItem.Text = "状態: 調査中..."
    Write-Log "スキャンサイクルを開始します。"
    Show-Toast -Title "調査開始" -Message "お掃除できる項目を探しています..."

    # 各スキャナーを並列実行 (PowerShell Job)
    $jobs = @{
        Junk = Start-Job -ScriptBlock ${function:Invoke-ScanJunkFiles}
        Docker = Start-Job -ScriptBlock ${function:Invoke-ScanDocker}
    }

    Wait-Job -Job $jobs.Values -Timeout 180 | Out-Null

    $tempScanItems = @{}
    $totalItems = 0
    $totalSize = 0

    foreach ($name in $jobs.Keys) {
        $items = Receive-Job -Job $jobs[$name]
        if ($items -and $items.Count -gt 0) {
            $category = $items[0].Category
            $tempScanItems[$category] = $items
            $categorySize = ($items | Measure-Object -Property Size -Sum).Sum
            $totalSize += $categorySize
            $totalItems += $items.Count
            Write-Log "[$category] $($items.Count)個の項目を発見しました。"
        }
        Remove-Job -Job $jobs[$name]
    }

    $global:kimuraState.LastScanItems = $tempScanItems
    $global:kimuraState.LastScanTime = [DateTime]::Now

    if ($totalItems -gt 0) {
        $sizeFormatted = "{0:N1} MB" -f ($totalSize / 1MB)
        Show-Toast -Title "調査完了" -Message "$totalItems 個の項目 ($sizeFormatted) がお掃除可能です。"
    } else {
        Show-Toast -Title "調査完了" -Message "お掃除できる項目はありませんでした。"
    }
    
    Update-MenuState
    $statusMenuItem.Text = "状態: 待機中"
    $global:kimuraState.IsScanning = $false
    Write-Log "スキャンサイクルが完了しました。"
}

function Run-Clean {
    if ($global:kimuraState.IsCleaning) { return }
    $global:kimuraState.IsCleaning = $true
    $statusMenuItem.Text = "状態: お掃除中..."
    $cleanMenuItem.Enabled = $false

    $itemsToClean = $global:kimuraState.LastScanItems
    $global:kimuraState.LastScanItems = @{} # 実行後はリストをクリア

    Write-Log "クリーンアップを開始します。"
    Show-Toast -Title "お掃除開始" -Message "見つかった項目を削除しています..."

    $freed = Invoke-Clean -ItemsToClean $itemsToClean

    $global:kimuraState.LastCleanTime = [DateTime]::Now
    $sizeFormatted = "{0:N1} MB" -f ($freed / 1MB)
    Show-Toast -Title "お掃除完了！" -Message "お掃除が完了し、約 $sizeFormatted の空き容量を確保しました。"
    Write-Log "クリーンアップが完了しました。解放サイズ: $sizeFormatted"

    Update-MenuState
    $statusMenuItem.Text = "状態: 待機中"
    $global:kimuraState.IsCleaning = $false
}

#endregion

#region --- UIセットアップ: システムトレイアイコンとタイマー ---

# NotifyIconオブジェクトの作成
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = [System.Drawing.Icon]::new($iconPath)
$notifyIcon.Text = "掃除夫 木村さん - 待機中"
$notifyIcon.Visible = $true

# コンテキストメニューの作成
$contextMenu = New-Object System.Windows.Forms.ContextMenu
$statusMenuItem = New-Object System.Windows.Forms.MenuItem("状態: 待機中")
$statusMenuItem.Enabled = $false
$scanMenuItem = New-Object System.Windows.Forms.MenuItem("今すぐ調査")
$cleanMenuItem = New-Object System.Windows.Forms.MenuItem("お掃除を実行 (0項目)")
$cleanMenuItem.Enabled = $false
$logMenuItem = New-Object System.Windows.Forms.MenuItem("ログを開く")
$exitMenuItem = New-Object System.Windows.Forms.MenuItem("終了")

# メニュー項目の追加
$contextMenu.MenuItems.Add($statusMenuItem) | Out-Null
$contextMenu.MenuItems.Add("-") | Out-Null
$contextMenu.MenuItems.Add($scanMenuItem) | Out-Null
$contextMenu.MenuItems.Add($cleanMenuItem) | Out-Null
$contextMenu.MenuItems.Add("-") | Out-Null
$contextMenu.MenuItems.Add($logMenuItem) | Out-Null
$contextMenu.MenuItems.Add($exitMenuItem) | Out-Null

$notifyIcon.ContextMenu = $contextMenu

# イベントハンドラの登録
$scanMenuItem.add_Click({ Run-Scan })
$cleanMenuItem.add_Click({ Run-Clean })
$logMenuItem.add_Click({ 
    Write-Log "ログファイルを開きます。"
    Invoke-Item $logFilePath
})
$exitMenuItem.add_Click({ 
    Write-Log "アプリケーションを終了します。"
    $notifyIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
    # タイマーも停止
    $scanTimer.Stop()
    $scanTimer.Dispose()
    exit
})

# 定期実行タイマーのセットアップ (3時間)
$scanTimer = New-Object System.Timers.Timer
$scanTimer.Interval = 3 * 60 * 60 * 1000 # 3 hours
Register-ObjectEvent -InputObject $scanTimer -EventName Elapsed -Action { Run-Scan } | Out-Null
$scanTimer.Start()

# 初回実行
Write-Log "掃除夫 木村さん (PowerShell版) を起動しました。"
Start-Sleep -Seconds 5 # 起動後少し待ってから初回スキャン
Run-Scan

# アプリケーションのメッセージループを開始
[System.Windows.Forms.Application]::Run()

#endregion
