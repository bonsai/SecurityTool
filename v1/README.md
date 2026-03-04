# SecurityTool v1 (PowerShell版)

C++ DLLをコアエンジンとし、PowerShellスクリプトから呼び出す構成のシステムメンテナンスツールです。

詳細は[ルートのREADME](../README.md)を参照してください。

## 主な機能

- システムジャンクのスキャン・クリーンアップ
- レジストリの問題検出・修復
- Docker、機械学習キャッシュ等の拡張クリーンアップ

## 使い方

```powershell
# ジャンクファイルとレジストリをスキャン
.\scripts\SecurityTool.ps1 -Action scan

# Dockerの不要ファイルをプレビュー表示
.\scripts\SecurityTool.ps1 -Action cleanup -Target docker -DryRun
```
