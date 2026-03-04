package scheduler

import (
	"context"
	"time"
)

// Scheduler は定期的に関数を実行します。
type Scheduler struct {
	task     func(context.Context)
	interval time.Duration
	stopChan chan struct{}
}

// New は新しいSchedulerインスタンスを作成します。
func New(task func(context.Context), interval time.Duration) *Scheduler {
	return &Scheduler{
		task:     task,
		interval: interval,
		stopChan: make(chan struct{}),
	}
}

// Start はスケジューラを開始します。
func (s *Scheduler) Start(ctx context.Context) {
	ticker := time.NewTicker(s.interval)
	go func() {
		// 起動時に即時実行
		s.task(ctx)

		for {
			select {
			case <-ticker.C:
				s.task(ctx)
			case <-s.stopChan:
				ticker.Stop()
				return
			}
		}
	}()
}

// Stop はスケジューラを停止します。
func (s *Scheduler) Stop() {
	close(s.stopChan)
}
