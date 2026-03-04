package cleaner

import (
	"context"
	"os/exec"
)

type DockerCleaner struct{}

func (c *DockerCleaner) Category() Category { return DockerCategory }

func (c *DockerCleaner) Scan(ctx context.Context) ([]Item, error) {
	if !commandExists("docker") { return nil, nil }

	// Dockerのクリーンアップは単純化し、「docker system prune」で一括削除できる、というItemを1つ返す
	// サイズはClean時に計算するため、ここでは0とする
	return []Item{{
		ID:          "docker_system_prune",
		Category:    DockerCategory,
		Description: "未使用のDockerリソース (コンテナ, イメージ, etc)",
		Size:        0, // Clean時に計算
	}}, nil
}

func (c *DockerCleaner) Clean(ctx context.Context, items []Item) (int64, error) {
	if len(items) == 0 { return 0, nil }

	// Clean前にdfでサイズを取得し、Clean後に再度取得して差分を計算する方式も考えられるが、
	// ここでは単純にpruneを実行するのみとする。
	cmd := exec.CommandContext(ctx, "docker", "system", "prune", "-f")
	if err := cmd.Run(); err != nil {
		return 0, err
	}
	return 0, nil // サイズは概算が難しいため0を返す
}

func commandExists(cmd string) bool {
	_, err := exec.LookPath(cmd)
	return err == nil
}
