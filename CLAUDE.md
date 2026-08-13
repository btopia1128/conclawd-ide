# CLAUDE.md

## 質問の言語に合わせて返答してね

## Project Overview

Conclawd は Claude Code CLI のエージェントを管理・実行するための macOS デスクトップアプリケーション。

## Development

```bash
# プロジェクト生成（XcodeGen）
xcodegen generate

# Xcodeで開く
open Conclawd.xcodeproj
```

## Architecture

- **Conclawd/**: メインアプリターゲット
  - `App/` - アプリエントリポイント
  - `Models/` - データモデル
  - `Views/` - SwiftUI ビュー
  - `ViewModels/` - ビューモデル
  - `Services/` - ビジネスロジック・外部連携
  - `Vendor/` - サードパーティコード
  - `Resources/` - アセット・MLモデル
- **ConclawdEmbed/**: 埋め込みターゲット
- **ConclawdTests/**: テスト

## Key Dependencies (Swift Packages)

- SwiftTerm - ターミナルエミュレータ
- Yams - YAML パーサー
- Highlightr - シンタックスハイライト
- GRDB - SQLite データベース

## ML Models

MLモデル（`*.mlpackage`, `*.mlmodelc`, `e5_tokenizer/`）は `.gitignore` で除外。
セットアップ方法は README.md を参照。
