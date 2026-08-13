# Conclawd 実装計画

## プロジェクト構造

```
Conclawd/
├── Conclawd.xcodeproj
├── Conclawd/
│   ├── App/
│   │   └── ConclawdApp.swift                # エントリポイント
│   ├── Models/
│   │   ├── Agent.swift                       # エージェント定義モデル
│   │   ├── AgentRelation.swift               # 親子関係モデル
│   │   ├── AgentProcess.swift                # ランタイム状態モデル
│   │   ├── Project.swift                     # プロジェクトモデル
│   │   └── Enums.swift                       # AgentModel, AgentColor, etc.
│   ├── Views/
│   │   ├── ContentView.swift                 # 3カラムレイアウト
│   │   ├── Sidebar/
│   │   │   ├── SidebarView.swift             # サイドバー全体
│   │   │   └── AgentRowView.swift            # エージェント行
│   │   ├── Terminal/
│   │   │   ├── TerminalTabView.swift         # タブ式ターミナル
│   │   │   └── TerminalNSViewRepresentable.swift  # SwiftTerm ラッパー
│   │   ├── OrgChart/
│   │   │   ├── OrgChartView.swift            # 組織図全体
│   │   │   ├── OrgChartCanvasView.swift      # キャンバス描画
│   │   │   ├── AgentNodeView.swift           # ノード表示
│   │   │   └── EdgeShape.swift               # エッジ描画
│   │   ├── Settings/
│   │   │   ├── AgentInspectorView.swift      # エージェント設定パネル
│   │   │   └── NewAgentSheet.swift           # 新規作成シート
│   │   └── Preferences/
│   │       └── PreferencesView.swift         # アプリ環境設定
│   ├── ViewModels/
│   │   ├── AppState.swift                    # アプリ全体状態
│   │   └── OrgChartViewModel.swift           # 組織図状態
│   ├── Services/
│   │   ├── AgentConfigService.swift          # 設定ファイル読み書き
│   │   ├── AgentProcessManager.swift         # プロセス管理
│   │   ├── AgentRelationService.swift        # 親子関係の抽出・更新
│   │   ├── FileWatcherService.swift          # ファイル変更監視
│   │   └── ClaudePathResolver.swift          # claude バイナリ検出
│   └── Resources/
│       └── Assets.xcassets
└── ConclawdTests/
    ├── Models/
    │   └── AgentTests.swift
    ├── Services/
    │   ├── AgentConfigServiceTests.swift
    │   └── AgentRelationServiceTests.swift
    └── Helpers/
        └── TestFixtures.swift
```

---

## Phase 1: 基盤構築（Week 1-3）

**マイルストーン**: アプリが起動し、`claude` プロセスを PTY で実行してターミナルに表示できる。

### P1-T1: Xcode プロジェクトセットアップ

- `Conclawd.xcodeproj` 作成（SwiftUI App ライフサイクル）
- ターゲット: macOS 14+ (Sonoma)
- Swift Package 追加:
  - SwiftTerm: `https://github.com/migueldeicaza/SwiftTerm`
  - Yams: `https://github.com/jpsim/Yams`
- App Sandbox: 無効化（Signing & Capabilities で削除）
- フォルダ構造作成: App/, Models/, Views/, Services/, ViewModels/

### P1-T2: SwiftTerm の NSViewRepresentable ラッパー

- `TerminalNSViewRepresentable.swift` 作成
- `NSViewRepresentable` で `LocalProcessTerminalView` をラップ
- `makeNSView` / `updateNSView` ライフサイクル実装
- `LocalProcessTerminalViewDelegate` コールバック処理:
  - `processTerminated`: プロセス終了検知
  - `sizeChanged`: ターミナルサイズ変更
  - `setTerminalTitle`: タブタイトル更新
  - `hostCurrentDirectoryUpdate`: CWD 変更通知
- フォント・カラー・サイズの設定を SwiftUI 環境から受け取り

### P1-T3: 基本アプリシェル

- `ConclawdApp.swift`: `@main` エントリポイント、`WindowGroup`
- `ContentView.swift`: `NavigationSplitView` で3カラムレイアウト
  - 左: プレースホルダーサイドバー（ハードコード）
  - 中央: `TerminalNSViewRepresentable` で単一セッション表示
  - 右: プレースホルダー設定パネル
- ツールバーにプロジェクト名表示

### P1-T4: Agent モデルとファイルパーサー

- `Agent.swift`: セクション4.1の全フィールド定義
- `AgentConfigService.swift`:
  - `loadAgents(projectDir: URL) -> [Agent]`: `.claude/agents/` をスキャン、各 `.md` をパース
  - `loadUserAgents() -> [Agent]`: `~/.claude/agents/` をスキャン
  - `saveAgent(_ agent: Agent)`: frontmatter + マークダウン本文にシリアライズして書き出し
- YAML frontmatter パース: Yams を使用（`---` で分割後、YAML 部分をデコード）
- frontmatter シリアライズ: モデル → YAML 文字列 → ファイル書き出し

### P1-T5: 統合確認（手動テスト）

- アプリ起動 → ターミナル表示 → `claude --agent <name>` が実行されることを確認
- ターミナル入出力動作確認（ユーザー入力、Claude 応答表示）
- プロセス終了の検知確認

---

## Phase 2: エージェント管理（Week 4-6）

**マイルストーン**: エージェントの一覧表示・作成・編集・削除がGUIで可能。実行/停止のステータスが表示される。

### P2-T1: AppState（アプリ全体状態管理）

- `AppState.swift` を `@Observable` クラスとして作成
- プロパティ:
  - `projects: [Project]`
  - `selectedProject: Project?`
  - `agents: [Agent]`
  - `selectedAgentId: UUID?`
  - `runningProcesses: [UUID: AgentProcess]`
- メソッド:
  - `loadProject(_:)`: プロジェクト読み込み、エージェント再スキャン
  - `selectAgent(_:)`: 選択状態更新
  - `startAgent(_:)`: エージェント起動
  - `stopAgent(_:)`: エージェント停止
- SwiftUI Environment で注入

### P2-T2: サイドバー

- `SidebarView.swift`: スコープ別グループ（プロジェクト / ユーザー）でエージェント一覧
- `AgentRowView.swift`: 名前、カラードット、ステータスインジケータ
- ステータスは `runningProcesses` にバインド
- 選択は `selectedAgentId` にバインド
- 下部に「+」ボタン（新規エージェント作成）
- 右クリックコンテキストメニュー（起動 / 停止 / 編集 / 削除）

### P2-T3: エージェント設定パネル（インスペクタ）

- `AgentInspectorView.swift`: フォーム形式のエディタ
- テキストフィールド: name, description
- ドロップダウン: model（enum ケース）
- カラーセレクタ: agent color
- リストエディタ: tools, disallowedTools, skills（項目追加/削除）
- ドロップダウン: permissionMode
- 複数行テキストエディタ: systemPrompt（マークダウン本文）
- 「保存」→ `AgentConfigService.saveAgent(_:)` 呼び出し
- 「元に戻す」→ ディスクから再読み込み

### P2-T4: エージェント作成フロー

- 「New Agent」シート/ポップオーバー
- 最低限のフィールド: name, description, model
- `.claude/agents/<name>.md` にファイル作成
- 作成後即座にエージェント一覧に追加

### P2-T5: エージェント削除

- 確認ダイアログ表示
- ディスク上の `.md` ファイル削除
- エージェント一覧から除去
- 実行中の場合はプロセス停止

### P2-T6: プロセスマネージャー

- `AgentProcessManager.swift` を `@Observable` クラスとして作成
- `[UUID: AgentProcess]` 辞書でランニングエージェントを管理
- `start(agent:)`: `LocalProcessTerminalView` 生成、`startProcess` 呼び出し、プロセス情報保存
- `stop(agentId:)`: プロセスに `terminate()` 送信
- `processTerminated` デリゲートでステータス更新
- 公開メソッド: `isRunning(agentId:)`, `status(agentId:)`

### P2-T7: ターミナルタブ管理

- `TerminalTabView.swift`: `TabView` で起動済みエージェントごとにタブ表示
- 各タブに `TerminalNSViewRepresentable` を紐付け
- エージェント起動時にタブ出現、停止後も最終出力を保持
- タブ閉じるボタン

### P2-T8: プロジェクトセレクタ

- `ProjectSelectorView.swift`: ドロップダウンまたはポップオーバー
- 「プロジェクトを開く...」→ フォルダピッカー（NSOpenPanel）
- 最近のプロジェクトを UserDefaults に保存
- プロジェクト切替 → `AppState.loadProject(_:)` → エージェント再スキャン

---

## Phase 3: 組織図（Week 7-9）

**マイルストーン**: エージェント間の親子関係を視覚的に表示・編集できる。

### P3-T1: AgentRelation モデルとサービス

- `AgentRelation.swift`: `parentAgentId` + `childAgentId`
- `AgentRelationService.swift`:
  - `extractRelations(agents: [Agent]) -> [AgentRelation]`: `tools` 配列から `Agent(...)` パターンを抽出
  - `addRelation(parent:child:)`: 親の tools 配列を更新、ディスクに保存
  - `removeRelation(parent:child:)`: Agent 参照を除去、ディスクに保存
  - 循環参照の検証

### P3-T2: 組織図ビューモデル

- `OrgChartViewModel.swift` (`@Observable`):
  - `nodes: [OrgChartNode]` — id, position (CGPoint), agent 参照
  - `edges: [OrgChartEdge]` — source node id, target node id
  - agents + relations から算出
  - `autoLayout()`: ツリーレイアウトアルゴリズム実行

### P3-T3: ツリーレイアウトアルゴリズム

- トップダウンのツリーレイアウト:
  1. ルートノード特定（子としてどこからも参照されていないエージェント）
  2. レベル割り当て（深さ優先探索）
  3. 各レベルのノードを等間隔配置
  4. DAG 対応（複数の親を持つ場合、主要な親1つを選択してレイアウト、追加エッジは曲線描画）
- 計算した位置を `OrgChartNode` に格納

### P3-T4: 組織図キャンバスビュー

- `OrgChartCanvasView.swift`:
  - ノード: SwiftUI ビュー（`ZStack` 配置）→ インタラクティブ性確保
  - エッジ: `Canvas` バックグラウンドレイヤーまたは `Path` オーバーレイ → 効率的な描画
  - `ScrollView` + `MagnificationGesture` でスクロール・ズーム

### P3-T5: ノードインタラクション

- ドラッグジェスチャでノード位置調整
- シングルクリック → 選択（インスペクタに設定表示）
- ダブルクリック → ターミナルタブを開く
- ユーザーカスタム位置をアプリ設定に保存（プロジェクト別）

### P3-T6: エッジ作成・削除

- ノードの出力ポート（下部の小円）からドラッグ → 別ノードの入力ポート（上部）にドロップ
- ドロップ時: `AgentRelationService.addRelation(parent:child:)` → 親の `.md` ファイル更新
- エッジ右クリック → 「関係を削除」
- 循環参照防止: 追加前にバリデーション

### P3-T7: 組織図ウィンドウ

- サイドバーのボタン（「Org Chart」またはツリーアイコン）からアクセス
- シートまたは別ウィンドウとして表示
- ツールバー: ズーム、自動レイアウト、閉じる

---

## Phase 4: 品質向上と高度な機能（Week 10-12）

**マイルストーン**: 堅牢なエラーハンドリング、ファイル監視、キーボードショートカット、ビジュアルポリッシュ。

### P4-T1: ファイルシステム監視

- `FileWatcherService.swift`:
  - `DispatchSource.makeFileSystemObjectSource` または FSEvents で `.claude/agents/` を監視
  - 外部変更時にエージェント一覧を自動リロード
  - デバウンス（300ms）

### P4-T2: エージェントステータス検知

- ターミナル出力のパターンマッチ:
  - `>` プロンプト → 入力待ち
  - パーミッションプロンプト → 入力待ち
  - それ以外の出力継続 → アクティブ動作中
- v1 はヒューリスティクス。v2 で `--output-format stream-json` による精密検知を検討

### P4-T3: 指示送信 UI

- ターミナル上部にテキストフィールド
- 「Send」ボタンまたは Enter キーで PTY の stdin に書き込み
- 送信履歴（↑キーでリコール）

### P4-T4: キーボードショートカット

| ショートカット | アクション |
|---|---|
| `Cmd+N` | 新規エージェント |
| `Cmd+R` | 選択エージェント起動/再起動 |
| `Cmd+.` | 選択エージェント停止 |
| `Cmd+1-9` | タブ切り替え |
| `Cmd+Shift+O` | プロジェクトを開く |
| `Cmd+,` | 環境設定 |

### P4-T5: Claude バイナリ検出

- `ClaudePathResolver.swift`:
  - 初回起動時に以下を検索:
    - `/usr/local/bin/claude`
    - ユーザーシェルでの `which claude` 出力
    - `~/.nvm/`, `~/.nodebrew/` 配下
  - 環境設定でパス手動指定可能
  - 未検出時にエラー表示

### P4-T6: エラーハンドリング

- エージェントファイルパースエラー → サイドバーに警告表示、無効なエージェントはスキップ
- プロセス起動失敗 → エラー詳細アラート表示
- 同名エージェント（プロジェクト/ユーザースコープ重複）→ プロジェクトスコープを優先
- 未保存変更警告（インスペクタ閉じ時）

### P4-T7: 環境設定ウィンドウ

- `PreferencesView.swift` (SwiftUI Settings シーン)
- Claude バイナリパス設定
- デフォルトターミナルフォント・サイズ
- ターミナルカラースキーム（ダーク/ライト）
- 最近のプロジェクト管理

### P4-T8: ダークモードとビジュアルポリッシュ

- 全ビューがシステムアピアランスに追従
- ターミナルカラーのライト/ダーク適応
- ステータスインジケータにセマンティックカラー使用
- サイドバーは macOS ネイティブスタイルに準拠

---

## テスト戦略

Apple Developer Program 不要。Xcode または `swift test` で全て実行可能。

### ユニットテスト（XCTest）

| テスト対象 | 内容 |
|---|---|
| Agent モデル | frontmatter マークダウンとの相互変換。全フィールド型、オプショナル、YAML エッジケース |
| AgentConfigService | テンポラリディレクトリにモック `.md` ファイル作成、読み書きラウンドトリップ検証 |
| AgentRelation 抽出 | 各種 `tools` 設定から正しい関係を抽出できることを検証 |
| ツリーレイアウト | ノード・エッジから重複なし・正しい順序の位置計算を検証 |
| frontmatter パーサー | frontmatter なし、空本文、不正 YAML、フィールド順序違い等のエッジケース |

### 統合テスト

| テスト対象 | 内容 |
|---|---|
| PTYService | 簡易コマンド（`/bin/echo "hello"`）を PTY で実行、出力受信・終了検知を確認。claude CLI 不要 |
| ファイル監視 | テンポラリディレクトリを監視、ファイル作成/変更/削除でコールバック発火を確認 |

### UI テスト（XCUITest）

- アプリ起動、サイドバー表示、3カラムレイアウト描画の確認
- エージェント作成フロー: 「+」クリック → フォーム入力 → 保存 → サイドバーに表示確認

### 手動テストチェックリスト

- [ ] アプリ起動、`.claude/agents/` のあるプロジェクトを開く
- [ ] エージェントが一覧に表示される
- [ ] エージェントを起動、ターミナルに Claude Code 出力が表示される
- [ ] 指示を入力、エージェントに届く
- [ ] エージェントを停止、ステータスが更新される
- [ ] エージェント設定を編集、保存、ディスク上のファイルが更新される
- [ ] 組織図を開く、関係が tools 設定と一致する
- [ ] 組織図でエッジを追加/削除、`.md` ファイルが更新される
- [ ] プロジェクトを切替、エージェント一覧が更新される
- [ ] プロジェクト/ユーザースコープ両方のエージェントで動作確認

---

## 技術的判断事項と根拠

### SwiftTerm NSView ラッピング

SwiftTerm の `LocalProcessTerminalView` は ANSI エスケープコード、カラー、カーソル移動、スクロールバック、PTY 管理を一括処理する。生の PTY マネージャー + カスタムターミナルレンダラーの自前実装は工数に見合わない。`NSViewRepresentable` による SwiftUI ブリッジは確立されたパターン。

### YAML パース: Yams 採用

Claude Code のエージェントファイルは `---` デリミタ間の YAML frontmatter + マークダウン構造。`hooks` や `mcpServers` フィールドはネスト YAML を含むため、手動パーサーでは脆弱。Yams による堅牢なパースを採用。

### v1 はインタラクティブターミナルモード

2つのアプローチが可能:
1. **生ターミナルモード**: `claude --agent <name>` を通常の PTY で実行。自然なターミナル体験だがステータス検知は不正確
2. **Stream JSON モード**: `claude -p --output-format stream-json --input-format stream-json` で構造化イベント取得。精密だがカスタム UI 構築が必要

v1 は生ターミナルモードを採用。ターミナル体験がアプリのコア価値。ステータス検知はヒューリスティクスで「十分」。Stream JSON モードは v2 で検討。

### 組織図: ZStack + Canvas ハイブリッド

SwiftUI `Canvas` は効率的な 2D 描画だがインタラクティビティが限定的。ハイブリッドアプローチ:
- ノード: SwiftUI ビュー（`ZStack` 配置）→ インタラクティブ・アクセシブル
- エッジ: `Canvas` バックグラウンドまたは `Path` オーバーレイ → 効率的な曲線描画
