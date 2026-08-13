# Conclawd 仕様書

## 1. プロダクト概要

Conclawd は、Claude Code CLI のエージェントを事前定義・管理・実行するための macOS デスクトップアプリケーション。

複数のClaude Codeエージェントを Slack のチャットのように一元管理し、エージェント間の親子関係（サブエージェント）を組織図GUIで設定できる。

### ターゲットユーザー

- Claude Code を日常的に使用する開発者
- 複数のエージェントを使い分けるワークフローを持つチーム・個人

---

## 2. 機能要件

### F1: エージェント一覧（サイドバー）

Slack 風の左サイドバーに事前定義したエージェントを表示する。

- **エージェントリスト**: 各エージェントは名前、カラーインジケータ、ステータスバッジを持つ行として表示
  - 🟢 緑: プロセス実行中（アクティブに動作中）
  - 🟡 黄: プロセス実行中（ユーザー入力待ち）
  - ⚪ グレー: 停止中
- **セクション分け**: 「プロジェクトエージェント」（`.claude/agents/`）と「ユーザーエージェント」（`~/.claude/agents/`）をグループ表示
- **操作**:
  - クリック → ターミナルタブを開く
  - 右クリック → コンテキストメニュー（起動 / 停止 / 強制停止 / 設定編集 / 複製 / 削除）
  - 「+」ボタン → 新規エージェント作成

### F2: ターミナルペイン（中央）

メインコンテンツエリアにタブ式のターミナルビューを表示する。

- SwiftTerm の `LocalProcessTerminalView` による本格的なターミナルエミュレーション
- 各タブで `claude --agent <agentName>` を PTY 内で実行
- エージェント設定に基づくワーキングディレクトリで起動
- ユーザーは直接ターミナルに入力し、エージェントと対話可能
- タブにはエージェント名とステータスインジケータを表示

### F3: 設定パネル（右）

選択中のエージェントの設定を編集可能なフォームで表示する。

| 設定項目 | 対応するClaude Code設定 | UIコンポーネント |
|---------|----------------------|----------------|
| エージェント名 | `name` | テキストフィールド |
| 説明 | `description` | テキストフィールド |
| ワーキングディレクトリ | （アプリ独自設定） | フォルダピッカー |
| モデル | `model` | ドロップダウン |
| カラー | `color` | カラーセレクタ |
| 許可ツール | `tools` | リストエディタ |
| 禁止ツール | `disallowedTools` | リストエディタ |
| スキル | `skills` | リストエディタ |
| サブエージェント | `tools` 内の `Agent(...)` | リストエディタ |
| パーミッションモード | `permissionMode` | ドロップダウン |
| 最大ターン数 | `maxTurns` | 数値入力 |
| MCPサーバー | `mcpServers` | リストエディタ |
| フック | `hooks` | JSON / フォームエディタ |
| システムプロンプト | マークダウン本文 | 複数行テキストエディタ |

- 「保存」ボタンで `.claude/agents/<name>.md` に書き出し
- 「元に戻す」ボタンでディスクから再読み込み

### F4: 組織図（ツリーエディタ）

エージェント間の親子関係（サブエージェント関係）を視覚的に表示・編集する。

- **ノード**: 各エージェントを角丸矩形で表示（名前、モデル、カラー）
- **エッジ**: 親 → 子の有向矢印（「起動可能」関係を示す）
- **操作**:
  - ノードをドラッグして位置調整
  - ノードの出力ポートから別ノードの入力ポートへドラッグ → 関係作成
  - クリックで選択 → 右ペインに設定表示
  - ダブルクリック → ターミナルタブを開く
  - 右クリック → 関係削除、設定編集、エージェント削除
- **レイアウト**: トップダウンのツリーレイアウト（自動配置）
- **データ連動**: エッジ追加 → 親エージェントの `tools` に `Agent(<child>)` を追加して `.md` ファイルを更新

### F5: プロジェクト管理

- サイドバー上部またはツールバーにプロジェクトセレクタ
- 「プロジェクトを開く」→ フォルダピッカー（NSOpenPanel）
- 最近開いたプロジェクトをリスト表示
- プロジェクト切り替え時にエージェント一覧を再読み込み

### F6: エージェントライフサイクル管理

- **起動**: PTY プロセス生成、`claude --agent <name>` 実行
- **入力送信**: テキストフィールドまたはターミナル直接入力でエージェントに指示
- **停止**: SIGTERM 送信（確認ダイアログあり）
- **強制停止**: SIGKILL 送信
- **再起動**: 停止 → 起動
- **ステータス検知**: ターミナル出力のパターンマッチでアクティブ/待機を判定

---

## 3. 画面レイアウト

```
┌─────────────────┬────────────────────────────────┬──────────────────┐
│  Agents         │  Terminal (タブ式)              │  Inspector       │
│                 │  ┌──────┬──────┬──────┐        │                  │
│  Project Agents │  │Coder │Review│Tester│        │  Name: Coder     │
│  ───────────── │  └──────┴──────┴──────┘        │  Model: sonnet   │
│  🟢 Coder      │                                │  Dir: /proj/src  │
│  🟡 Reviewer   │  $ claude --agent coder        │  Color: 🔵       │
│  ⚪ Tester     │  > Reading files...            │                  │
│                 │  > Analyzing src/main.swift    │  Tools:          │
│  User Agents   │  > ...                         │  ☑ Read          │
│  ───────────── │                                │  ☑ Bash          │
│  ⚪ General    │                                │  ☑ Edit          │
│                 │                                │                  │
│  ─────────────  │                                │  SubAgents:      │
│  [📊 Org Chart] │                                │  - Reviewer      │
│  [+ New Agent]  │  [入力フィールド        ][Send]│  [Save] [Revert] │
└─────────────────┴────────────────────────────────┴──────────────────┘
```

---

## 4. データモデル

### 4.1 Agent（コアモデル）

```swift
struct Agent: Identifiable, Codable {
    var id: UUID
    var name: String                        // ファイル名兼 frontmatter name
    var description: String
    var model: AgentModel                   // .inherit, .haiku, .sonnet, .opus, .custom(String)
    var color: AgentColor                   // .red, .blue, .green, etc.
    var tools: [String]                     // ["Read", "Bash", "Agent(reviewer)"]
    var disallowedTools: [String]
    var permissionMode: PermissionMode      // .default, .acceptEdits, .dontAsk, etc.
    var maxTurns: Int?
    var skills: [String]
    var mcpServers: [String]
    var hooks: AgentHooks?
    var systemPrompt: String                // frontmatter 以降のマークダウン本文

    // アプリ内メタデータ（.md ファイルには書き出さない）
    var scope: AgentScope                   // .project or .user
    var filePath: URL
    var currentDirectory: URL               // アプリ独自設定
}
```

### 4.2 AgentRelation（組織図エッジ）

```swift
struct AgentRelation: Identifiable {
    var id: UUID
    var parentAgentId: UUID
    var childAgentId: UUID
}
```

`tools` 配列内の `Agent(name1, name2)` パターンから導出。組織図での編集時に `.md` ファイルに反映。

### 4.3 AgentProcess（ランタイム状態）

```swift
class AgentProcess {
    var agentId: UUID
    var pid: pid_t
    var status: AgentProcessStatus          // .running, .waitingForInput, .stopped(exitCode)
    var startedAt: Date
    var stoppedAt: Date?
}
```

### 4.4 Project

```swift
struct Project: Identifiable, Codable {
    var id: UUID
    var name: String                        // ディレクトリ名から導出
    var directoryPath: URL
    var lastOpenedAt: Date
}
```

### 4.5 列挙型

```swift
enum AgentModel: String, Codable, CaseIterable {
    case inherit, haiku, sonnet, opus
    // + custom(String) for arbitrary model IDs
}

enum AgentColor: String, Codable, CaseIterable {
    case red, orange, yellow, green, blue, purple, cyan, magenta
}

enum PermissionMode: String, Codable, CaseIterable {
    case `default`, acceptEdits, dontAsk, bypassPermissions, plan
}

enum AgentScope: Codable {
    case project, user
}

enum AgentProcessStatus {
    case running, waitingForInput, stopped(exitCode: Int32?)
}
```

---

## 5. Claude Code 設定ファイルマッピング

### 5.1 エージェント定義ファイル

アプリで定義した各エージェントは以下のパスにマークダウンファイルとして保存される。

- **プロジェクトスコープ**: `<projectDir>/.claude/agents/<name>.md`
- **ユーザースコープ**: `~/.claude/agents/<name>.md`

#### フィールドマッピング

| アプリ内フィールド | YAML frontmatter キー | 備考 |
|---|---|---|
| `name` | `name` | ファイル名にも使用: `<name>.md` |
| `description` | `description` | Claude がサブエージェント選択時に参照 |
| `model` | `model` | "inherit", "haiku", "sonnet", "opus", or model ID |
| `color` | `color` | Claude Code UI でのカラー表示 |
| `tools` | `tools` | カンマ区切り: `Read, Bash, Agent(reviewer)` |
| `disallowedTools` | `disallowedTools` | カンマ区切り |
| `permissionMode` | `permissionMode` | 文字列 |
| `maxTurns` | `maxTurns` | 整数 |
| `skills` | `skills` | YAML リスト |
| `mcpServers` | `mcpServers` | YAML リスト |
| `hooks` | `hooks` | ネスト YAML オブジェクト |
| `systemPrompt` | *(マークダウン本文)* | `---` 以降の全テキスト |

#### 生成ファイル例: `.claude/agents/code-reviewer.md`

```markdown
---
name: code-reviewer
description: Expert code review specialist. Reviews code for quality, security, and maintainability.
tools: Read, Grep, Glob, Bash
model: sonnet
color: blue
permissionMode: plan
maxTurns: 50
---

You are a senior code reviewer ensuring high standards of code quality.

When invoked:
1. Run git diff to see recent changes
2. Focus on modified files
3. Review for quality, security, and best practices
```

### 5.2 サブエージェント関係のエンコーディング

組織図で親→子の関係を作成すると:

- 親エージェントの `tools` に `Agent(<childName>)` を追加
- 複数の子: `tools: Read, Bash, Agent(reviewer, tester)`
- 関係削除時は `Agent(...)` から該当名を除去

### 5.3 ワーキングディレクトリ

Claude Code の `.claude/agents/*.md` フォーマットにはワーキングディレクトリフィールドがない。アプリ独自設定として以下に保存:

```
~/Library/Application Support/Conclawd/projects/<projectId>.json
```

エージェント起動時、`claude` プロセスのカレントディレクトリとして設定される。

---

## 6. 非機能要件

### 対応OS
- macOS 14 (Sonoma) 以降

### パフォーマンス
- エージェント同時実行数: 最低10プロセス
- サイドバーのステータス更新: 1秒以内
- 組織図ノード数: 50エージェントまでスムーズ描画

### セキュリティ
- App Sandbox: 無効（PTY アクセス・任意ディレクトリアクセスに必要）
- ユーザーの認証情報やAPIキーはアプリ内に保存しない（Claude Code 自身の認証に依存）

### 配布
- 直接配布（公証あり）を想定
- App Store 配布はサンドボックス制約のため対象外

---

## 7. 技術スタック

| レイヤー | 技術 | 用途 |
|---------|------|------|
| UI フレームワーク | SwiftUI (macOS 14+) | 全体UI |
| アプリ構造 | `NavigationSplitView` | 3カラムレイアウト |
| ターミナル | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | ターミナルエミュレーション + PTY |
| SwiftUI統合 | `NSViewRepresentable` | SwiftTerm の NSView をラップ |
| 状態管理 | `@Observable` (Observation framework) | リアクティブ状態管理 |
| 組織図描画 | SwiftUI `Canvas` + `ZStack` | ノード/エッジ描画 |
| 設定ファイル解析 | [Yams](https://github.com/jpsim/Yams) | YAML frontmatter パース |
| 永続化 | `Codable` + JSON | アプリ設定・プロジェクト情報 |
| ファイル監視 | `DispatchSource` / FSEvents | エージェントファイル変更検知 |
| プロセス管理 | Foundation `Process` + POSIX | PTY セッション管理 |

### 外部依存（最小限）

| ライブラリ | 必須度 | 理由 |
|-----------|--------|------|
| SwiftTerm | 必須 | ターミナルエミュレーション。自前実装は非現実的 |
| Yams | 推奨 | YAML パース。hooks/mcpServers のネスト構造に対応するため |

---

## 8. リスクと対策

| リスク | 影響 | 対策 |
|--------|------|------|
| SwiftTerm の SwiftUI 統合が限定的 | レイアウト・リサイズ不具合の可能性 | NSViewRepresentable で手動サイズ同期。早期に検証 |
| Claude Code CLI のfrontmatterフォーマット変更 | エージェントファイル非互換 | Yams で柔軟にパース。バージョン検知を実装 |
| hooks/mcpServers の複雑な YAML 編集 | フォームUIでの編集が困難 | フォームエディタと生 YAML テキストエディタの切り替え |
| PTY プロセス管理のエッジケース | ゾンビプロセス発生 | アプリ終了時に全子プロセスに SIGTERM。プロセスグループ使用 |
| App Sandbox 無効 | Mac App Store 配布不可 | 直接配布（公証あり）で対応 |
