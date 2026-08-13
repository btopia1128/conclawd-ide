# エージェント単位記憶機能（Agent Memory）設計プラン v3

## 概要

各エージェントがセッションをまたいで情報を自動的に記憶・想起できる仕組み。
ユーザーの手動操作なしで、**セッション中にエージェントが随時記憶を保存**し、次回セッション開始時にシステムプロンプトへ注入する。

**設計方針:**
- メモリの追加は全自動（ユーザーの手動追加に依存しない）
- **セッション中の随時保存（Write ツール + FileWatcher）** がメイン
- セッション終了時の LLM 抽出は安全ネット（保存漏れの補完）
- ファイルベース（Markdown）で人間が読める形式
- 既存のエージェント起動方式（`claude --agent`）を活かす
- MCP不要。追加の外部依存なし。エージェント定義ファイルも変更しない
- 記憶ルールはアプリが `--append-system-prompt` で一元管理

---

## 動機・背景

現状、エージェントはセッション終了時にすべてのコンテキストを失う。
同じエージェントを繰り返し使う場面で、毎回同じ情報を伝え直す必要がある。

**解決したいユースケース:**
- コードレビュー担当エージェントが、過去に指摘したパターンや好みを覚えている
- デプロイ担当エージェントが、前回のインシデント情報を保持している
- ユーザーのフィードバック（「この書き方はやめて」等）をエージェントが学習する

---

## アーキテクチャ概要

```
┌──────────────────────────────────────────────────────────────────┐
│ Session Lifecycle                                                │
│                                                                  │
│  ① 起動時                                                        │
│  ┌─────────────┐                                                 │
│  │ MEMORY.md   │──→ --append-system-prompt                       │
│  │ + 個別.md   │   （既存メモリ内容 + 保存ルール + inbox パス）     │
│  └─────────────┘                                                 │
│                                                                  │
│  ② 対話中（随時）                                                 │
│  ┌──────────────────┐    Write ツール    ┌──────────────────┐    │
│  │ エージェントが     │──────────────────→│ inbox.md         │    │
│  │ 「覚えるべき」と   │                   │ (append-only)    │    │
│  │ 判断したタイミング │                   └────────┬─────────┘    │
│  └──────────────────┘                             │              │
│                                          FileWatcher 検知        │
│                                                    │              │
│                                          ┌─────────▼─────────┐   │
│                                          │ アプリがパース      │   │
│                                          │ → 個別 .md 作成    │   │
│                                          │ → MEMORY.md 更新   │   │
│                                          │ → inbox.md クリア   │   │
│                                          └───────────────────┘   │
│                                                                  │
│  ③ セッション終了時（安全ネット）                                  │
│  ┌─────────────┐    LLM API     ┌─────────────────┐             │
│  │ memory/     │←── 抽出 ←──────│ Terminal Buffer  │             │
│  │ *.md files  │  (保存漏れ補完) │ (ANSI stripped)  │             │
│  └─────────────┘                └─────────────────┘             │
└──────────────────────────────────────────────────────────────────┘
```

### ストレージ構造

```
{project}/.claude/agents/
├── code-reviewer.md              # 既存のエージェント定義（変更なし）
├── code-reviewer.memory/         # メモリディレクトリ
│   ├── MEMORY.md                 # インデックス（名前+説明の一覧）
│   ├── inbox.md                  # エージェントが書き込む一時ファイル
│   ├── feedback_no_mocks.md      # 個別メモリファイル（パース後）
│   └── user_style_prefs.md
├── deployer.md
└── deployer.memory/
    ├── MEMORY.md
    ├── inbox.md
    └── incident_db_migration.md
```

---

## データフロー詳細

### ① セッション起動時: メモリ + ルール注入

アプリが `--append-system-prompt` で以下を注入する。
エージェント定義ファイル（`.md`）は一切変更しない。
記憶ルールはアプリが一元管理し、全エージェントに同じルールを適用する。

```swift
// AgentProcessManager.start(agent:) 内
func start(agent: Agent, memoryContext: String?) throws -> UUID {
    var args = ["--agent", agent.name]

    // メモリ有効なら --append-system-prompt で注入
    if agent.memoryEnabled, let context = memoryContext, !context.isEmpty {
        args.append("--append-system-prompt")
        args.append(context)
    }

    // ...
}
```

**注入テキストの構成（`buildMemoryContext` が生成）:**

```
<agent-memory>

## 過去の記憶
以下はこのエージェントの過去のセッションから蓄積された記憶です。
これらを参考にしつつ、現在のタスクに取り組んでください。
既存のメモリが古くなっていたり間違っている場合は、そのまま従わず現在の状況を優先してください。

### feedback: テストではモックを使わない
統合テストでは実DBを使用すること。
**Why:** 前四半期にモックとの乖離でバグが発生。
**How to apply:** テストコードでDB操作のモック化を提案しない。

### user: シニアGoエンジニア、React初心者
バックエンドの類推でフロントエンドを説明すると理解が早い。

## 記憶の保存ルール
対話中に以下に該当する情報を得た場合、Write ツールで即座に保存してください。

保存先: {memoryDir}/inbox.md（追記）
フォーマット（1件ごとに --- で区切る）:

---
name: english_snake_case
type: feedback
description: 一行の説明
---
本文。**Why:** と **How to apply:** を含める。
---

### 保存すべきもの
- ユーザーからの修正・フィードバック（「これはやめて」「こうして」）→ type: feedback
- ユーザーの役割・専門性・好みが判明した時 → type: user
- プロジェクトの重要な意思決定・背景が共有された時 → type: project
- 外部リソースの場所・参照先を教えられた時 → type: reference
- 繰り返し使えるパターンを学んだ時 → type: learned

### 保存しないもの
- 今のタスクだけに関係する一時的な情報
- コードやgit履歴から読み取れること
- 「過去の記憶」セクションに既にある情報

### ルール
- 1セッションで最大5回まで
- 保存前に「過去の記憶」セクションを確認し、重複しないこと
- 対話の流れを中断せず、自然なタイミングで保存すること

</agent-memory>
```

**ポイント:**
- 既存メモリの内容と保存ルールを1つのテキストにまとめて注入
- `{memoryDir}` はアプリが実パスに置換
- エージェント定義ファイルにはメモリ関連の記述は一切不要
- メモリ無効のエージェントには `--append-system-prompt` を付けない

### ② 対話中: エージェントが Write で inbox.md に追記

エージェントが「これは覚えるべき」と判断した時点で、標準の Write ツールを使って `inbox.md` に追記する。

```
エージェントの思考:
「ユーザーがモックを使うなと言った。記憶しよう」
→ Write(file: "/path/to/.../code-reviewer.memory/inbox.md", content: "---\nname: ...")
→ ファイル書き込み成功
→ 対話を続行
```

**アプリ側の処理（FileWatcher）:**

```swift
// FileWatcher が inbox.md の変更を検知
func handleInboxChange(agent: Agent) {
    guard let memoryDir = agent.memoryDirectory else { return }
    let inboxPath = memoryDir.appending(path: "inbox.md")

    // 1. inbox.md を読み込み
    guard let content = try? String(contentsOf: inboxPath, encoding: .utf8),
          !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

    // 2. --- 区切りでパース → [AgentMemory] に変換
    let memories = parseInbox(content)

    // 3. 各メモリを個別ファイルに保存
    for memory in memories {
        try? memoryService.saveMemory(memory, for: agent)
    }

    // 4. MEMORY.md インデックスを更新
    try? memoryService.rebuildIndex(for: agent)

    // 5. inbox.md をクリア
    try? "".write(to: inboxPath, atomically: true, encoding: .utf8)
}
```

**inbox.md の例（エージェントが書き込んだ状態）:**

```markdown
---
name: feedback_no_mocks
type: feedback
description: 統合テストでは実DBを使用すること
---
統合テストでは実データベースを使用し、モックは使わない。

**Why:** 前四半期にモックテストがパスしたが本番マイグレーションが失敗するインシデントが発生。
**How to apply:** テストコードを書く際、DB操作のモック化を提案しない。
---
---
name: user_go_expert
type: user
description: シニアGoエンジニア、React初心者
---
バックエンドの類推でフロントエンドを説明すると理解が早い。
---
```

### ③ セッション終了時: 安全ネット（LLM 抽出）

セッション終了時に、ターミナルバッファから記憶すべき情報を LLM で抽出する。
これはエージェントが inbox.md に書き忘れたケースを補完する安全ネット。

```
handleProcessTerminated(sessionId:exitCode:)
  │
  ├─ 1. getTerminalText(sessionId:) でターミナルバッファ取得
  │
  ├─ 2. stripANSI() でエスケープシーケンス除去
  │
  ├─ 3. テキストが短すぎる場合はスキップ（閾値: 500文字）
  │
  ├─ 4. 既存 MEMORY.md を読み込み（重複防止）
  │     ※ ②で保存済みのメモリも含まれる
  │
  ├─ 5. LLM API (claude -p --model haiku) に抽出プロンプトを送信
  │     - 入力: クリーンテキスト + 既存メモリ一覧
  │     - 出力: 構造化JSON（新規メモリ / 更新 / 削除）
  │     - 既存メモリに既にある情報は抽出しない
  │
  ├─ 6. 結果をパースして memory/ にファイル書き込み
  │
  └─ 7. MEMORY.md インデックスを更新
```

---

## メモリ抽出の詳細設計（安全ネット用）

### 抽出プロンプト

```
以下はAIエージェントとユーザーの対話ログです。
この対話から、将来のセッションで役立つ情報を抽出してください。

## 抽出すべきもの
- ユーザーからの修正・フィードバック（「これはやめて」「こうして」）→ type: feedback
- ユーザーの役割・専門性・好み → type: user
- プロジェクトの重要な意思決定・背景 → type: project
- 外部リソースの場所・参照先 → type: reference
- エージェントが学んだパターン・知見 → type: learned

## 抽出しないもの
- 今のタスクだけに関係する一時的な情報
- コードやgit履歴から読み取れる具体的な実装内容
- 既に既存メモリに記録済みの情報

## 既存メモリ（重複回避のため参照）
{existing_memory_index}

## 出力フォーマット
以下のJSONで返してください。抽出すべきものがない場合は空配列を返してください。
```json
{
  "memories": [
    {
      "action": "create",
      "name": "英語のスネークケース（例: feedback_no_mocks）",
      "description": "一行の説明",
      "type": "feedback|user|project|reference|learned",
      "content": "本文。Why: と How to apply: を含めること。"
    },
    {
      "action": "update",
      "existing_file": "既存ファイル名.md",
      "content": "更新後の本文"
    },
    {
      "action": "delete",
      "existing_file": "不要になったファイル名.md",
      "reason": "削除理由"
    }
  ]
}
```

## 対話ログ
{conversation_text}
```

### 抽出の実行方法

```swift
// claude CLI の --print モードを使用（非対話的）
func extractMemories(conversationText: String, existingIndex: String) async throws -> [MemoryAction] {
    let prompt = buildExtractionPrompt(
        conversation: conversationText,
        existingMemories: existingIndex
    )

    // claude -p --model haiku --output-format json --json-schema ...
    let process = Process()
    process.executableURL = URL(fileURLWithPath: claudePath)
    process.arguments = [
        "-p",
        "--model", "haiku",       // 抽出には軽量モデルで十分
        "--output-format", "json",
        "--json-schema", memoryExtractionSchema,
        prompt
    ]

    let output = try await runProcess(process)
    return try parseMemoryActions(output)
}
```

**モデル選択:** Haiku を使用。コスト・速度の面で十分（1回あたり ~$0.001 以下）。

---

## inbox.md パースの詳細

### パース仕様

```
inbox.md は以下の形式で複数エントリを含む:

---
name: {snake_case_name}
type: {feedback|user|project|reference|learned}
description: {one_line_description}
---
{content body}
---

各エントリは --- で開始し、--- で終了する。
frontmatter 部分は YAML。本文は Markdown。
```

### パースのロバスト性

エージェント（LLM）がフォーマットを崩す可能性があるため、パーサーは寛容に設計する:

```swift
func parseInbox(_ content: String) -> [AgentMemory] {
    var memories: [AgentMemory] = []

    // --- で区切って各ブロックを処理
    let blocks = content.components(separatedBy: "\n---\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    for block in blocks {
        // frontmatter + body の分離を試みる
        if let memory = tryParseFrontmatterBlock(block) {
            memories.append(memory)
        } else {
            // フォーマット崩れ: ブロック全体を learned タイプとして保存
            let fallback = AgentMemory(
                id: UUID(),
                name: "auto_\(Date().timeIntervalSince1970)",
                description: String(block.prefix(80)),
                type: .learned,
                content: block,
                createdAt: Date(),
                updatedAt: Date()
            )
            memories.append(fallback)
        }
    }

    return memories
}
```

**パース失敗時の挙動:**
- frontmatter が不完全 → ブロック全体を `learned` タイプとして保存
- 完全に壊れたテキスト → セッション終了時の LLM 抽出（安全ネット）で拾う
- 空の inbox.md → 何もしない

---

## データモデル

### AgentMemory

```swift
struct AgentMemory: Identifiable, Codable {
    let id: UUID
    var name: String                    // ファイル名（拡張子なし）
    var description: String             // 一行の説明
    var type: AgentMemoryType           // メモリ種別
    var content: String                 // メモリ本文
    var createdAt: Date
    var updatedAt: Date
    var filePath: URL?                  // ディスク上のパス
}

enum AgentMemoryType: String, Codable, CaseIterable {
    case user       // ユーザーに関する情報
    case feedback   // ユーザーからのフィードバック・修正
    case project    // プロジェクトの状況・意思決定
    case reference  // 外部リソースへの参照
    case learned    // エージェントが学習したパターン
}
```

### メモリファイルフォーマット（個別 .md）

```markdown
---
name: feedback_no_mocks
description: 統合テストでは実DBを使用すること
type: feedback
createdAt: 2026-03-16T10:00:00Z
updatedAt: 2026-03-16T10:00:00Z
---

統合テストでは実データベースを使用し、モックは使わない。

**Why:** 前四半期にモックテストがパスしたが本番マイグレーションが失敗するインシデントが発生。
**How to apply:** テストコードを書く際、DB操作のモック化を提案しない。テストDBへの接続を前提とする。
```

### MEMORY.md フォーマット

```markdown
# Memory Index

- [feedback_no_mocks.md](feedback_no_mocks.md) - 統合テストでは実DBを使用すること
- [user_style_prefs.md](user_style_prefs.md) - コードスタイルの好み
```

---

## サービス層

### AgentMemoryService

メモリファイルのCRUDとインデックス管理を担当。

```swift
final class AgentMemoryService {

    // MARK: - Read

    /// エージェントのメモリディレクトリからメモリを一括読み込み
    func loadMemories(for agent: Agent) -> [AgentMemory]

    /// MEMORY.md のインデックステキストを読み込み
    func loadMemoryIndex(for agent: Agent) -> String

    /// 注入用のメモリコンテキストを構築
    /// 既存メモリの内容 + inbox.md パス + 保存ルール を含む
    /// <agent-memory> タグで囲んだテキストを返す
    func buildMemoryContext(for agent: Agent) -> String

    // MARK: - Write

    /// 個別メモリファイルを作成し、MEMORY.md を更新
    func saveMemory(_ memory: AgentMemory, for agent: Agent) throws

    /// 既存メモリを上書き更新し、MEMORY.md を更新
    func updateMemory(_ memory: AgentMemory, for agent: Agent) throws

    /// メモリファイルを削除し、MEMORY.md から除去
    func deleteMemory(_ memory: AgentMemory, for agent: Agent) throws

    // MARK: - Inbox

    /// inbox.md をパースして個別メモリに変換・保存・クリア
    func processInbox(for agent: Agent) throws

    // MARK: - Index

    /// memory/ 内のファイルからインデックスを再構築
    func rebuildIndex(for agent: Agent) throws
}
```

### MemoryExtractor

セッション終了時のメモリ自動抽出（安全ネット）を担当。

```swift
actor MemoryExtractor {

    private let memoryService: AgentMemoryService
    private let claudePathResolver: ClaudePathResolver

    /// セッション終了時に呼ばれる
    func extractAndSave(
        sessionId: UUID,
        agentName: String,
        terminalText: String,
        agent: Agent
    ) async {
        // 1. ANSIエスケープ除去
        let cleanText = stripANSI(terminalText)

        // 2. テキストが短すぎる場合はスキップ
        guard cleanText.count >= 500 else { return }

        // 3. 既存メモリインデックスを読み込み（inbox 経由で保存済みのものも含む）
        let existingIndex = memoryService.loadMemoryIndex(for: agent)

        // 4. LLM APIで抽出（既存メモリと重複するものは抽出しない）
        guard let actions = try? await callExtractionLLM(
            conversation: cleanText,
            existingMemories: existingIndex
        ) else { return }

        // 5. 抽出結果を適用
        for action in actions {
            try? applyMemoryAction(action, for: agent)
        }
    }

    /// ANSI エスケープシーケンスを除去
    private func stripANSI(_ text: String) -> String {
        let pattern = "\\x1B\\[[0-9;]*[A-Za-z]|\\x1B\\][^\\x07]*\\x07|\\x1B\\([A-Z]"
        return text.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
    }

    /// claude -p --model haiku で抽出
    private func callExtractionLLM(
        conversation: String,
        existingMemories: String
    ) async throws -> [MemoryAction] {
        let truncated = truncateFromStart(conversation, maxChars: 50_000)
        let prompt = buildExtractionPrompt(
            conversation: truncated,
            existingMemories: existingMemories
        )
        let result = try await executeClaudePrint(prompt: prompt, model: "haiku")
        return try JSONDecoder().decode([MemoryAction].self, from: result)
    }
}

/// 抽出結果のアクション
enum MemoryAction: Codable {
    case create(name: String, description: String, type: AgentMemoryType, content: String)
    case update(existingFile: String, content: String)
    case delete(existingFile: String, reason: String)
}
```

---

## Agent モデル拡張

```swift
struct Agent: Identifiable, Hashable {
    // ... 既存プロパティ ...

    // NEW: メモリ関連
    var memoryEnabled: Bool = true  // frontmatter で制御

    // Computed
    var memoryDirectory: URL? {
        guard let filePath else { return nil }
        let nameWithoutExt = filePath.deletingPathExtension().lastPathComponent
        return filePath.deletingLastPathComponent()
            .appending(path: "\(nameWithoutExt).memory")
    }

    var inboxPath: URL? {
        memoryDirectory?.appending(path: "inbox.md")
    }
}
```

### frontmatter での制御

```markdown
---
name: code-reviewer
memory: true          # デフォルトtrue。falseで無効化
---
```

---

## 同時実行の安全性

### 問題: 同じエージェントの複数セッションが inbox.md に同時書き込み

```
セッションA: Write("inbox.md", "---\nname: feedback_a\n...")
セッションB: Write("inbox.md", "---\nname: feedback_b\n...")
```

### 対策

**inbox.md は append-only。** エージェントへの指示で「追記」を明示する。

```
保存先: {memoryDir}/inbox.md（追記。既存内容を上書きしないこと）
```

ただし、Claude の Write ツールは「ファイル全体を書き換える」動作なので、
複数セッションが同時に Write すると片方の内容が消える可能性がある。

**対策案:**

1. **セッションごとに inbox ファイルを分ける:**
   ```
   inbox_{sessionId}.md
   ```
   - セッションIDを `--append-system-prompt` のパスに含める
   - FileWatcher は `inbox_*.md` パターンで監視
   - 競合が完全になくなる

2. **FileWatcher の処理を actor で直列化:**
   - 同時に検知しても処理は1つずつ
   - ファイル単位で分けるほうがシンプル

**推奨: セッションごとに inbox ファイルを分ける（案1）。**

```
code-reviewer.memory/
├── MEMORY.md
├── inbox_a1b2c3d4.md    # セッションAの書き込み先
├── inbox_e5f6g7h8.md    # セッションBの書き込み先
├── feedback_no_mocks.md  # パース済みメモリ
└── user_style_prefs.md
```

### MEMORY.md への書き込みの直列化

```swift
actor MemoryIndexWriter {
    func addEntry(memoryDir: URL, fileName: String, description: String) throws {
        let indexPath = memoryDir.appending(path: "MEMORY.md")

        if !FileManager.default.fileExists(atPath: indexPath.path(percentEncoded: false)) {
            try "# Memory Index\n\n".write(to: indexPath, atomically: true, encoding: .utf8)
        }

        let line = "- [\(fileName)](\(fileName)) - \(description)\n"
        let handle = try FileHandle(forWritingTo: indexPath)
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    }

    func removeEntry(memoryDir: URL, fileName: String) throws {
        let indexPath = memoryDir.appending(path: "MEMORY.md")
        guard let content = try? String(contentsOf: indexPath, encoding: .utf8) else { return }
        let filtered = content.components(separatedBy: "\n")
            .filter { !$0.contains("[\(fileName)]") }
            .joined(separator: "\n")
        try filtered.write(to: indexPath, atomically: true, encoding: .utf8)
    }
}
```

---

## AppState 拡張

```swift
final class AppState {
    // 既存
    let processManager = AgentProcessManager()
    let configService = AgentConfigService()

    // NEW
    let memoryService = AgentMemoryService()
    let memoryExtractor = MemoryExtractor(...)

    // エージェント起動時
    func startAgent(_ agent: Agent) {
        let memoryContext: String?
        if agent.memoryEnabled {
            // セッションIDを含むinboxパスを生成してコンテキストに含める
            let sessionId = UUID()
            memoryContext = memoryService.buildMemoryContext(
                for: agent,
                inboxSessionId: sessionId
            )
        } else {
            memoryContext = nil
        }

        do {
            let sessionId = try processManager.start(
                agent: agent,
                memoryContext: memoryContext
            )
            // ... 既存のセッション管理 ...
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

### セッション終了時のフック

```swift
// AgentProcessManager に onSessionTerminated コールバックを追加
var onSessionTerminated: ((UUID, String?, Agent?) -> Void)?

func handleProcessTerminated(sessionId: UUID, exitCode: Int32?) {
    guard let process = processes[sessionId] else { return }
    process.status = .stopped(exitCode: exitCode)
    process.stoppedAt = Date()

    // ターミナルテキストを取得してからコールバック
    let text = getTerminalText(sessionId: sessionId)
    onSessionTerminated?(sessionId, text, findAgent(sessionId: sessionId))

    lastDataReceived.removeValue(forKey: sessionId)
}

// AppState.init() で接続
processManager.onSessionTerminated = { [weak self] sessionId, text, agent in
    guard let self, let text, let agent, agent.memoryEnabled else { return }

    // 1. inbox ファイルの最終処理（未処理分があれば）
    try? memoryService.processInbox(for: agent, sessionId: sessionId)

    // 2. 安全ネット: LLM で保存漏れを抽出
    Task {
        await self.memoryExtractor.extractAndSave(
            sessionId: sessionId,
            agentName: agent.name,
            terminalText: text,
            agent: agent
        )

        // 3. セッション用 inbox ファイルを削除
        if let inboxPath = agent.memoryDirectory?
            .appending(path: "inbox_\(sessionId.uuidString.prefix(8)).md") {
            try? FileManager.default.removeItem(at: inboxPath)
        }
    }
}
```

---

## FileWatcher 拡張

```swift
// setupFileWatcher() 内
// 既存: .claude/agents/ ディレクトリを監視

// NEW: 各エージェントの .memory/ ディレクトリも監視
for agent in agents where agent.memoryEnabled {
    if let memoryDir = agent.memoryDirectory {
        // ディレクトリが存在しなければ作成
        try? FileManager.default.createDirectory(
            at: memoryDir,
            withIntermediateDirectories: true
        )
        fileWatcher.watch(directory: memoryDir)
    }
}

// onChange ハンドラで inbox_*.md の変更を検知
fileWatcher.onChange = { [weak self] changedURL in
    guard let self else { return }

    // inbox ファイルの変更を検知
    if changedURL.lastPathComponent.hasPrefix("inbox_") {
        if let agent = findAgentForMemoryDir(changedURL.deletingLastPathComponent()) {
            try? memoryService.processInbox(for: agent)
        }
    }

    // 既存の処理
    self.reloadAgents()
    self.reloadSkills()
}
```

---

## ターミナルバッファの制約と対策

### 既知の制約（安全ネット用）

- SwiftTerm のバッファサイズはデフォルトで有限（スクロールバック行数に依存）
- 長時間のセッションでは古い対話が流れてしまう可能性
- ANSI エスケープの除去は完全ではない場合がある

### 対策

1. **バッファサイズ拡張:** SwiftTerm の `scrollback` 設定で十分なバッファを確保
2. **テキスト長の上限:** 抽出 LLM に送る前に50,000文字に切り詰め（末尾優先）
3. **最低文字数のガード:** 500文字未満のセッションはスキップ
4. **メインの保存は inbox 経由:** バッファ制約の影響を受けない

### 将来の改善（Phase 2以降）

- Claude Code のセッションファイル（`~/.claude/projects/{hash}/.sessions/*.jsonl`）を読む方式
  - 構造化された JSON で正確な対話データが取れる
  - バッファサイズの制約なし
  - ただし Claude Code の内部構造に依存するリスクあり

---

## UI 設計

### Inspector パネルのメモリセクション

AgentInspectorView に追加。メモリの閲覧・手動編集・削除が可能。
メモリの追加は自動だが、ユーザーが不要なメモリを削除・修正できるようにする。

```
┌─────────────────────────────┐
│ Memory (3)           [Auto] │
├─────────────────────────────┤
│ ┌─────────────────────────┐ │
│ │ feedback                │ │
│ │ テストではモックを使わない   │ │
│ │ 2026-03-16         [✕]  │ │
│ └─────────────────────────┘ │
│ ┌─────────────────────────┐ │
│ │ learned                 │ │
│ │ API変更時はgen:apiを実行   │ │
│ │ 2026-03-15         [✕]  │ │
│ └─────────────────────────┘ │
│ ┌─────────────────────────┐ │
│ │ user                    │ │
│ │ シニアGoエンジニア         │ │
│ │ 2026-03-14         [✕]  │ │
│ └─────────────────────────┘ │
│                             │
│  Memory: ON  [Toggle]       │
└─────────────────────────────┘
```

- メモリをクリックすると詳細・編集シートが開く
- [✕] で削除（確認ダイアログ付き）
- トグルで memoryEnabled を切り替え（frontmatter に保存）
- [Auto] バッジは自動抽出が有効であることを示す

---

## 実装フェーズ

### Phase 1: 自動記憶 MVP

**目標:** セッション中の inbox 保存 + 終了時の安全ネット抽出 + 起動時の注入

1. **AgentMemory モデル + AgentMemoryType enum**
   - `Conclawd/Models/AgentMemory.swift`

2. **AgentMemoryService**
   - `Conclawd/Services/AgentMemoryService.swift`
   - ファイル読み書き、MEMORY.md 管理、buildMemoryContext()、processInbox()

3. **MemoryExtractor (actor)**
   - `Conclawd/Services/MemoryExtractor.swift`
   - ANSI除去、LLM API呼び出し（安全ネット）、結果パース

4. **MemoryIndexWriter (actor)**
   - MEMORY.md への排他書き込み

5. **Agent モデル拡張**
   - `memoryEnabled` プロパティ追加
   - `memoryDirectory`, `inboxPath` computed property 追加

6. **AgentConfigService 拡張**
   - frontmatter `memory` フィールドのパース・シリアライズ

7. **AgentProcessManager 拡張**
   - `start(agent:memoryContext:)` に変更
   - `--append-system-prompt` 引数の追加
   - `onSessionTerminated` コールバック追加

8. **AppState 拡張**
   - memoryService, memoryExtractor の初期化
   - startAgent でメモリ注入ロジック追加
   - onSessionTerminated での処理接続

9. **FileWatcher 拡張**
   - `.memory/` ディレクトリの監視
   - `inbox_*.md` 変更時の自動パース

10. **Inspector UI にメモリセクション追加**
    - メモリ一覧表示、編集、削除
    - ON/OFF トグル

### Phase 2: 精度・UX 改善

1. **Claude Code セッションファイル読み込み**
   - ターミナルバッファではなく JSONL から対話データを取得
   - 安全ネット抽出の精度向上

2. **メモリ注入の最適化**
   - トークン数カウント + 制限（2000トークン目安）
   - recency ベースの優先度付け

3. **メモリプレビュー**
   - 注入されるテキストのプレビュー
   - トークン数の概算表示

### Phase 3: 高度な記憶管理

1. **メモリの自動整理**
   - 重複検出・統合
   - 古いメモリの重要度スコアリング
   - 上限超過時の自動アーカイブ

2. **関連度ベースの選択的注入**
   - 全メモリ注入ではなく、セッション開始時の文脈に応じて選択
   - SQLite FTS5 によるキーワードマッチ

---

## ファイル一覧（新規・変更）

### 新規作成

| ファイル | 説明 |
|---------|------|
| `Models/AgentMemory.swift` | メモリデータモデル + MemoryAction enum |
| `Services/AgentMemoryService.swift` | メモリ CRUD + インデックス管理 + inbox 処理 |
| `Services/MemoryExtractor.swift` | セッション終了時の安全ネット抽出 (actor) |
| `Views/Settings/MemoryCardView.swift` | Inspector のメモリカード UI |
| `Views/Settings/MemoryEditSheet.swift` | メモリ編集シート |

### 変更

| ファイル | 変更内容 |
|---------|---------|
| `Models/Agent.swift` | `memoryEnabled`, `memoryDirectory`, `inboxPath` 追加 |
| `Services/AgentConfigService.swift` | frontmatter `memory` フィールド対応 |
| `Services/AgentProcessManager.swift` | `start(agent:memoryContext:)`, `onSessionTerminated` |
| `Services/FileWatcherService.swift` | `.memory/` 監視 + inbox 変更検知 |
| `ViewModels/AppState.swift` | memoryService/memoryExtractor 追加、起動・終了フック |
| `Views/Settings/AgentInspectorView.swift` | メモリセクション追加 |

---

## 技術的考慮事項

### コンテキストウィンドウの制約

メモリが増えると `--append-system-prompt` のテキストが肥大化する。

- **Phase 1:** メモリ数上限（デフォルト20件）+ 全文注入
- **Phase 2:** トークン数制限（2000トークン目安）+ recency 優先
- **Phase 3:** 関連度ベースの選択的注入

### 抽出 LLM のコスト（安全ネット）

- Haiku を使用: 1セッション終了あたり ~$0.001 以下
- 短いセッション（500文字未満）はスキップ
- 入力テキストは50,000文字で切り詰め

### ファイルシステムとの整合性

- `.memory/` ディレクトリの git 管理はユーザー判断
- ファイル名は英数字+アンダースコアに sanitize
- 同名ファイルの衝突はタイムスタンプ suffix で回避
- `inbox_*.md` は一時ファイル。セッション終了時に削除

### 既存機能への影響

- `claude --agent` の起動方式は維持（`--append-system-prompt` を追加するだけ）
- エージェント定義ファイル（`.md`）は一切変更しない
- エージェントは標準の Write ツールのみ使用（追加のツール・MCP 不要）
- FileWatcher の監視対象に `.memory/` を追加

### Write ツールのフォーマット遵守率

- LLM がフォーマットを崩す可能性がある（推定10%程度）
- 対策: パーサーを寛容に設計 + フォールバック（learned として保存）
- 最終的な安全ネットとしてセッション終了時の LLM 抽出がある
- 実運用でフォーマット崩れが多い場合、Phase 3 で MCP に移行を検討
