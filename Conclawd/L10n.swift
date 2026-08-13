import SwiftUI

/// Lightweight localization system driven by `@AppStorage("appLanguage")`.
struct L10n {
    let lang: AppLanguage

    init(_ lang: AppLanguage) {
        self.lang = lang
    }

    /// Create from the raw AppStorage string, falling back to `.en`.
    init(raw: String) {
        self.lang = AppLanguage(rawValue: raw) ?? .en
    }

    // MARK: - Settings Tabs

    var general: String { s("General", "一般") }
    var terminal: String { s("Terminal", "ターミナル") }
    var agents: String { s("Agents", "エージェント") }
    var notifications: String { s("Notifications", "通知") }

    // MARK: - General Settings

    var appearance: String { s("Appearance", "外観") }
    var theme: String { s("Theme", "テーマ") }
    var language: String { s("Language", "言語") }
    var claudeCLI: String { s("Claude CLI", "Claude CLI") }
    var binaryPath: String { s("Binary Path", "バイナリパス") }
    var autoDetectIfEmpty: String { s("Auto-detect if empty", "空欄なら自動検出") }
    var browse: String { s("Browse...", "選択...") }
    var browseShort: String { s("Browse", "選択") }
    var autoDetected: String { s("Auto-detected", "自動検出") }
    var claudeBinaryNotFound: String { s("claude binary not found", "claudeバイナリが見つかりません") }
    var validExecutable: String { s("Valid executable", "有効な実行ファイル") }
    var fileNotFoundOrNotExecutable: String { s("File not found or not executable", "ファイルが見つからないか実行不可") }
    var selectClaudeBinary: String { s("Select the claude CLI binary", "claude CLIバイナリを選択") }

    // MARK: - Startup Settings

    var startup: String { s("Startup", "起動時") }
    var initialProject: String { s("Initial Project", "初期プロジェクト") }
    var projectShownOnLaunch: String { s("The project shown when the app launches.", "アプリ起動時に表示するプロジェクトです。") }

    // MARK: - Sidebar Settings

    var sidebar: String { s("Sidebar", "サイドバー") }
    var sidebarTabs: String { s("Sidebar Tabs", "サイドバータブ") }
    var sidebarTabsDesc: String { s("Drag to reorder. The top 4 are shown in the sidebar.", "ドラッグで並べ替え。上位4つがサイドバーに表示されます。") }

    // MARK: - Appearance Modes

    var dark: String { s("Dark", "ダーク") }
    var light: String { s("Light", "ライト") }
    var system: String { s("System", "システム") }

    // MARK: - Terminal Settings

    var font: String { s("Font", "フォント") }
    var size: String { s("Size", "サイズ") }
    var cursor: String { s("Cursor", "カーソル") }
    var style: String { s("Style", "スタイル") }
    var colorScheme: String { s("Color Scheme", "カラースキーム") }
    var scheme: String { s("Scheme", "スキーム") }

    // MARK: - Editor Settings

    var editor: String { s("Editor", "エディタ") }
    var lineNumbers: String { s("Line Numbers", "行番号") }
    var wordWrap: String { s("Word Wrap", "行の折り返し") }
    var showPreview: String { s("Show Preview", "プレビューを表示") }
    var showSource: String { s("Show Source", "ソースを表示") }

    // MARK: - Cursor Styles

    var block: String { s("Block", "ブロック") }
    var bar: String { s("Bar", "バー") }
    var underline: String { s("Underline", "アンダーライン") }

    // MARK: - Agent Settings

    var model: String { s("Model", "モデル") }
    var defaultLabel: String { s("Default", "デフォルト") }
    var noneUseCLIDefault: String { s("None (use CLI default)", "なし（CLI既定を使用）") }
    var concurrency: String { s("Concurrency", "同時実行") }
    var maxSessions: String { s("Max Sessions", "最大セッション数") }
    var unlimited: String { s("Unlimited", "無制限") }
    var appliedWhenInherit: String { s("Applied when an agent's model is set to \"inherit\".", "エージェントのモデルが「inherit」の場合に適用されます。") }
    var limitsMaxSessions: String { s("Limits the number of agent sessions running simultaneously.", "同時に実行するエージェントセッション数を制限します。") }
    var skillUsageTracking: String { s("Skill Usage Tracking", "スキル利用回数の記録") }
    var trackSkillUsage: String { s("Track Usage", "利用回数を記録") }
    var skillUsageTrackingDesc: String { s("Records skill usage via Claude Code hook. Counts are shown in the skill inspector.", "Claude Codeフックでスキル利用を記録します。回数はスキルインスペクターに表示されます。") }

    // MARK: - Codex Sync Settings
    var codexIntegration: String { s("Codex Integration", "Codex連携") }
    var codexSkillSync: String { s("Sync Skills to Codex", "スキルをCodexに同期") }
    var codexSkillSyncDesc: String { s("Automatically syncs skills from ~/.claude/skills/ to ~/.codex/skills/ so Codex CLI can use them.", "~/.claude/skills/ のスキルを ~/.codex/skills/ に自動同期し、Codex CLIで利用可能にします。") }
    var createForClaudeCode: String { s("Claude Code", "Claude Code") }
    var createForCodex: String { s("Codex CLI", "Codex CLI") }

    // MARK: - Background Tasks Settings
    var backgroundTasks: String { s("Background Tasks", "バックグラウンドタスク") }
    var backgroundTasksDesc: String { s("Choose which CLI runs each background task. Claude consumes its programmatic credit pool; Codex uses your Codex subscription. Schedule (cloud triggers) always uses Claude because it relies on Anthropic's RemoteTrigger tool.", "各バックグラウンドタスクを実行するCLIを選択します。ClaudeはClaudeのプログラマティッククレジット枠を消費し、CodexはCodexサブスクを使用します。スケジュール（クラウドトリガー）はAnthropicのRemoteTriggerツールに依存するため常にClaudeを使用します。") }
    var memoryExtractionProvider: String { s("Memory Extraction", "メモリ抽出") }
    var commitMessageProvider: String { s("Commit Messages", "コミットメッセージ") }

    // MARK: - Notification Settings

    var configuresClaudeCodeHooks: String { s("Configures Claude Code hooks in ~/.claude/settings.json", "~/.claude/settings.json のClaude Codeフックを設定") }
    var taskCompletion: String { s("Task Completion", "タスク完了") }
    var enabled: String { s("Enabled", "有効") }
    var message: String { s("Message", "メッセージ") }
    var sound: String { s("Sound", "サウンド") }
    var none: String { s("None", "なし") }
    var attentionRequired: String { s("Attention Required", "注意が必要") }
    var notifyWhenFinished: String { s("Notify when an agent finishes responding.", "エージェントの応答完了時に通知します。") }
    var notifyWhenAttention: String { s("Notify when Claude Code sends a notification (e.g. permission request).", "Claude Codeが通知を送信したとき（権限要求など）に通知します。") }
    var sendTestNotification: String { s("Send Test Notification", "テスト通知を送信") }
    var notificationMessage: String { s("Notification message", "通知メッセージ") }
    var previewSound: String { s("Preview sound", "サウンドをプレビュー") }
    var testNotification: String { s("Test notification", "テスト通知") }

    // MARK: - Sidebar

    var sessions: String { s("Sessions", "セッション") }
    var skills: String { s("Skills", "スキル") }
    var schedules: String { s("Schedules", "スケジュール") }
    var files: String { s("Files", "ファイル") }
    var shells: String { s("Shells", "シェル") }
    var newShell: String { s("New Shell", "新規シェル") }
    var noShells: String { s("No Shells", "シェルなし") }
    var openShellToBegin: String { s("Open a shell to begin", "シェルを開いて始めましょう") }
    var presets: String { s("Presets", "プリセット") }
    var newPreset: String { s("New Preset...", "新規プリセット...") }
    var editPreset: String { s("Edit Preset", "プリセットを編集") }
    var saveAsPreset: String { s("Save as Preset...", "プリセットとして保存...") }
    var command: String { s("Command", "コマンド") }
    var manual: String { s("Manual", "マニュアル") }
    var commandPlaceholder: String { s("e.g. claude --model opus-4 --dangerously-skip-permissions", "例: claude --model opus-4 --dangerously-skip-permissions") }
    var selectProjectToViewFiles: String { s("Select a project to view files", "プロジェクトを選択するとファイルを表示できます") }
    var unsavedChanges: String { s("Unsaved Changes", "未保存の変更") }
    var refresh: String { s("Refresh", "更新") }
    var newFile: String { s("New File", "新規ファイル") }
    var newFolder: String { s("New Folder", "新規フォルダ") }
    var copyPath: String { s("Copy Path", "パスをコピー") }
    var copyRelativePath: String { s("Copy Relative Path", "相対パスをコピー") }
    var openWithDefaultApp: String { s("Open with Default App", "デフォルトアプリで開く") }
    var fileName: String { s("File name", "ファイル名") }
    var folderName: String { s("Folder name", "フォルダ名") }
    var moveToTrash: String { s("Move to Trash", "ゴミ箱に入れる") }
    var moveToTrashConfirmTitle: String { s("Move to Trash?", "ゴミ箱に入れますか？") }
    func moveToTrashConfirmMessage(name: String) -> String {
        s("\"\(name)\" will be moved to the Trash. You can restore it from the Trash later.",
          "\"\(name)\" をゴミ箱に移動します。後でゴミ箱から復元できます。")
    }

    // MARK: - Common Actions

    var save: String { s("Save", "保存") }
    var cancel: String { s("Cancel", "キャンセル") }
    var create: String { s("Create", "作成") }
    var delete: String { s("Delete", "削除") }
    var edit: String { s("Edit", "編集") }
    var revert: String { s("Revert", "元に戻す") }
    var duplicate: String { s("Duplicate", "複製") }
    var close: String { s("Close", "閉じる") }
    var closeAll: String { s("Close All", "すべて閉じる") }
    var rename: String { s("Rename", "名前を変更") }
    var start: String { s("Start", "開始") }
    var stop: String { s("Stop", "停止") }
    var resume: String { s("Resume", "再開") }
    var fork: String { s("Fork", "分岐") }
    var done: String { s("Done", "完了") }
    var add: String { s("Add", "追加") }

    // MARK: - Common Labels

    var settings: String { s("Settings", "設定") }
    var name: String { s("Name", "名前") }
    var description: String { s("Description", "説明") }
    var type: String { s("Type", "タイプ") }
    var content: String { s("Content", "内容") }
    var scope: String { s("Scope", "スコープ") }
    var project: String { s("Project", "プロジェクト") }
    var directory: String { s("Directory", "ディレクトリ") }
    var advanced: String { s("Advanced", "詳細設定") }
    var configuration: String { s("Configuration", "設定") }
    var inspector: String { s("Inspector", "インスペクター") }
    var custom: String { s("Custom", "カスタム") }
    var permissions: String { s("Permissions", "権限") }
    var color: String { s("Color", "カラー") }
    var memory: String { s("Memory", "メモリ") }

    // MARK: - Navigation

    var home: String { s("Home", "ホーム") }
    var allProjects: String { s("All Projects", "全プロジェクト") }
    var openProject: String { s("Open Project...", "プロジェクトを開く...") }
    var selectProjectDirectory: String { s("Select a project directory", "プロジェクトディレクトリを選択") }
    var hideSidebar: String { s("Hide Sidebar", "サイドバーを隠す") }
    var showSidebar: String { s("Show Sidebar", "サイドバーを表示") }

    // MARK: - Git Branch Selector

    var searchBranches: String { s("Search branches...", "ブランチを検索...") }
    var localBranches: String { s("Local", "ローカル") }
    var remoteBranches: String { s("Remote", "リモート") }
    var createNewBranch: String { s("Create New Branch...", "新しいブランチを作成...") }
    var newBranchName: String { s("New branch name", "新しいブランチ名") }
    var branchSwitchFailed: String { s("Branch switch failed", "ブランチ切り替えに失敗") }
    var uncommittedChanges: String { s("You have uncommitted changes. Switch anyway?", "未コミットの変更があります。切り替えますか？") }
    var switchBranch: String { s("Switch", "切り替え") }
    var hideInspector: String { s("Hide Inspector", "インスペクターを隠す") }
    var showInspector: String { s("Show Inspector", "インスペクターを表示") }

    // MARK: - Git Actions

    var commitChanges: String { s("Commit Changes", "変更をコミット") }
    var commit: String { s("Commit", "コミット") }
    var push: String { s("Push", "プッシュ") }
    var pull: String { s("Pull", "プル") }
    var filesChanged: String { s("files changed", "ファイル変更") }
    var commitMessagePlaceholder: String { s("Commit message...", "コミットメッセージ...") }
    var generateMessage: String { s("Generate", "AI生成") }
    var gitOperationFailed: String { s("Git Operation Failed", "Git操作に失敗") }
    var copyError: String { s("Copy", "コピー") }
    var dismissError: String { s("Dismiss", "閉じる") }

    // MARK: - Status

    var thinking: String { s("Thinking...", "考え中...") }
    var ready: String { s("Ready", "待機中") }
    var stopped: String { s("Stopped", "停止") }
    var running: String { s("Running", "実行中") }
    var waiting: String { s("Waiting", "待機中") }
    var disabled: String { s("Disabled", "無効") }
    var completed: String { s("completed", "完了") }
    var needsYourAttention: String { s("needs your attention", "確認が必要です") }

    // MARK: - Agent Inspector

    var selectAnAgent: String { s("Select an agent", "エージェントを選択") }
    var tools: String { s("Tools", "ツール") }
    var agentDefinition: String { s("Agent Definition", "エージェント定義") }
    var noToolsConfigured: String { s("No tools configured", "ツール未設定") }
    var addTool: String { s("Add Tool", "ツールを追加") }
    var subAgents: String { s("Sub-Agents", "サブエージェント") }
    var addSubAgent: String { s("Add Sub-Agent", "サブエージェントを追加") }
    var noAvailableSubAgents: String { s("No available agents", "追加可能なエージェントがありません") }
    var cycleDetected: String { s("Cannot add: circular dependency detected", "追加できません: 循環参照が検出されました") }
    var startSession: String { s("Start Session", "セッションを開始") }
    var newSession: String { s("New Session", "新規セッション") }
    var addSchedule: String { s("Add Schedule", "スケジュールを追加") }
    var permission: String { s("Permission", "権限") }
    var maxTurns: String { s("Max Turns", "最大ターン数") }
    var projectRoot: String { s("Project Root", "プロジェクトルート") }
    var localOverride: String { s("Local override", "ローカル上書き") }
    var fromMdFile: String { s("From .md file", ".mdファイルから") }
    var clearLocalOverride: String { s("Clear local override", "ローカル上書きをクリア") }
    var selectWorkingDirectory: String { s("Select working directory for this agent", "エージェントの作業ディレクトリを選択") }
    var agentName: String { s("Agent name", "エージェント名") }
    var runNow: String { s("Run Now", "今すぐ実行") }
    var enable: String { s("Enable", "有効化") }
    var disable: String { s("Disable", "無効化") }
    var inherit: String { s("Inherit", "継承") }

    // MARK: - Skill Inspector

    var selectASkill: String { s("Select a skill", "スキルを選択") }
    var bundledFiles: String { s("Bundled Files", "バンドルファイル") }
    var noBundledFiles: String { s("No bundled files", "バンドルファイルなし") }
    var revealInFinder: String { s("Reveal in Finder", "Finderで表示") }
    var skillName: String { s("Skill name", "スキル名") }
    var usageCount: String { s("Usage", "利用回数") }
    var timesUsed: String { s("times", "回") }
    var behavior: String { s("Behavior", "動作") }
    var manualOnly: String { s("Manual Only", "手動のみ") }
    var manualOnlyDescription: String { s("Prevent automatic invocation by Claude", "Claudeの自動呼び出しを無効化") }
    var showInMenu: String { s("Show in / Menu", "/メニューに表示") }
    var showInMenuDescription: String { s("Show in slash command menu", "スラッシュコマンドメニューに表示") }
    var skillContext: String { s("Context", "コンテキスト") }
    var agentType: String { s("Agent Type", "エージェント型") }
    var effort: String { s("Effort", "品質") }
    var argumentHint: String { s("Argument Hint", "引数ヒント") }
    var allowedToolsLabel: String { s("Allowed Tools", "許可ツール") }

    // MARK: - Agent Editor

    var noAgentSelected: String { s("No agent selected", "エージェント未選択") }
    var selectAgentToEdit: String { s("Select an agent and choose \"Inspect\" to edit", "エージェントを選択して「インスペクト」で編集") }

    // MARK: - Skill Editor

    var noSkillSelected: String { s("No skill selected", "スキル未選択") }
    var selectSkillToEdit: String { s("Select a skill from the sidebar to edit", "サイドバーからスキルを選択して編集") }
    var binaryFile: String { s("Binary file", "バイナリファイル") }
    var chooseApplication: String { s("Choose Application...", "アプリケーションを選択...") }
    var resetToDefault: String { s("Reset to Default", "デフォルトに戻す") }

    // MARK: - New Agent Sheet

    var newAgent: String { s("New Agent", "新規エージェント") }
    var userGlobal: String { s("User (Global)", "ユーザー（グローバル）") }
    var projectSpecific: String { s("Project (Specific)", "プロジェクト（固有）") }
    var notSelected: String { s("Not selected", "未選択") }
    var saveTo: String { s("Save to", "保存先") }
    var setCustomWorkingDirectory: String { s("Set custom Working Directory", "カスタム作業ディレクトリを設定") }
    var workingDirectory: String { s("Working Directory", "作業ディレクトリ") }

    // MARK: - New Skill Sheet

    var newSkill: String { s("New Skill", "新規スキル") }

    // MARK: - New Schedule Sheet

    var newSchedule: String { s("New Schedule", "新規スケジュール") }
    var editSchedule: String { s("Edit Schedule", "スケジュールを編集") }
    var selectAnAgentPicker: String { s("Select an agent", "エージェントを選択") }
    var schedule: String { s("Schedule", "スケジュール") }
    var interval: String { s("Interval", "間隔") }
    var daily: String { s("Daily", "毎日") }
    var weekly: String { s("Weekly", "毎週") }
    var executionSettings: String { s("Execution Settings", "実行設定") }
    var instructionsPrompt: String { s("Instructions (Prompt)", "指示（プロンプト）") }
    var maxConcurrent: String { s("Max concurrent", "最大同時実行") }

    // MARK: - Cloud Schedule

    var cloud: String { s("Cloud", "クラウド") }
    var cloudSchedule: String { s("Cloud Schedule", "クラウドスケジュール") }
    var cronExpression: String { s("Cron Expression", "Cron式") }
    var cronExpressionPlaceholder: String { s("e.g. 0 9 * * 1-5 (UTC)", "例: 0 9 * * 1-5 (UTC)") }
    var environmentId: String { s("Environment", "環境") }
    var nextRun: String { s("Next Run", "次回実行") }
    var deleteOnWeb: String { s("Delete on Web...", "Webで削除...") }
    var cloudScheduleMinInterval: String { s("Minimum interval: 1 hour", "最小間隔: 1時間") }
    var notLoggedIn: String { s("Not logged in to Claude Code", "Claude Codeにログインしていません") }
    var cronPresetHourly: String { s("Hourly", "毎時") }
    var cronPresetDaily9am: String { s("Daily 9am", "毎日9時") }
    var cronPresetWeekdays9am: String { s("Weekdays 9am", "平日9時") }
    var cronPresetWeekly: String { s("Weekly Mon 9am", "毎週月曜9時") }

    // MARK: - Time Intervals

    var min1: String { s("1 min", "1分") }
    var min5: String { s("5 min", "5分") }
    var min10: String { s("10 min", "10分") }
    var min15: String { s("15 min", "15分") }
    var min30: String { s("30 min", "30分") }
    var hour1: String { s("1 hour", "1時間") }
    var hours2: String { s("2 hours", "2時間") }
    var hours4: String { s("4 hours", "4時間") }
    var hours8: String { s("8 hours", "8時間") }
    var hours12: String { s("12 hours", "12時間") }
    var hours24: String { s("24 hours", "24時間") }

    // MARK: - Weekdays

    var sunday: String { s("Sunday", "日曜日") }
    var monday: String { s("Monday", "月曜日") }
    var tuesday: String { s("Tuesday", "火曜日") }
    var wednesday: String { s("Wednesday", "水曜日") }
    var thursday: String { s("Thursday", "木曜日") }
    var friday: String { s("Friday", "金曜日") }
    var saturday: String { s("Saturday", "土曜日") }

    // MARK: - Memory

    var memoryDisabledForAgent: String { s("Memory is disabled for this agent", "このエージェントのメモリは無効です") }
    var noMemoriesYet: String { s("No memories yet", "メモリなし") }
    var showMoreMemories: String { s("Show more", "もっと見る") }
    var showLessMemories: String { s("Show less", "閉じる") }
    var memoryStorage: String { s("Storage", "保存先") }
    var editMemory: String { s("Edit Memory", "メモリを編集") }
    var memoryName: String { s("memory_name", "メモリ名") }
    var oneLineDescription: String { s("One-line description", "一行の説明") }

    // MARK: - Terminal Tab View

    var startAgent: String { s("Start Agent", "エージェントを開始") }
    var selectAgentToStart: String { s("Select an agent from the sidebar to get started", "サイドバーからエージェントを選択して開始") }
    var sessionStopped: String { s("Session stopped", "セッション停止") }
    var attachFile: String { s("Attach File", "ファイルを添付") }
    var shareContext: String { s("Share Context", "コンテキストを共有") }
    var tabName: String { s("Tab name", "タブ名") }

    // MARK: - Creation Session

    var describeAgentToCreate: String { s("Describe the agent you want to create", "作成したいエージェントを説明してください") }
    var describeSkillToCreate: String { s("Describe the skill you want to create", "作成したいスキルを説明してください") }
    var agentCreationExample: String { s("e.g. \"I want an agent for code review\"", "例：「コードレビュー用のエージェントが欲しい」") }
    var skillCreationExample: String { s("e.g. \"I want a skill that helps with PDF manipulation\"", "例：「PDF操作に役立つスキルが欲しい」") }

    // MARK: - New Session Sheet

    var systemPrompt: String { s("System Prompt", "システムプロンプト") }
    var customFlags: String { s("Custom CLI Flags", "カスタムCLIフラグ") }
    var customFlagsPlaceholder: String { s("e.g. --verbose --max-turns 10", "例: --verbose --max-turns 10") }
    var customDirectory: String { s("Custom Directory", "カスタムディレクトリ") }

    // MARK: - Session History

    var sessionHistory: String { s("Session History", "セッション履歴") }
    var clearAll: String { s("Clear All", "すべてクリア") }
    var filterByAgentName: String { s("Filter by agent name...", "エージェント名で絞り込み...") }
    var resumableOnly: String { s("Resumable only", "再開可能のみ") }
    var noHistory: String { s("No History", "履歴なし") }
    var clearAllHistory: String { s("Clear All History", "全履歴をクリア") }
    var clearAllHistoryConfirm: String { s("Are you sure you want to delete all session history? This cannot be undone.", "すべてのセッション履歴を削除しますか？この操作は取り消せません。") }
    var today: String { s("Today", "今日") }
    var yesterday: String { s("Yesterday", "昨日") }
    var thisWeek: String { s("This Week", "今週") }
    var lastWeek: String { s("Last Week", "先週") }
    var older: String { s("Older", "それ以前") }

    // MARK: - Duplicate Sheet

    var duplicateLabel: String { s("Duplicate", "複製") }

    // MARK: - Sidebar Context Menus

    var startAgentMenu: String { s("Start", "開始") }
    var closeAllMenu: String { s("Close All", "すべて閉じる") }
    var inspectMenu: String { s("Inspect", "インスペクト") }
    var editDefinition: String { s("Edit Definition", "定義を編集") }
    var editContent: String { s("Edit Content", "内容を編集") }
    var keyboardShortcuts: String { s("Keyboard Shortcuts", "キーボードショートカット") }
    var showHistory: String { s("Show History", "履歴を表示") }

    // MARK: - Org Chart

    var orgChart: String { s("Team", "チーム") }
    var crossProjectRelationship: String { s("Cross-Project Relationship", "プロジェクト間のリレーション") }
    var crossProjectWarningMessage: String { s(
        "These agents are in different projects. Claude Code won't find the child agent when running from either project.",
        "これらのエージェントは異なるプロジェクトにあります。どちらのプロジェクトから実行しても、子エージェントは見つかりません。"
    ) }
    var relationWarnings: String { s("Relation Warnings", "リレーション警告") }
    var removeBrokenReference: String { s("Remove Broken Reference", "壊れた参照を削除") }

    // MARK: - Sidebar Labels

    var noAgents: String { s("No agents found", "エージェントが見つかりません") }
    var addAgent: String { s("Add an agent to get started", "エージェントを追加して始めましょう") }
    var noSkills: String { s("No skills found", "スキルが見つかりません") }
    var addSkill: String { s("Add a skill to get started", "スキルを追加して始めましょう") }
    var noSchedules: String { s("No schedules", "スケジュールなし") }
    var addScheduleToStart: String { s("Add a schedule to automate tasks", "スケジュールを追加してタスクを自動化") }
    var noSessions: String { s("No active sessions", "アクティブなセッションなし") }
    var startSessionToBegin: String { s("Start an agent to begin", "エージェントを開始して始めましょう") }

    // MARK: - Agent

    var agent: String { s("Agent", "エージェント") }
    var skill: String { s("Skill", "スキル") }

    // MARK: - Private

    private func s(_ en: String, _ ja: String) -> String {
        lang == .ja ? ja : en
    }
}

// MARK: - Environment Key

private struct L10nKey: EnvironmentKey {
    static let defaultValue: L10n = L10n(.en)
}

extension EnvironmentValues {
    var l10n: L10n {
        get { self[L10nKey.self] }
        set { self[L10nKey.self] = newValue }
    }
}
