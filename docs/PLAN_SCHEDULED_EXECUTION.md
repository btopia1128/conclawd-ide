# エージェント定期実行機能（Scheduled Execution）設計プラン

## 概要

エージェントに「スケジュール + 指示」を設定し、指定した時間・間隔で自動実行する機能。
発火ごとに新しいターミナルセッションを起動し、既存のプロセス管理・メモリ統合をそのまま活用する。

**設計方針:**
- 既存の `startAgent()` フローを再利用（ターミナルセッションとして実行）
- 発火ごとに新セッション（同時実行の競合問題を回避）
- スケジュール形式はシンプル（interval / daily / weekly）
- スコープはプロジェクト単位 + ユーザーグローバル両方
- アプリ起動中は Timer で駆動、起動時にキャッチアップ実行

---

## 動機・背景

現状、エージェントは手動でしか起動できない。
定期的に実行したいタスクがあっても、毎回手動で起動→指示を入力する必要がある。

**解決したいユースケース:**
- PRレビュー担当エージェントを30分ごとに起動し、新規PRをチェック
- 毎朝9時にデプロイ状況を確認・報告するエージェント
- 毎週月曜に依存関係の更新状況をチェックするエージェント
- 定期的にログを分析してサマリーを作成するエージェント

---

## アーキテクチャ概要

```
┌─────────────────────────────────────────────────────────────┐
│ Scheduling Lifecycle                                         │
│                                                              │
│  ① アプリ起動時                                               │
│  ┌──────────────────┐                                        │
│  │ schedules.json   │──→ ScheduleManager 初期化              │
│  │ (永続化済み)      │   → Timer 開始                         │
│  └──────────────────┘   → キャッチアップ判定                  │
│          │                  （lastRunAt < nextRunAt < now     │
│          │                   → 見逃し分を即時実行）            │
│          ▼                                                    │
│  ② Timer 発火（60秒間隔でチェック）                            │
│  ┌──────────────────┐                                        │
│  │ ScheduleManager  │──→ 全スケジュールを走査                 │
│  │ .checkSchedules()│   → nextRunAt <= now のものを抽出       │
│  └────────┬─────────┘                                        │
│           │                                                   │
│           ▼                                                   │
│  ③ 実行判定                                                   │
│  ┌──────────────────────────────────────────┐                │
│  │ 同エージェントのスケジュール実行中セッション数  │                │
│  │ < maxConcurrentSessions ?                  │                │
│  │   → YES: 新セッション起動                   │                │
│  │   → NO:  スキップ＋ログ記録                 │                │
│  └────────┬─────────────────────────────────┘                │
│           │                                                   │
│           ▼                                                   │
│  ④ セッション起動                                              │
│  ┌──────────────────┐    ┌─────────────────────┐            │
│  │ AppState          │──→│ AgentProcessManager  │            │
│  │ .startScheduled   │   │ .start(agent:...)    │            │
│  │  Agent(schedule:) │   └────────┬────────────┘            │
│  └──────────────────┘            │                           │
│           │                       ▼                           │
│           │              ┌─────────────────────┐             │
│           │              │ TerminalSession      │             │
│           │              │ (isScheduled: true)  │             │
│           │              │ prompt を自動送信     │             │
│           │              └─────────────────────┘             │
│           ▼                                                   │
│  ⑤ 完了後                                                     │
│  ┌──────────────────┐                                        │
│  │ lastRunAt 更新    │                                        │
│  │ nextRunAt 再計算  │                                        │
│  │ 実行履歴に記録    │                                        │
│  │ メモリ抽出（既存） │                                        │
│  └──────────────────┘                                        │
└─────────────────────────────────────────────────────────────┘
```

---

## データモデル

### AgentSchedule

```swift
struct AgentSchedule: Identifiable, Codable {
    let id: UUID
    var agentId: UUID                    // 対象エージェント
    var agentName: String                // エージェント名（表示用・参照用）
    var prompt: String                   // 実行時に自動送信する指示
    var scheduleType: ScheduleType       // interval / daily / weekly
    var isEnabled: Bool                  // 有効/無効
    var maxConcurrentSessions: Int       // 同時実行上限（デフォルト: 3）
    var scope: AgentScope                // .project / .user
    var lastRunAt: Date?                 // 最終実行日時
    var nextRunAt: Date?                 // 次回実行予定日時
    var createdAt: Date
}
```

### ScheduleType

```swift
enum ScheduleType: Codable, Equatable {
    case interval(minutes: Int)                        // 毎X分
    case daily(hour: Int, minute: Int)                 // 毎日X時X分
    case weekly(weekday: Int, hour: Int, minute: Int)  // 毎週X曜日X時X分
    // weekday: 1=日, 2=月, ..., 7=土 (Calendar.component 準拠)
}
```

### ScheduleRunRecord（実行履歴）

```swift
struct ScheduleRunRecord: Identifiable, Codable {
    let id: UUID
    var scheduleId: UUID
    var sessionId: UUID?          // 起動したセッションのID（スキップ時はnil）
    var status: RunStatus         // started / completed / skipped / failed
    var startedAt: Date
    var completedAt: Date?
    var skipReason: String?       // "max_concurrent_reached" など
}

enum RunStatus: String, Codable {
    case started
    case completed
    case skipped
    case failed
}
```

### AgentSession への追加

```swift
// 既存の AgentSession に追加
struct AgentSession {
    // ... 既存フィールド ...
    var isScheduled: Bool          // スケジュール起動かどうか
    var scheduleId: UUID?          // 紐づくスケジュールID
}
```

---

## サービス層

### ScheduleManager（新規）

スケジュールの管理・発火・永続化を担当する中核サービス。

```swift
@Observable @MainActor
class ScheduleManager {
    // --- State ---
    var schedules: [AgentSchedule] = []
    var runHistory: [ScheduleRunRecord] = []
    private var timer: Timer?

    // --- Dependencies ---
    private let appState: AppState   // セッション起動のため

    // --- Core Methods ---

    /// アプリ起動時に呼ばれる
    func initialize()
        // 1. schedules.json を読み込み
        // 2. Timer 開始（60秒間隔）
        // 3. キャッチアップ判定・実行

    /// Timer から60秒ごとに呼ばれる
    func checkSchedules()
        // 全スケジュールを走査
        // nextRunAt <= now && isEnabled のものを実行

    /// スケジュール発火
    func executeSchedule(_ schedule: AgentSchedule)
        // 1. 同時実行数チェック
        // 2. エージェント取得
        // 3. AppState.startScheduledAgent(schedule:) 呼び出し
        // 4. nextRunAt 再計算
        // 5. 履歴記録

    /// キャッチアップ: アプリ未起動中に見逃した実行を処理
    func catchUpMissedRuns()
        // lastRunAt < nextRunAt < now のスケジュールを検出
        // 1回だけ即時実行（溜まった分を全部実行はしない）

    // --- CRUD ---
    func addSchedule(_ schedule: AgentSchedule)
    func updateSchedule(_ schedule: AgentSchedule)
    func deleteSchedule(id: UUID)
    func toggleEnabled(id: UUID)

    // --- Persistence ---
    func save()       // schedules.json に書き出し
    func load()       // schedules.json から読み込み

    // --- Helpers ---
    func calculateNextRunAt(for schedule: AgentSchedule) -> Date
    func activeSessionCount(for scheduleId: UUID) -> Int
}
```

### AppState への追加

```swift
// AppState に追加するメソッド・プロパティ

var scheduleManager: ScheduleManager

/// スケジュールからのエージェント起動
func startScheduledAgent(schedule: AgentSchedule) {
    // 1. エージェント取得
    // 2. メモリコンテキスト構築（memoryEnabled なら）
    // 3. processManager.start(agent:memoryContext:)
    // 4. セッション作成（isScheduled: true, scheduleId: schedule.id）
    // 5. プロンプト自動送信（0.5秒待ってから sendInput）
}
```

---

## 永続化

### スケジュール定義

```
プロジェクトスコープ:
  {project}/.claude/schedules.json

ユーザースコープ:
  ~/.claude/schedules.json
```

**schedules.json の構造:**
```json
[
  {
    "id": "uuid",
    "agentId": "uuid",
    "agentName": "pr-reviewer",
    "prompt": "新しいPRがあればレビューしてください",
    "scheduleType": { "interval": { "minutes": 30 } },
    "isEnabled": true,
    "maxConcurrentSessions": 3,
    "lastRunAt": "2026-03-17T09:00:00Z",
    "nextRunAt": "2026-03-17T09:30:00Z",
    "createdAt": "2026-03-15T10:00:00Z"
  }
]
```

### 実行履歴

```
{project}/.claude/schedule-history.json
~/.claude/schedule-history.json
```

直近100件程度を保持し、古いものは自動削除。

---

## プロンプト自動送信

スケジュール起動後、エージェントにプロンプトを自動送信するフロー:

```
セッション起動
  → claude CLI の初期化待ち（プロンプトが表示されるまで）
  → waitingForInput 状態を検知
  → sendInput(sessionId:text: schedule.prompt)
```

**既存の idle 検知（1.5秒）を活用:**
- `AgentProcessManager` の `checkIdleSessions()` で `waitingForInput` に遷移
- その状態変化を `ScheduleManager` が監視
- `waitingForInput` になったら `sendInput()` で prompt を送信

**注意:**
- 初回の `waitingForInput` のみ自動送信（2回目以降は送信しない）
- エージェントが追加の質問をした場合は手動対応（or 将来的に自動応答を検討）

---

## UI

### サイドバー

```
┌─────────────────────────┐
│ 🔍 Search               │
├─────────────────────────┤
│ Agents │ Sessions │ ⏱   │  ← 新タブ「Schedules」追加
├─────────────────────────┤
│                         │
│ ▶ pr-reviewer           │
│   毎30分 ・ 次回 09:30  │
│   ● 有効                │
│                         │
│ ▶ deploy-checker        │
│   毎日 09:00 ・ 次回 明日│
│   ○ 無効                │
│                         │
│ ▶ deps-updater          │
│   毎週月 10:00           │
│   ● 有効                │
│                         │
├─────────────────────────┤
│ [+ 新規スケジュール]      │
└─────────────────────────┘
```

### スケジュール設定シート（NewScheduleSheet）

```
┌──────────────────────────────────┐
│ 新規スケジュール                    │
├──────────────────────────────────┤
│                                  │
│ エージェント:  [▼ pr-reviewer   ] │
│                                  │
│ 指示:                             │
│ ┌──────────────────────────────┐ │
│ │ 新しいPRがあればレビューして    │ │
│ │ ください                      │ │
│ └──────────────────────────────┘ │
│                                  │
│ スケジュール: [▼ 毎X分          ] │
│   間隔:      [▼ 30分           ] │
│                                  │
│ 同時実行上限: [▼ 3             ] │
│                                  │
│ スコープ:  ○ プロジェクト  ○ ユーザー │
│                                  │
│        [キャンセル]  [作成]       │
└──────────────────────────────────┘
```

### セッション一覧での表示

スケジュール起動されたセッションには ⏱ マークを表示し、通常セッションと区別する。

```
┌─────────────────────────┐
│ Sessions                │
├─────────────────────────┤
│ ⏱ pr-reviewer (09:30)  │  ← スケジュール実行
│ ⏱ pr-reviewer (09:00)  │  ← スケジュール実行
│   code-writer           │  ← 手動実行
└─────────────────────────┘
```

### スケジュール詳細・履歴ビュー（ScheduleInspectorView）

```
┌──────────────────────────────────┐
│ pr-reviewer スケジュール           │
├──────────────────────────────────┤
│ 状態: ● 有効     [無効にする]     │
│ 間隔: 毎30分                      │
│ 次回: 2026-03-17 09:30           │
│ 指示: 新しいPRがあればレビュー...  │
│                                  │
│ ── 実行履歴 ──                    │
│ 09:00  ✅ 完了 (セッション #a3f2) │
│ 08:30  ✅ 完了 (セッション #b1c4) │
│ 08:00  ⏭ スキップ (上限到達)      │
│ 07:30  ✅ 完了 (セッション #d5e6) │
│                                  │
│        [編集]  [削除]             │
└──────────────────────────────────┘
```

---

## 実装順序

### Phase 1: 基盤（モデル + サービス）

| # | タスク | ファイル | 概要 |
|---|--------|---------|------|
| 1-1 | ScheduleType モデル追加 | `Models/ScheduleType.swift` | interval / daily / weekly の enum |
| 1-2 | AgentSchedule モデル追加 | `Models/AgentSchedule.swift` | スケジュール定義 |
| 1-3 | ScheduleRunRecord モデル追加 | `Models/ScheduleRunRecord.swift` | 実行履歴 |
| 1-4 | AgentSession に isScheduled 追加 | `Models/AgentSession.swift` | 既存モデル拡張 |
| 1-5 | ScheduleManager 実装 | `Services/ScheduleManager.swift` | CRUD + 永続化 + Timer + 発火ロジック |
| 1-6 | AppState にスケジュール起動メソッド追加 | `ViewModels/AppState.swift` | `startScheduledAgent()` + ScheduleManager 統合 |

### Phase 2: プロンプト自動送信

| # | タスク | ファイル | 概要 |
|---|--------|---------|------|
| 2-1 | waitingForInput 検知→自動送信 | `Services/ScheduleManager.swift` | 初回 idle 検知時に prompt を sendInput |
| 2-2 | 自動送信の1回制限 | `Services/AgentProcessManager.swift` | isScheduled セッションの初回のみ送信するフラグ管理 |

### Phase 3: UI

| # | タスク | ファイル | 概要 |
|---|--------|---------|------|
| 3-1 | NewScheduleSheet | `Views/Schedule/NewScheduleSheet.swift` | スケジュール作成シート |
| 3-2 | ScheduleListView | `Views/Schedule/ScheduleListView.swift` | サイドバーのスケジュール一覧 |
| 3-3 | ScheduleInspectorView | `Views/Schedule/ScheduleInspectorView.swift` | 詳細・履歴表示 |
| 3-4 | ScheduleRowView | `Views/Schedule/ScheduleRowView.swift` | 一覧の各行 |
| 3-5 | サイドバーにタブ追加 | `Views/Sidebar/SidebarView.swift` | Schedules タブ追加 |
| 3-6 | セッション行にスケジュールマーク | `Views/Sidebar/AgentRowView.swift` | ⏱ 表示 |

### Phase 4: キャッチアップ + 履歴管理

| # | タスク | ファイル | 概要 |
|---|--------|---------|------|
| 4-1 | キャッチアップ実行 | `Services/ScheduleManager.swift` | アプリ起動時の見逃し実行 |
| 4-2 | 履歴の永続化 | `Services/ScheduleManager.swift` | schedule-history.json 読み書き |
| 4-3 | 履歴の自動クリーンアップ | `Services/ScheduleManager.swift` | 100件超過分の削除 |

---

## 既存コードへの影響

| ファイル | 変更内容 |
|---------|---------|
| `Models/AgentSession.swift` | `isScheduled`, `scheduleId` フィールド追加 |
| `Models/Enums.swift` | `SidebarTab` に `.schedules` 追加 |
| `ViewModels/AppState.swift` | `scheduleManager` プロパティ追加、`startScheduledAgent()` メソッド追加、初期化時に ScheduleManager 起動 |
| `Views/Sidebar/SidebarView.swift` | Schedules タブ追加 |
| `Views/Sidebar/AgentRowView.swift` | スケジュールセッションの表示区別 |
| `Views/ContentView.swift` | スケジュール関連ペインの表示分岐追加 |
| `App/ConclawdApp.swift` | アプリ終了時に ScheduleManager の Timer 停止 |

---

## 将来の拡張候補（今回はスコープ外）

- **cron式サポート**: 「平日の営業時間だけ」など柔軟な指定
- **ヘッドレス実行**: UI表示なしのバックグラウンド実行モード
- **プロンプトテンプレート**: `{{date}}`, `{{time}}` などの動的変数
- **条件付き実行**: 「PRが存在する場合のみ」などの前提条件
- **通知**: スケジュール実行の完了/失敗をmacOS通知で知らせる
- **launchd連携**: アプリ未起動でもスケジュール実行
- **自動応答**: エージェントからの質問に自動で応答するポリシー
