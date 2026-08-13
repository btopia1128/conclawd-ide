# メインビュー2枠スプリット化 実装計画

## 概要

現在1つしかないメインビュー（`TerminalTabView`）を2枠まで横に並べて表示できるようにする。各枠は独立したタブ列・選択状態・センターペインを持ち、片方でターミナルを動かしながらもう片方でファイル編集や Settings を開けるようにする。

本計画は **タスクA（スプリット本体）** と **タスクB（既読挙動 latent fix）** の2本立てで進める。タスクBは独立しており、タスクAの完了を待たずに着手可能だが、既読仕様のリグレッション原因切り分けを容易にするためタスクA完了後に実施する。

---

## 前提と制約

### SwiftTerm の単一 NSView 制約
- `AgentProcessManager.terminalViews[sessionId]` は session : NSView = 1 : 1
- `TerminalHostView.showTerminal(for:)` は NSView を `addSubview` / `removeFromSuperview` で物理的に付け替える
- → **同一セッションを2枠同時表示することは不可能**。データ構造レベルで排他を保証する

### 既読判定の現状（調査済み）
- `AgentProcess.hasUnreadOutput: Bool`（`Conclawd/Models/AgentProcess.swift:16`）
- `AgentProcessManager.viewingSessionId: UUID?` 単一値（`AgentProcessManager.swift:34`）
- unread 立ち上げ：`checkIdleSessions()` のアイドル検知（2.5秒）で `sessionId != viewingSessionId` の時のみ（`AgentProcessManager.swift:729-732`）
- 既読化：`AppState.selectedSessionId.didSet` のみ（`AppState.swift:98-112`）
- chat セッションには unread 機構が存在しない（`ChatSessionManager` に unread 系プロパティなし）
- **centerPane は既読判定に一切関与していない**（Settings/Editor 中も最後のセッションは viewed 扱い）→ タスクB で扱う

### 設計の合意事項
- 2枠固定（primary / secondary、横分割のみ）
- 同一セッション複製表示は不要
- スプリット解除時は secondary の全タブを primary にマージ（状態保持）
- タスクA では既読の現状仕様（centerPane 無関係）をそのまま温存

---

## タスクA：スプリット本体

### A-1. データモデル

#### `PaneState`（新規、値型）

`Conclawd/ViewModels/PaneState.swift` に新規追加。

```swift
enum PaneID: String, Codable { case primary, secondary }

struct PaneState {
    let id: PaneID
    var centerPane: AppState.CenterPane = .terminal
    var selectedSessionId: UUID?
    var selectedFileId: UUID?
    var selectedAgentId: UUID?      // Inspector をアクティブペイン追従にするため
    var selectedSkillId: UUID?

    // 各エディタタブの開閉状態
    var orgChartTabOpen: Bool = false
    var agentEditorTabOpen: Bool = false
    var agentEditorTabName: String?
    var skillEditorTabOpen: Bool = false
    var skillEditorTabName: String?
    var scheduleEditorTabOpen: Bool = false
    var scheduleEditorTabName: String?
    var settingsTabOpen: Bool = false

    // エディタの付随状態
    var viewingBundledFileURL: URL?
    var editingSchedule: AgentSchedule?
    var editingCloudTrigger: CloudTrigger?
}
```

#### `AgentSession` / `OpenFile` への `paneId` 追加

```swift
struct AgentSession {
    // ...既存フィールド
    var paneId: PaneID = .primary    // 所属ペイン
}

struct OpenFile {
    // ...既存フィールド
    var paneId: PaneID = .primary
}
```

- `paneId` はランタイム属性。永続化（SessionHistory等）対象外
- デフォルト値により既存コードの `AgentSession(id:...)` 初期化は変更不要
- これで「同一セッションは1ペインにのみ存在」をデータ構造で保証

#### グローバル据え置き
- `activeSessions: [AgentSession]` / `openFiles: [OpenFile]` 本体はグローバルのまま
- `chatManagers: [UUID: ChatSessionManager]` もグローバル
- `editingAgent` / `editingSkill` / `editingAgentContent` / `agentEditorHasChanges` などの編集バッファ本体もグローバル据え置き（Phase 1）
  - 不足時は Phase 2 で PaneState 化を検討

### A-2. `AppState` の書き換え

#### 新規プロパティ
```swift
var primaryPane = PaneState(id: .primary)
var secondaryPane: PaneState?            // nil = 非スプリット
var activePaneId: PaneID = .primary
```

#### 廃止
- `var selectedSessionId: UUID?`（didSet ごと削除 → `PaneState.selectedSessionId` に移動）
- `var selectedFileId: UUID?`
- `var selectedAgentId: UUID?`
- `var selectedSkillId: UUID?`
- `var centerPane: CenterPane`
- 各 `*TabOpen` / `*TabName` フラグ
- `viewingBundledFileURL`
- `editingSchedule` / `editingCloudTrigger`

#### 後方互換アクセサ（薄いフォワーディング）
既存の呼び出し元を一気に書き換える前の段階では、アクティブペインへの薄いフォワーディングを残すのが現実的。
```swift
var selectedSessionId: UUID? {
    get { activePane.selectedSessionId }
    set { updatePane(activePaneId) { $0.selectedSessionId = newValue } }
}
var centerPane: CenterPane {
    get { activePane.centerPane }
    set { updatePane(activePaneId) { $0.centerPane = newValue } }
}
// ... 他も同様
```
Phase 段階で全呼び出し元を明示的な `updatePane(_:mutate:)` へ移行し、最終的にこれらのフォワーディングを削除する。

#### 集中ヘルパ `updatePane`
```swift
private func updatePane(_ id: PaneID, mutate: (inout PaneState) -> Void) {
    let oldVisible = visibleSessionIds
    switch id {
    case .primary:   mutate(&primaryPane)
    case .secondary:
        guard var pane = secondaryPane else { return }
        mutate(&pane)
        secondaryPane = pane
    }
    applyVisibilityChange(old: oldVisible)
}

private func applyVisibilityChange(old: Set<UUID>) {
    let new = visibleSessionIds
    guard old != new else { return }
    let gained = new.subtracting(old)
    Task { @MainActor [weak self] in
        guard let self else { return }
        for id in gained { self.processManager.markAsRead(sessionId: id) }
        self.processManager.viewingSessionIds = new
    }
}

var visibleSessionIds: Set<UUID> {
    var ids = Set<UUID>()
    if let sid = primaryPane.selectedSessionId { ids.insert(sid) }
    if let sid = secondaryPane?.selectedSessionId { ids.insert(sid) }
    return ids
}

var activePane: PaneState {
    activePaneId == .primary ? primaryPane : (secondaryPane ?? primaryPane)
}
```

- `updatePane` を通らない直接代入を原則禁止にする（後方互換アクセサも内部でこれを呼ぶ）
- `selectedSessionId.didSet` を廃止して markAsRead をここに集約

#### `AppState` 内の書き換え箇所マップ

直接代入箇所を機能別に分類。**代入先ペインの決定ルール**：
- **A: アクティブペイン固定**（`activePaneId` に流す） — ユーザー起点の操作
- **P: primary 固定** — 初期化・起動時のデフォルト
- **S: その場の文脈に応じたペイン指定** — 呼び出し元からペインIDを渡す

| 行 | 関数 | 現状 | ルール | 備考 |
|---|---|---|---|---|
| 727-732 | `selectAgent(_)` | `selectedAgentId` / `selectedSkillId` / 条件付き `centerPane=.terminal` | **A** | サイドバークリック起点 |
| 739-745 | `selectSkill(_)` | `selectedSkillId` / `skillEditorTabOpen` / `centerPane=.skillEditor` | **A** | 同上 |
| 911-912 | `removeAgent` | `selectedAgentId = agents.first?.id` | **A** | 削除後のフォールバック |
| 1014-1021 | `showAgentEditor` | `agentEditorTabOpen` / `centerPane=.agentEditor` | **A** | |
| 1043-1053 | `closeAgentEditor` | `agentEditorTabOpen=false` / 条件付き `centerPane=.terminal` | **S** | **閉じたペインを明示**（primary/secondary 両対応） |
| 1057-1068 | `closeSkillEditor` | `skillEditorTabOpen=false` / `selectedSkillId=nil` / 条件付き `centerPane=.terminal` | **S** | 同上 |
| 1072-1081 | `showScheduleEditor` | `scheduleEditorTabOpen` / `centerPane=.scheduleEditor` | **A** | |
| 1085-1092 | `closeScheduleEditor` | `scheduleEditorTabOpen=false` / 条件付き `centerPane=.terminal` | **S** | |
| 1098-1107 | `showCloudTriggerEditor` | 同上 | **A** | |
| 1247-1273 | `openFile(url:)` | `selectedFileId` / `centerPane=.fileEditor` | **A** | `openFiles` に `paneId=activePaneId` を付与 |
| 1285-1293 | `closeFileTab` | `selectedFileId` / 条件付き `centerPane=.terminal` | **S** | ファイルが所属するペインで閉じる |
| 1414-1421 | `startCreationSession` | `selectedSessionId` / `selectedAgentId=nil` / `centerPane=.terminal` | **A** | 新規セッションは `paneId=activePaneId` で作成 |
| 1440-1441 | `endCreationSession` | `selectedSessionId = activeSessions.last?.id` | **S** | 閉じたセッションが所属するペインで次を選ぶ |
| 1500-1510 | `startSkillCreationSession` | 同上 | **A** | |
| 1640-1692 | `startStandaloneSession` 系 | `selectedSessionId` / `centerPane=.terminal` | **A** | |
| 1844-1845 | `startManualSession` | 同上 | **A** | |
| 1887-1888 | `startShellSession` | 同上 | **A** | |
| 1932-1933 | `startPresetSession` 経由 | 同上 | **A** | |
| 2051-2053 | `startAgent` | 同上 | **A** | |
| 2095-2097 | `startChatSession` | 同上 | **A** | chat セッションも `paneId=activePaneId` |
| 2161-2163 | `resumeSession` | 同上 | **S** | **resume対象セッションの所属ペインを維持**（セッションの `paneId` をそのまま使う） |
| 2247-2250 | `resumeFromHistory` | 同上 | **A** | 履歴からの新規起動は active ペイン |
| 2296-2297 | `forkSession` | 同上 | **A** | |
| 2349-2352 | `forkFromHistory` | 同上 | **A** | |
| 2363-2367 | `selectSessionByIndex` | 同上 | **S** | `⌘1-9` はセッションを**所属ペインで選択**＋フォーカスをそのペインへ |
| 2385-2388 | `closeTab`（shell） | `selectedSessionId=activeSessions.last?.id` | **S** | 閉じたセッションが所属するペインで次を選ぶ |
| 2400-2403 | `closeTab`（chat） | 同上 | **S** | |
| 2438-2441 | `closeTab`（通常） | 同上 | **S** | |
| 2516-2549 | `reloadSkills`（selectedSkillId復元） | `selectedSkillId = ...` | **A** | |
| 2571-2572 | `removeSkill` | `selectedSkillId = nil` | **A** | |
| 2653-2657 | `shareContext` | `selectedSessionId=targetSessionId` / `centerPane=.terminal` | **S** | target セッションの所属ペインに切替 |

**ルール適用時の注意**
- **S ルール（所属ペイン追従）** は `activeSessions.first(where: { $0.id == sessionId })?.paneId` で引く補助関数 `paneOwning(sessionId:)` / `paneOwning(fileId:)` を用意して一貫させる
- クローズ時は「閉じたあと `activeSessions.last?.id` を拾う」のではなく、**同一ペインの最後のセッションを拾う**ように変更する必要がある：
  ```swift
  let nextId = activeSessions.last(where: { $0.paneId == ownerPaneId })?.id
  ```
- `⌘1-9` のタブインデックスはどうする？
  - 案: 全ペインのタブをフラットに数える → 操作がペインを跨げて便利だが混乱の元
  - 推奨: **アクティブペイン内のインデックス**で拾う

### A-3. ビュー層の書き換え

#### `ContentView.swift`
```swift
HStack(spacing: 0) {
    // 左サイドバー（変更なし）

    // 中央：HSplitView（スプリット時）
    if let secondary = appState.secondaryPane {
        HSplitView {
            MainPaneView(pane: $appState.primaryPane)
                .frame(minWidth: 400)
            MainPaneView(pane: Binding(get: { secondary }, set: { appState.secondaryPane = $0 }))
                .frame(minWidth: 400)
        }
    } else {
        MainPaneView(pane: $appState.primaryPane)
    }

    // Inspector（activePane に追従）
    if showInspector { InspectorRouter(...) }
}
```

- `HSplitView` or 自前 Divider + 幅保持（`@State` の `secondaryPaneWidth`）
- アクティブペインの視覚フィードバック：タブバー下に細いアクセントライン、またはペイン全体に薄い border

#### `TerminalTabView.swift` → `MainPaneView` にリネーム
- `@Environment(AppState)` から `@Binding var pane: PaneState` 駆動に変更
- タブ列のフィルタ：
  ```swift
  let paneSessions = appState.activeSessions.filter { $0.paneId == pane.id }
  let paneFiles = appState.openFiles.filter { $0.paneId == pane.id }
  ```
- ZStack 内の各 branch は `pane.centerPane` / `pane.selectedSessionId` / `pane.*TabOpen` を参照
- `.id("agent-editor-\(pane.id.rawValue)-\(editorShowLineNumbers)-\(editorWordWrap)")` — 2枠で同時にエディタを開く場合にビュー共有しないよう**ペインIDをキーに混ぜる**
- タブクリック / 右クリック時は `appState.activePaneId = pane.id` を更新してフォーカス切替
- 背景領域クリック（Gesture）でもフォーカス切替

#### `InspectorRouter`
- `appState.activePane.selectedAgentId` / `selectedSkillId` を参照するよう変更

#### `TopBarView.swift`
- スプリット/解除ボタンを追加：
  ```swift
  Button {
      if appState.secondaryPane == nil {
          appState.openSecondaryPane()
      } else {
          appState.closeSecondaryPane()
      }
  } label: {
      Image(systemName: appState.secondaryPane == nil
          ? "rectangle.split.2x1"
          : "rectangle")
  }
  ```

#### `SidebarView.swift`
- クリックハンドラから呼ぶ AppState API を `openFileInEditor(url)` のように引数なしで呼ぶ形のまま
- AppState 側で `activePaneId` にルーティングされる
- **既読インジケータの表示ロジックは完全に変更不要**（`processes[id]?.hasUnreadOutput` を見るだけなので）

### A-4. スプリット操作 API

```swift
extension AppState {
    /// 右側ペインを開く。sessionId 指定時はそのセッションを右側に移動。
    func openSecondaryPane(movingSessionId: UUID? = nil) {
        var secondary = PaneState(id: .secondary)
        if let sid = movingSessionId,
           let idx = activeSessions.firstIndex(where: { $0.id == sid }) {
            activeSessions[idx].paneId = .secondary
            secondary.selectedSessionId = sid
            secondary.centerPane = .terminal
        }
        secondaryPane = secondary
        activePaneId = .secondary
        applyVisibilityChange(old: /* 変化前の visibleSessionIds */)
    }

    /// 右側ペインを閉じる。タブはすべて primary にマージ。
    func closeSecondaryPane() {
        guard secondaryPane != nil else { return }
        let old = visibleSessionIds
        for i in activeSessions.indices where activeSessions[i].paneId == .secondary {
            activeSessions[i].paneId = .primary
        }
        for i in openFiles.indices where openFiles[i].paneId == .secondary {
            openFiles[i].paneId = .primary
        }
        secondaryPane = nil
        activePaneId = .primary
        applyVisibilityChange(old: old)
    }

    /// 既に他ペインにあるセッションを開く要求：フォーカスだけそちらに移す（reveal 相当）
    func revealSessionInItsPane(sessionId: UUID) {
        guard let owner = activeSessions.first(where: { $0.id == sessionId })?.paneId
        else { return }
        activePaneId = owner
        updatePane(owner) {
            $0.selectedSessionId = sessionId
            $0.centerPane = .terminal
        }
    }
}
```

### A-5. `AgentProcessManager` の変更

```swift
// Before
var viewingSessionId: UUID?

// After
var viewingSessionIds: Set<UUID> = []

// checkIdleSessions 内
if !viewingSessionIds.contains(sessionId) {
    process.hasUnreadOutput = true
}
```

- `markAsRead(sessionId:)` はシグネチャ変更なし
- 呼び出し元は `AppState.applyVisibilityChange` のみ（他は全廃止）

### A-6. 影響ファイル一覧

| ファイル | 変更内容 | 規模 |
|---|---|---|
| `Models/PaneState.swift` | 新規作成 | 新規 |
| `Models/AgentSession.swift` | `paneId` 追加 | 小 |
| `Models/OpenFile.swift` | `paneId` 追加 | 小 |
| `ViewModels/AppState.swift` | `primaryPane`/`secondaryPane` 導入、約40箇所の代入書き換え、`updatePane` 集中ヘルパ、スプリット操作 API | 大 |
| `Services/AgentProcessManager.swift` | `viewingSessionId` → `viewingSessionIds`（小） | 小 |
| `Views/ContentView.swift` | 中央領域を HSplitView 対応 | 小 |
| `Views/Terminal/TerminalTabView.swift` → `MainPaneView.swift`（リネーム推奨） | `PaneState` バインディング駆動化、タブフィルタ、ID suffix、フォーカス更新 | 中〜大 |
| `Views/TopBarView.swift` | スプリット/解除ボタン追加 | 小 |
| `Views/ContentView.swift` 内 `InspectorRouter` | `activePane` 参照に変更 | 小 |
| `Views/Sidebar/SidebarView.swift` | **ほぼ変更なし**（ルーティングは AppState 側） | なし |

### A-7. フェーズ分割

一度に全部変えずに、ビルドが通る状態を維持しながら進める。

#### Phase A-1: `PaneState` 抽出（UI見た目は変わらない）
- `PaneState` / `PaneID` 追加
- `primaryPane: PaneState` を追加、`secondaryPane: nil` 固定
- `AppState` 上の各プロパティを `primaryPane` へのフォワーディングに
- `AgentSession` / `OpenFile` に `paneId` 追加（デフォルト `.primary`）
- `AgentProcessManager.viewingSessionIds: Set<UUID>` に変更
- `AppState.updatePane` / `applyVisibilityChange` / `visibleSessionIds` 導入
- `selectedSessionId.didSet` 廃止 → `applyVisibilityChange` に移行
- **この時点で動作は完全に従来通り**。リファクタのみ

#### Phase A-2: `MainPaneView` バインディング駆動化
- `TerminalTabView` を `@Binding var pane: PaneState` で動くよう書き換え
- タブ列は `appState.activeSessions.filter { $0.paneId == pane.id }`（まだ全部 `.primary`）
- ContentView から `MainPaneView(pane: $appState.primaryPane)` として渡す
- `.id("...")` にペインID suffix を入れる
- **この時点でも UI は従来通り**

#### Phase A-3: `AppState` の書き換え箇所を updatePane ベースに
- A-2 のマップに従って、書き換えルールに基づいて全ての `centerPane =` / `selectedSessionId =` 等を `updatePane(activePaneId)` 経由に置換
- クローズ系は `paneOwning(sessionId:)` ヘルパで所属ペイン解決
- 後方互換フォワーディングを徐々に削除
- **この時点でも UI は従来通り**（`secondaryPane == nil` のまま）

#### Phase A-4: secondaryPane 有効化 + UI分割
- `openSecondaryPane` / `closeSecondaryPane` / `revealSessionInItsPane` 実装
- `ContentView` に HSplitView 分岐を入れる
- `TopBarView` にスプリットボタン追加
- タブ右クリックメニューに "Open in Right Pane" 追加
- フォーカス切替（ペインクリック / `activePaneId` 更新）
- Inspector を activePane 追従に

#### Phase A-5: 仕上げ
- D&D でタブを別ペインに移動（`onDrag` / `onDrop` で `paneId` 更新）
- スプリット時の幅保存（`@State` で十分、永続化は後回し）
- キーボードショートカット（`⌘\` でトグル、必要なら `⌘⌥→/←` でペイン切替）
- 手動 QA：サイドバー既読ドット、⌘1-9、`shareContext`、`forkSession`、resume、履歴からの起動、creation session 全パス

### A-8. リスク・注意点

- **SwiftTerm NSView の付け替え**：2枠それぞれが独自の `TerminalHostView` を持つ。同一 sessionId が両方に渡ることがないよう `paneId` ユニーク制約を徹底する。万一渡っても `TerminalHostView.showTerminal(for:)` の前半の early-return が効かずに `superview` が片方から奪われる → 視覚的に「ターミナルが片方から消える」バグが起きる可能性
- **`.id("agent-editor-\(editorShowLineNumbers)-\(editorWordWrap)")`** のような force-reinit キー：ペインID suffix 必須。忘れると SwiftUI がビューを共有して壊れる
- **`shareContext` の画面遷移**：ターゲットセッションが別ペインにある場合、`activePaneId` をターゲット側に切り替えて表示する（移動はしない）
- **`resumeSession`**：停止したセッションはもう1枠にある可能性がある（D&D で移動後に停止した場合）。所属ペインを維持したまま resume するのが自然
- **`reloadAgents` / `reloadSkills` 後の UUID 変更**：現状 `syncSelectedAgentId()` で処理しているが、これを各ペインに対して実行する必要がある
- **PaneState が値型なので `Binding<PaneState>` の更新 = 親の書き換え**：`updatePane` 経由で一元化することで副作用トリガも一元化される。直接 `primaryPane.xxx = ...` を呼ぶと `applyVisibilityChange` が走らないので禁止
- **Observable 再描画範囲の拡大**：`primaryPane` / `secondaryPane` を値型で持つと、ペイン内部の小さな変更でも `@Observable` が AppState 全体に変更通知を出す。パフォーマンス計測後、必要なら `@Observable` を `PaneState` 自体に付けて参照型化することも検討

---

## タスクB：既読挙動 latent fix（切り出しタスク）

### 現状の問題
- `centerPane` を `.settings` / `.fileEditor` / `.agentEditor` 等に切り替えても、`viewingSessionId` は前回の `selectedSessionId` のまま
- → Settings を開いたまま放置中にエージェントが応答を出しても、`idleTick` の `sessionId != viewingSessionId` 判定が false になり、**unread インジケータが立たない**
- 「本当にターミナルを見ている」ことと「最後に選択したセッション」が区別されていない

### 修正方針

タスクA完了後、`visibleSessionIds` の定義を変更するだけで済むよう設計されている。

```swift
// タスクAの時点
var visibleSessionIds: Set<UUID> {
    var ids = Set<UUID>()
    if let sid = primaryPane.selectedSessionId { ids.insert(sid) }
    if let sid = secondaryPane?.selectedSessionId { ids.insert(sid) }
    return ids
}

// タスクBで以下に変更
var visibleSessionIds: Set<UUID> {
    var ids = Set<UUID>()
    if primaryPane.centerPane == .terminal,
       let sid = primaryPane.selectedSessionId { ids.insert(sid) }
    if let sec = secondaryPane,
       sec.centerPane == .terminal,
       let sid = sec.selectedSessionId { ids.insert(sid) }
    return ids
}
```

`updatePane` 経由で centerPane 変更時にも `applyVisibilityChange` が走るため、追加のトリガ配線は不要。

### 検討事項
- **chat モードも viewing に含めるか**：chat セッションには現状 unread 機構がないので、`== .terminal` だけで実害なし。ただし将来 chat に unread を入れるなら `|| == .chat` も同時に条件に入れるべき
- **タブフォーカス（NSWindow の isKeyWindow）も条件に入れるか**：アプリ自体がバックグラウンドの時は「見ていない」と判定するか。現状は判定しない。タスクBのスコープでは取り込まない（別タスク候補）
- **起動時の初期状態**：アプリ起動直後で `centerPane == .terminal` だが `selectedSessionId == nil` の時は `visibleSessionIds` が空 → 正しい挙動（何も見ていない）

### 影響ファイル
| ファイル | 変更内容 |
|---|---|
| `ViewModels/AppState.swift` | `visibleSessionIds` の定義に `centerPane == .terminal` 条件を追加 |

### 手動 QA
- Settings を開いた状態でエージェントから応答 → サイドバーに unread ドット出現
- Agent Editor を開いた状態でもう1つのセッションのエージェントから応答 → 両方のセッション（現行セッションはエディタで隠れている）に適切に unread 判定
- スプリット状態で primary がターミナル、secondary が Settings の場合：primary のセッションは viewed、secondary 側で最後に見たセッションは unread 対象
- `openSecondaryPane` で secondary にセッションを移動後、即座に markAsRead が走る
- `closeSecondaryPane` でマージ後、primary でアクティブになったセッションは markAsRead が走る

### 実施タイミング
- タスクAの Phase A-4 完了後（スプリットが動作する状態）に着手
- タスクBの変更は1行〜数行なので、**別PRで明示的に切る**ことでリグレッション混入時の原因切り分けを容易にする

---

## 合意ポイント（実装着手前に最終確認）

1. **編集バッファ（`editingAgent` / `editingSkill` / `editingAgentContent`）はグローバル据え置き**（Phase 1）でOKか？ → 2枠で同時に別々のエージェントを編集するユースケースが薄ければ温存
2. **`⌘1-9` はアクティブペイン内インデックス**でOKか？ → 全ペインフラット案は混乱の元
3. **スプリット時の初期幅** は 50:50 固定 or ユーザー調整可能 or 直前の幅を保存？ → Phase A-4 で 50:50 固定、Phase A-5 で `@State` に保存
4. **永続化**（再起動時のスプリット状態復元）は初期リリースで対応するか？ → Phase 1 のスコープ外、別タスク
5. **タブ D&D によるペイン間移動** は Phase A-4 と A-5 のどちらで入れるか？ → A-5 推奨（コア動作を先に安定させる）
