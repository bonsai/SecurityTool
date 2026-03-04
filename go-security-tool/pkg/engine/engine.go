package engine

import (
	"context"
	"sync"

	"github.com/bonsai/SecurityTool/go-security-tool/pkg/cleaner"
)

// ScanResult はスキャン結果を格納します。
type ScanResult struct {
	Category cleaner.Category
	Items    []cleaner.Item
	Err      error
}

// RunScan は登録されたすべてのクリーナーのスキャンを並列で実行します。
func RunScan(ctx context.Context, cleaners []cleaner.Cleaner) <-chan ScanResult {
	resultsChan := make(chan ScanResult, len(cleaners))
	var wg sync.WaitGroup

	for _, c := range cleaners {
		wg.Add(1)
		go func(cl cleaner.Cleaner) {
			defer wg.Done()
			items, err := cl.Scan(ctx)
			resultsChan <- ScanResult{Category: cl.Category(), Items: items, Err: err}
		}(c)
	}

	go func() {
		wg.Wait()
		close(resultsChan)
	}()

	return resultsChan
}
