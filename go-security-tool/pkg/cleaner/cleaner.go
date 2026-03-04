package cleaner

import (
	"context"
	"fmt"
)

// Item はスキャン対象の単一項目を表します。
type Item struct {
	ID          string   `json:"id"`
	Category    Category `json:"category"`
	Description string   `json:"description"`
	Size        int64    `json:"size"`
}

// Category はクリーンアップ対象のカテゴリを定義します。
type Category string

const (
	JunkFilesCategory    Category = "ジャンクファイル"
	DockerCategory       Category = "Docker"
	MLCachesCategory     Category = "MLキャッシュ"
	WindowsExtraCategory Category = "Windows保守"
)

// Cleaner は特定のカテゴリをスキャン・クリーンアップする機能を提供します。
type Cleaner interface {
	Category() Category
	Scan(context.Context) ([]Item, error)
	Clean(context.Context, []Item) (int64, error)
}

// FormatBytes はバイト数を人間が読みやすい形式に変換します。
func FormatBytes(b int64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(b)/float64(div), "KMGTPE"[exp])
}
