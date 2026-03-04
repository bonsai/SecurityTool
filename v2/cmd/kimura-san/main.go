package main

import (
	"context"
	"fmt"
	"io/ioutil"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/bonsai/SecurityTool/v2/pkg/cleaner"
	"github.com/bonsai/SecurityTool/v2/pkg/engine"
	"github.com/bonsai/SecurityTool/v2/pkg/logger"
	"github.com/bonsai/SecurityTool/v2/pkg/scheduler"

	"github.com/getlantern/systray"
	"github.com/go-toast/toast"
)

const logFilePath = "kimura-san_log.txt"

var (
	// アプリケーションの状態を管理
	appState struct {
		mu              sync.Mutex
		lastScanItems   map[cleaner.Category][]cleaner.Item
		lastScanTime    time.Time
		lastCleanTime   time.Time
		isScanning      bool
		isCleaning      bool
	}
	// UIコンポーネント
	mStatus   *systray.MenuItem
	mScan     *systray.MenuItem
	mClean    *systray.MenuItem
)

func main() {
	if err := logger.Init(logFilePath); err != nil {
		fmt.Printf("ロガーの初期化に失敗: %v\n", err)
		return
	}
	logger.Info("アプリケーション起動")
	systray.Run(onReady, onExit)
}

func onReady() {
	icon, _ := ioutil.ReadFile("assets/icon.ico")
	systray.SetIcon(icon)
	systray.SetTitle("掃除夫 木村さん")
	systray.SetTooltip("待機中...")

	// --- メニュー設定 ---
	mStatus = systray.AddMenuItem("状態: 待機中", "現在の状態")
	systray.AddSeparator()
	mScan = systray.AddMenuItem("今すぐ調査", "クリーンアップ可能な項目を調査します")
	mClean = systray.AddMenuItem("お掃除を実行 (0項目)", "調査結果を元にクリーンアップを実行します")
	mClean.Disable()
	systray.AddSeparator()
	mOpenLog := systray.AddMenuItem("ログファイルを開く", "動作ログを確認します")
	mQuit := systray.AddMenuItem("終了", "アプリケーションを終了します")

	// --- アプリケーションロジック ---
	ctx, cancel := context.WithCancel(context.Background())
	appState.lastScanItems = make(map[cleaner.Category][]cleaner.Item)

	// 定期スキャンタスクを定義
	scanTask := func(ctx context.Context) {
		go runScan(ctx)
	}

	// 3時間ごとにタスクを実行するスケジューラを開始
	sched := scheduler.New(scanTask, 3*time.Hour)
	sched.Start(ctx)

	// メニュークリックイベントのハンドリング
	go func() {
		for {
			select {
			case <-mScan.ClickedCh:
				logger.Info("手動スキャンがトリガーされました")
				go runScan(ctx)
			case <-mClean.ClickedCh:
				logger.Info("手動クリーンアップがトリガーされました")
				go runClean(ctx)
			case <-mOpenLog.ClickedCh:
				exec.Command("cmd", "/C", "start", logFilePath).Start()
			case <-mQuit.ClickedCh:
				logger.Info("終了処理を開始")
				cancel()
				sched.Stop()
				systray.Quit()
				return
			}
		}
	}()
}

func onExit() {
	logger.Info("アプリケーション終了")
}

// runScan はクリーンアップ可能な項目を調査し、結果を状態に保存します。
func runScan(ctx context.Context) {
	appState.mu.Lock()
	if appState.isScanning {
		appState.mu.Unlock()
		logger.Info("スキャンは既に実行中です")
		return
	}
	appState.isScanning = true
	appState.mu.Unlock()

	defer func() {
		appState.mu.Lock()
		appState.isScanning = false
		appState.mu.Unlock()
		mStatus.SetTitle("状態: 待機中")
	}()

	mStatus.SetTitle("状態: 調査中...")
	logger.Info("調査を開始します...")
	notify("調査開始", "お掃除できる項目を探しています...")

	cleaners := []cleaner.Cleaner{&cleaner.JunkCleaner{}, &cleaner.DockerCleaner{}}
	resultsChan := engine.RunScan(ctx, cleaners)

	tempScanItems := make(map[cleaner.Category][]cleaner.Item)
	var totalItems int
	var totalSize int64

	for res := range resultsChan {
		if res.Err != nil {
			logger.Warn("調査中にエラー [%s]: %v", res.Category, res.Err)
			continue
		}
		if len(res.Items) > 0 {
			tempScanItems[res.Category] = res.Items
			logger.Info("[%s] %d個の項目を発見しました", res.Category, len(res.Items))
			for _, item := range res.Items {
				logger.Info("  - %s (%s)", item.Description, cleaner.FormatBytes(item.Size))
				totalSize += item.Size
			}
			totalItems += len(res.Items)
		}
	}

	appState.mu.Lock()
	appState.lastScanItems = tempScanItems
	appState.lastScanTime = time.Now()
	appState.mu.Unlock()

	if totalItems > 0 {
		mClean.SetTitle(fmt.Sprintf("お掃除を実行 (%d項目, %s)", totalItems, cleaner.FormatBytes(totalSize)))
		mClean.Enable()
		msg := fmt.Sprintf("%d個の項目 (%s) がお掃除可能です。", totalItems, cleaner.FormatBytes(totalSize))
		notify("調査完了", msg)
	} else {
		mClean.SetTitle("お掃除を実行 (0項目)")
		mClean.Disable()
		notify("調査完了", "お掃除できる項目はありませんでした。")
	}
	logger.Info("調査が完了しました。")
}

// runClean は最後のスキャン結果を元にクリーンアップを実行します。
func runClean(ctx context.Context) {
	appState.mu.Lock()
	if appState.isCleaning {
		appState.mu.Unlock()
		return
	}
	appState.isCleaning = true
	itemsToClean := appState.lastScanItems
	appState.lastScanItems = make(map[cleaner.Category][]cleaner.Item) // 一度消したらリストは空に
	appState.mu.Unlock()

	mClean.Disable()
	mStatus.SetTitle("状態: お掃除中...")
	logger.Info("お掃除を開始します...")
	notify("お掃除開始", "見つかった項目を削除しています...")

	var totalFreed int64
	var wg sync.WaitGroup
	cleaners := []cleaner.Cleaner{&cleaner.JunkCleaner{}, &cleaner.DockerCleaner{}}

	for _, cl := range cleaners {
		if items, ok := itemsToClean[cl.Category()]; ok && len(items) > 0 {
			wg.Add(1)
			go func(c cleaner.Cleaner, i []cleaner.Item) {
				defer wg.Done()
				freed, err := c.Clean(ctx, i)
				if err != nil {
					logger.Warn("お掃除中にエラー [%s]: %v", c.Category(), err)
				} else {
					appState.mu.Lock()
					totalFreed += freed
					appState.mu.Unlock()
					logger.Info("[%s] のお掃除が完了しました。", c.Category())
				}
			}(cl, items)
		}
	}

	wg.Wait()

	appState.mu.Lock()
	appState.isCleaning = false
	appState.lastCleanTime = time.Now()
	appState.mu.Unlock()

	mStatus.SetTitle("状態: 待機中")
	msg := fmt.Sprintf("お掃除が完了し、約 %s の空き容量を確保しました。", cleaner.FormatBytes(totalFreed))
	logger.Info(msg)
	notify("お掃除完了！", msg)
}

// notify はデスクトップ通知を表示します。
func notify(title, message string) {
	// アイコンパスは実行ファイルの場所からの相対パスを想定
	// exeと同じ場所にassets/icon.icoを配置する必要がある
	iconPath, _ := filepath.Abs("assets/icon.ico")

	notification := toast.Notification{
		AppID:   "掃除夫 木村さん",
		Title:   title,
		Message: message,
		Icon:    iconPath,
	}
	if err := notification.Push(); err != nil {
		logger.Warn("通知の表示に失敗: %v", err)
	}
}
