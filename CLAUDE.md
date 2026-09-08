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

# CLIからビルド（Xcodeと同時でも競合しない）
Scripts/build.sh            # Debug
Scripts/build.sh Release    # Release（未署名。配布は Scripts/release.sh）
```

CLIからビルドするときは素の `xcodebuild` を直接叩かず、必ず `Scripts/build.sh` を使うこと。
Xcode.app は共有の `~/Library/Developer/Xcode/DerivedData` を使うため、そこへ `xcodebuild` を
同時に走らせると `XCBuildData/build.db` を奪い合って
`unable to attach DB: ... database is locked` で落ちる。
`Scripts/build.sh` は `build/DerivedData` に分離し、CLIビルド同士の重複もロックで防ぐ。

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
