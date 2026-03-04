package cleaner

import (
	"context"
	"os"
	"path/filepath"
)

type JunkCleaner struct{}

func (c *JunkCleaner) Category() Category { return JunkFilesCategory }

func (c *JunkCleaner) Scan(ctx context.Context) ([]Item, error) {
	var items []Item
	dirs := []string{
		os.Getenv("TEMP"),
		os.Getenv("LOCALAPPDATA") + "\\Temp",
	}

	for _, dir := range dirs {
		walkErr := filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
			if err != nil || info.IsDir() { return nil }
			items = append(items, Item{ID: path, Category: JunkFilesCategory, Description: "一時ファイル", Size: info.Size()})
			return nil
		})
		if walkErr != nil { /* ignore */ }
	}
	return items, nil
}

func (c *JunkCleaner) Clean(ctx context.Context, items []Item) (int64, error) {
	var totalFreed int64
	for _, item := range items {
		if err := os.Remove(item.ID); err == nil {
			totalFreed += item.Size
		}
	}
	return totalFreed, nil
}
