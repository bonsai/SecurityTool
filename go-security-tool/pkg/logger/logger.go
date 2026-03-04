package logger

import (
	"log"
	"os"
)

var defaultLogger *log.Logger

// Init はロガーを初期化します。
func Init(logFilePath string) error {
	f, err := os.OpenFile(logFilePath, os.O_RDWR|os.O_CREATE|os.O_APPEND, 0666)
	if err != nil {
		return err
	}
	defaultLogger = log.New(f, "", log.LstdFlags)
	return nil
}

// Info は情報レベルのログを記録します。
func Info(format string, v ...interface{}) {
	if defaultLogger != nil {
		defaultLogger.Printf("[INFO] "+format+"\n", v...)
	}
}

// Warn は警告レベルのログを記録します。
func Warn(format string, v ...interface{}) {
	if defaultLogger != nil {
		defaultLogger.Printf("[WARN] "+format+"\n", v...)
	}
}
