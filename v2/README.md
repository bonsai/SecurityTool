# SecurityTool v2 (掃除夫 木村さん)

Go言語で実装されたWindows 10向けの常駐型PCクリーナーアプリケーションです。

詳細は[ルートのREADME](../README.md)を参照してください。

## 主な機能

- **常駐監視**: システムトレイに常駐し、バックグラウンドで動作します。
- **定期スキャン**: 3時間ごとにクリーンアップ可能な項目を自動で調査します。
- **ユーザー確認**: 実際の削除は行わず、ユーザーが確認した上で手動実行する安全設計です。

## 使い方

1.  リリースページから `kimura-san.exe` と `assets` フォルダをダウンロードします。
2.  `kimura-san.exe` と `assets` フォルダを同じディレクトリに配置して実行します。

## ビルド方法

```bash
# Windows向けにビルド
GOOS=windows GOARCH=amd64 go build -ldflags="-H windowsgui" -o kimura-san.exe ./cmd/kimura-san/
```
