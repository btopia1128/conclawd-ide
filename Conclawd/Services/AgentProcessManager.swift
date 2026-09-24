import Foundation
import SwiftTerm
import AppKit

/// Manages the lifecycle of Claude Code agent processes.
/// All dictionaries are keyed by **sessionId** (not agentId).
@Observable
@MainActor
final class AgentProcessManager {

    /// Running or recently-stopped processes, keyed by session ID.
    private(set) var processes: [UUID: AgentProcess] = [:]

    /// Terminal views keyed by session ID. Retained to keep PTY alive.
    private(set) var terminalViews: [UUID: IMETerminalView] = [:]

    /// Delegate bridge objects keyed by session ID.
    private var delegates: [UUID: TerminalDelegateBridge] = [:]

    /// Last data received timestamp per session.
    private var lastDataReceived: [UUID: Date] = [:]

    /// Whether we're expecting a response from Claude (after Enter was pressed).
    private var expectingResponse: [UUID: Bool] = [:]

    /// Timestamp of the last meaningful interaction (prompt submission or response start).
    /// Used for session list sorting — unlike lastDataReceived, this does NOT update on every data chunk.
    private(set) var lastInteraction: [UUID: Date] = [:]

    /// The latest user prompt text per session (updated on each Enter press).
    private(set) var lastUserPrompt: [UUID: String] = [:]

    /// The set of sessions currently visible across all panes. Data received for
    /// sessions outside this set is marked as unread (after the idle threshold).
    /// Was a single `viewingSessionId: UUID?` before split-pane support.
    var viewingSessionIds: Set<UUID> = []

    /// Timer for idle detection.
    private var idleTimer: Timer?

    /// Seconds of silence before marking an agent as "waiting for input".
    private let idleThreshold: TimeInterval = 2.5

    let cliPathResolver = CLIPathResolver()

    /// Backward-compatible alias.
    var claudePathResolver: CLIPathResolver { cliPathResolver }

    /// Callback when a session terminates. (sessionId, terminalText, agentId)
    var onSessionTerminated: ((UUID, String?, UUID?) -> Void)?

    /// Called when a Claude resume ID is detected from terminal output.
    /// Parameters: (sessionId, resumeId)
    var onResumeIdDetected: ((UUID, String) -> Void)?

    /// Callback when a session's status changes. (sessionId, newStatus)
    var onStatusChanged: ((UUID, AgentProcessStatus) -> Void)?

    // MARK: - Creation Session

    /// Starts a creation session and returns the session ID.
    func startCreationSession(session: CreationSession, systemPrompt: String) throws -> UUID {
        guard let claudePath = claudePathResolver.resolve() else {
            throw ProcessManagerError.claudeNotFound
        }

        let sessionId = session.id

        let terminalView = createTerminalView(sessionId: sessionId)

        // Pass multiline system prompt via env var to avoid shell escaping issues
        var env = buildEnvironment()
        env.append("_AGENT_TERMINAL_SYSTEM_PROMPT=\(systemPrompt)")

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let escapedClaude = claudePath.replacingOccurrences(of: " ", with: "\\ ")

        let args = ["--model", AgentModel.opus.rawValue, "--system-prompt", "$_AGENT_TERMINAL_SYSTEM_PROMPT"]
        let escapedArgs = args.map { "\"\($0)\"" }.joined(separator: " ")
        let command = "\(escapedClaude) \(escapedArgs)"

        let workingDir = session.targetDirectory.deletingLastPathComponent().deletingLastPathComponent().path(percentEncoded: false)

        terminalView.startProcess(
            executable: shell,
            args: ["-l", "-c", command],
            environment: env,
            execName: shell,
            currentDirectory: workingDir
        )

        let process = AgentProcess(agentId: sessionId)
        process.pid = terminalView.process.shellPid
        process.status = .running
        logLifecycle("start", sessionId: sessionId, pid: process.pid)
        processes[sessionId] = process
        terminalViews[sessionId] = terminalView

        lastDataReceived[sessionId] = Date()
        lastInteraction[sessionId] = Date()
        startIdleTimer()

        return sessionId
    }

    // MARK: - Manual Session

    /// Starts a session by executing a raw command string as-is (e.g. "claude --model opus-4").
    func startManual(
        rawCommand: String,
        workingDirectory: String? = nil
    ) throws -> UUID {
        let sessionId = UUID()
        let terminalView = createTerminalView(sessionId: sessionId)

        let maxConcurrent = UserDefaults.standard.integer(forKey: "maxConcurrentAgents")
        if maxConcurrent > 0 {
            let activeCount = processes.values.filter { $0.status.isActive }.count
            if activeCount >= maxConcurrent {
                throw ProcessManagerError.concurrencyLimitReached
            }
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let env = buildEnvironment()

        terminalView.startProcess(
            executable: shell,
            args: ["-l", "-c", rawCommand],
            environment: env,
            execName: shell,
            currentDirectory: workingDirectory
        )

        let startTime = Date()
        let process = AgentProcess(agentId: sessionId)
        process.pid = terminalView.process.shellPid
        process.status = .running
        logLifecycle("start", sessionId: sessionId, pid: process.pid)
        processes[sessionId] = process
        terminalViews[sessionId] = terminalView
        lastDataReceived[sessionId] = startTime
        lastInteraction[sessionId] = startTime

        startIdleTimer()

        return sessionId
    }

    // MARK: - Standalone Session

    /// Starts a standalone CLI session (not tied to any agent).
    func startStandalone(
        model: AgentModel = .inherit,
        permissionMode: PermissionMode = .default,
        workingDirectory: String? = nil,
        systemPrompt: String? = nil,
        customFlags: String? = nil,
        provider: CLIProviderType = .claude
    ) throws -> UUID {
        guard let cliPath = cliPathResolver.resolve(for: provider) else {
            throw ProcessManagerError.cliNotFound(provider)
        }

        let sessionId = UUID()
        let terminalView = createTerminalView(sessionId: sessionId)

        // Enforce max concurrent sessions
        let maxConcurrent = UserDefaults.standard.integer(forKey: "maxConcurrentAgents")
        if maxConcurrent > 0 {
            let activeCount = processes.values.filter { $0.status.isActive }.count
            if activeCount >= maxConcurrent {
                throw ProcessManagerError.concurrencyLimitReached
            }
        }

        var args: [String] = []

        // Model
        let effectiveModel: AgentModel = {
            if model != .inherit { return model }
            let defaultModel = UserDefaults.standard.string(forKey: "defaultModel") ?? ""
            if !defaultModel.isEmpty, defaultModel != AgentModel.inherit.rawValue {
                return AgentModel.from(defaultModel)
            }
            return .inherit
        }()
        if effectiveModel != .inherit {
            let modelId = effectiveModel.cliModelId(for: provider)
            switch provider {
            case .claude:
                args += ["--model", modelId]
            case .codex:
                args += ["-m", modelId]
            }
        }

        // Permission mode
        args += permissionMode.cliArgs(for: provider)

        // Codex: explicitly set working directory so thread DB records the correct CWD
        if provider == .codex, let workingDirectory {
            args += ["-C", workingDirectory]
        }

        // System prompt via env var
        var env = buildEnvironment()
        if let systemPrompt, !systemPrompt.isEmpty {
            switch provider {
            case .claude:
                env.append("_AGENT_TERMINAL_SYSTEM_PROMPT=\(systemPrompt)")
                args += ["--system-prompt", "$_AGENT_TERMINAL_SYSTEM_PROMPT"]
            case .codex:
                // Codex has no --system-prompt flag; write temporary AGENTS.md
                writeTemporaryAgentsMd(systemPrompt: systemPrompt, workingDirectory: workingDirectory)
            }
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let escapedCli = cliPath.replacingOccurrences(of: " ", with: "\\ ")
        let escapedArgs = args.map { "\"\($0)\"" }.joined(separator: " ")
        var command = escapedArgs.isEmpty ? escapedCli : "\(escapedCli) \(escapedArgs)"

        // Append user-provided custom CLI flags as-is (escape hatch for new CLI features)
        if let customFlags, !customFlags.isEmpty {
            command += " \(customFlags)"
        }

        terminalView.startProcess(
            executable: shell,
            args: ["-l", "-c", command],
            environment: env,
            execName: shell,
            currentDirectory: workingDirectory
        )

        let startTime = Date()
        let process = AgentProcess(agentId: sessionId) // use sessionId as sentinel
        process.pid = terminalView.process.shellPid
        process.status = .running
        logLifecycle("start", sessionId: sessionId, pid: process.pid)
        process.cliProviderType = provider
        processes[sessionId] = process
        terminalViews[sessionId] = terminalView
        lastDataReceived[sessionId] = startTime
        lastInteraction[sessionId] = startTime

        startIdleTimer()

        // Proactively detect the session ID from the filesystem.
        switch provider {
        case .claude:
            probeClaudeSessionIdWithRetry(sessionId: sessionId, workingDir: workingDirectory, startTime: startTime)
        case .codex:
            probeCodexSessionIdWithRetry(sessionId: sessionId, startTime: startTime)
        }

        return sessionId
    }

    /// Starts a plain shell terminal (not running Claude CLI).
    /// If `command` is provided, it is sent to the PTY after a short delay.
    func startShellTerminal(
        shell: ShellType,
        workingDirectory: String? = nil,
        command: String? = nil
    ) -> UUID {
        let sessionId = UUID()
        let terminalView = createTerminalView(sessionId: sessionId)

        let env = buildEnvironment()

        terminalView.startProcess(
            executable: shell.rawValue,
            args: ["-l"],
            environment: env,
            execName: shell.rawValue,
            currentDirectory: workingDirectory
        )

        let process = AgentProcess(agentId: sessionId) // sentinel — no real agent
        process.pid = terminalView.process.shellPid
        process.status = .running
        logLifecycle("start", sessionId: sessionId, pid: process.pid)
        processes[sessionId] = process
        terminalViews[sessionId] = terminalView
        lastDataReceived[sessionId] = Date()
        lastInteraction[sessionId] = Date()

        startIdleTimer()

        // Ensure correct working directory and send command after shell has initialized.
        // We send an explicit `cd` because `startProcess(currentDirectory:)` can silently
        // fail to set the working directory on some macOS configurations.
        if let workingDirectory {
            let escaped = workingDirectory.replacingOccurrences(of: "'", with: "'\\''")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if let command, !command.isEmpty {
                    self?.sendInput(sessionId: sessionId, text: "cd '\(escaped)' && \(command)\n")
                } else {
                    self?.sendInput(sessionId: sessionId, text: "cd '\(escaped)' && clear\n")
                }
            }
        } else if let command, !command.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.sendInput(sessionId: sessionId, text: command + "\n")
            }
        }

        return sessionId
    }

    // MARK: - Process Lifecycle

    /// Starts a new session for the given agent and returns the session ID.
    /// Multiple sessions can run concurrently for the same agent.
    func start(agent: Agent, memoryContext: String? = nil, memoryDbPath: String? = nil, provider: CLIProviderType = .claude) throws -> UUID {
        guard let cliPath = cliPathResolver.resolve(for: provider) else {
            throw ProcessManagerError.cliNotFound(provider)
        }

        let sessionId = UUID()

        let terminalView = createTerminalView(sessionId: sessionId)

        // Enforce max concurrent sessions
        let maxConcurrent = UserDefaults.standard.integer(forKey: "maxConcurrentAgents")
        if maxConcurrent > 0 {
            let activeCount = processes.values.filter { $0.status.isActive }.count
            if activeCount >= maxConcurrent {
                throw ProcessManagerError.concurrencyLimitReached
            }
        }

        // Resolve effective model
        let effectiveModel: AgentModel = {
            if agent.model != .inherit { return agent.model }
            let defaultModel = UserDefaults.standard.string(forKey: "defaultModel") ?? ""
            if !defaultModel.isEmpty, defaultModel != AgentModel.inherit.rawValue {
                return AgentModel.from(defaultModel)
            }
            return .inherit
        }()

        // Determine working directory: localDirectory > currentDirectory > projectRoot
        let workingDir = agent.effectiveDirectory?.path(percentEncoded: false)

        var args: [String] = []
        var env = buildEnvironment()

        switch provider {
        case .claude:
            args = buildClaudeAgentArgs(
                agent: agent, effectiveModel: effectiveModel,
                memoryContext: memoryContext, env: &env
            )
        case .codex:
            args = buildCodexAgentArgs(
                agent: agent, effectiveModel: effectiveModel,
                memoryContext: memoryContext, workingDirectory: workingDir, env: &env
            )
        }

        // MCP memory database environment variables
        if let memoryDbPath {
            env.append("CONCLAWD_MEMORY_DB_PATH=\(memoryDbPath)")
        }
        env.append("CONCLAWD_AGENT_NAME=\(agent.name)")
        env.append("CONCLAWD_SESSION_ID=\(sessionId.uuidString)")

        // Connect Conclawd MCP server for recall_memory tool
        let mcpArgs = buildMcpConfigArgs(memoryDbPath: memoryDbPath, agentName: agent.name, sessionId: sessionId, provider: provider)
        args += mcpArgs
        if !mcpArgs.isEmpty {
            print("[AgentProcessManager] MCP config args: \(mcpArgs)")
        } else {
            print("[AgentProcessManager] WARNING: MCP config args empty — recall_memory will not be available")
        }

        // Launch via user's shell so that .zshrc / .bash_profile are sourced
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let escapedCli = cliPath.replacingOccurrences(of: " ", with: "\\ ")
        let escapedArgs = args.map { "\"\($0)\"" }.joined(separator: " ")
        var command = "\(escapedCli) \(escapedArgs)"
        print("[AgentProcessManager] Launch command: \(command)")

        // Append user-provided custom CLI flags as-is (escape hatch for new CLI features)
        if !agent.customFlags.isEmpty {
            command += " \(agent.customFlags)"
        }

        terminalView.startProcess(
            executable: shell,
            args: ["-l", "-c", command],
            environment: env,
            execName: shell,
            currentDirectory: workingDir
        )

        // Track the process — starts as "running" (initial startup is thinking)
        let startTime = Date()
        let process = AgentProcess(agentId: agent.id)
        process.pid = terminalView.process.shellPid
        process.status = .running
        logLifecycle("start", sessionId: sessionId, pid: process.pid)
        process.cliProviderType = provider
        processes[sessionId] = process
        terminalViews[sessionId] = terminalView
        lastDataReceived[sessionId] = startTime
        lastInteraction[sessionId] = startTime

        // Start idle detection if not already running
        startIdleTimer()

        // Proactively detect the session ID from the filesystem.
        switch provider {
        case .claude:
            probeClaudeSessionIdWithRetry(sessionId: sessionId, workingDir: workingDir, startTime: startTime)
        case .codex:
            probeCodexSessionIdWithRetry(sessionId: sessionId, startTime: startTime)
        }

        return sessionId
    }

    // MARK: - Resume Session

    /// Resumes a stopped session using the appropriate CLI resume command.
    /// Replaces the old terminal with a new one running the resumed session.
    func resume(sessionId: UUID, agent: Agent? = nil, memoryContext: String? = nil, workingDirectory: String? = nil, memoryDbPath: String? = nil) throws {
        guard let process = processes[sessionId],
              let resumeId = process.claudeResumeId else {
            throw ProcessManagerError.noResumeId
        }
        let provider = process.cliProviderType
        guard let cliPath = cliPathResolver.resolve(for: provider) else {
            throw ProcessManagerError.cliNotFound(provider)
        }

        // Clean up old terminal — remove from superview to avoid leaked/overlapping views
        if let oldView = terminalViews.removeValue(forKey: sessionId) {
            oldView.removeFromSuperview()
        }
        delegates.removeValue(forKey: sessionId)

        let terminalView = createTerminalView(sessionId: sessionId)

        var args: [String]
        switch provider {
        case .claude:
            args = ["--resume", resumeId]
            if agent?.permissionMode == .bypassPermissions {
                args.append("--dangerously-skip-permissions")
            }
        case .codex:
            args = ["resume", resumeId]
            // Codex filters by CWD — pass -C to match the original session's directory
            if let workingDirectory {
                args += ["-C", workingDirectory]
            }
            if agent?.permissionMode == .bypassPermissions {
                args.append("--yolo")
            }
        }

        var env = buildEnvironment()
        switch provider {
        case .claude:
            appendClaudeSystemPrompt(memoryContext: memoryContext, args: &args, env: &env)
        case .codex:
            appendCodexDeveloperInstructions(args: &args, env: &env)
            if let memoryContext, !memoryContext.isEmpty {
                // For Codex resume, inject memory via temporary AGENTS.md
                writeTemporaryAgentsMd(systemPrompt: memoryContext, workingDirectory: workingDirectory)
            }
        }

        // MCP memory database environment variables
        if let memoryDbPath {
            env.append("CONCLAWD_MEMORY_DB_PATH=\(memoryDbPath)")
        }
        let agentName = agent?.name ?? "main"
        env.append("CONCLAWD_AGENT_NAME=\(agentName)")
        env.append("CONCLAWD_SESSION_ID=\(sessionId.uuidString)")

        // Connect Conclawd MCP server for recall_memory tool
        args += buildMcpConfigArgs(memoryDbPath: memoryDbPath, agentName: agentName, sessionId: sessionId, provider: provider)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let escapedCli = cliPath.replacingOccurrences(of: " ", with: "\\ ")
        let escapedArgs = args.map { "\"\($0)\"" }.joined(separator: " ")
        let command = "\(escapedCli) \(escapedArgs)"

        terminalView.startProcess(
            executable: shell,
            args: ["-l", "-c", command],
            environment: env,
            execName: shell,
            currentDirectory: workingDirectory
        )

        process.pid = terminalView.process.shellPid
        process.status = .running
        process.stoppedAt = nil
        logLifecycle("start", sessionId: sessionId, pid: process.pid)
        terminalViews[sessionId] = terminalView

        lastDataReceived[sessionId] = Date()
        lastInteraction[sessionId] = Date()
        startIdleTimer()
    }

    // MARK: - Fork Session

    /// Forks a session. Claude uses `--resume {id} --fork-session`, Codex uses `fork {id}`.
    /// Creates a brand-new session that inherits conversation history up to the fork point.
    /// Returns the new session ID.
    func forkSession(sourceSessionId: UUID, agent: Agent? = nil, memoryContext: String? = nil, workingDirectory: String? = nil, memoryDbPath: String? = nil) throws -> UUID {
        guard let sourceProcess = processes[sourceSessionId],
              let resumeId = sourceProcess.claudeResumeId else {
            throw ProcessManagerError.noResumeId
        }
        let provider = sourceProcess.cliProviderType
        guard let cliPath = cliPathResolver.resolve(for: provider) else {
            throw ProcessManagerError.cliNotFound(provider)
        }

        let newSessionId = UUID()
        let terminalView = createTerminalView(sessionId: newSessionId)

        var args: [String]
        switch provider {
        case .claude:
            args = ["--resume", resumeId, "--fork-session"]
            if agent?.permissionMode == .bypassPermissions {
                args.append("--dangerously-skip-permissions")
            }
        case .codex:
            args = ["fork", resumeId]
            // Codex filters by CWD — pass -C to match the original session's directory
            if let workingDirectory {
                args += ["-C", workingDirectory]
            }
            if agent?.permissionMode == .bypassPermissions {
                args.append("--yolo")
            }
        }

        var env = buildEnvironment()
        switch provider {
        case .claude:
            appendClaudeSystemPrompt(memoryContext: memoryContext, args: &args, env: &env)
        case .codex:
            appendCodexDeveloperInstructions(args: &args, env: &env)
            if let memoryContext, !memoryContext.isEmpty {
                writeTemporaryAgentsMd(systemPrompt: memoryContext, workingDirectory: workingDirectory)
            }
        }

        if let memoryDbPath {
            env.append("CONCLAWD_MEMORY_DB_PATH=\(memoryDbPath)")
        }
        let agentName = agent?.name ?? "main"
        env.append("CONCLAWD_AGENT_NAME=\(agentName)")
        env.append("CONCLAWD_SESSION_ID=\(newSessionId.uuidString)")

        args += buildMcpConfigArgs(memoryDbPath: memoryDbPath, agentName: agentName, sessionId: newSessionId, provider: provider)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let escapedCli = cliPath.replacingOccurrences(of: " ", with: "\\ ")
        let escapedArgs = args.map { "\"\($0)\"" }.joined(separator: " ")
        let command = "\(escapedCli) \(escapedArgs)"

        terminalView.startProcess(
            executable: shell,
            args: ["-l", "-c", command],
            environment: env,
            execName: shell,
            currentDirectory: workingDirectory
        )

        let startTime = Date()
        let process = AgentProcess(agentId: sourceProcess.agentId)
        process.pid = terminalView.process.shellPid
        process.status = .running
        logLifecycle("start", sessionId: newSessionId, pid: process.pid)
        process.cliProviderType = provider
        processes[newSessionId] = process
        terminalViews[newSessionId] = terminalView

        lastDataReceived[newSessionId] = startTime
        lastInteraction[newSessionId] = startTime
        startIdleTimer()

        if provider == .claude {
            probeClaudeSessionIdWithRetry(sessionId: newSessionId, workingDir: workingDirectory, startTime: startTime)
        }

        return newSessionId
    }

    /// Forks a session from a history record's resume ID.
    /// Returns the new session ID.
    func forkFromHistory(resumeId: String, agentId: UUID, agent: Agent? = nil, memoryContext: String? = nil, workingDirectory: String? = nil, memoryDbPath: String? = nil, provider: CLIProviderType = .claude) throws -> UUID {
        guard let cliPath = cliPathResolver.resolve(for: provider) else {
            throw ProcessManagerError.cliNotFound(provider)
        }

        let newSessionId = UUID()
        let terminalView = createTerminalView(sessionId: newSessionId)

        var args: [String]
        switch provider {
        case .claude:
            args = ["--resume", resumeId, "--fork-session"]
            if agent?.permissionMode == .bypassPermissions {
                args.append("--dangerously-skip-permissions")
            }
        case .codex:
            args = ["fork", resumeId]
            // Codex filters by CWD — pass -C to match the original session's directory
            if let workingDirectory {
                args += ["-C", workingDirectory]
            }
            if agent?.permissionMode == .bypassPermissions {
                args.append("--yolo")
            }
        }

        var env = buildEnvironment()
        switch provider {
        case .claude:
            appendClaudeSystemPrompt(memoryContext: memoryContext, args: &args, env: &env)
        case .codex:
            appendCodexDeveloperInstructions(args: &args, env: &env)
            if let memoryContext, !memoryContext.isEmpty {
                writeTemporaryAgentsMd(systemPrompt: memoryContext, workingDirectory: workingDirectory)
            }
        }

        if let memoryDbPath {
            env.append("CONCLAWD_MEMORY_DB_PATH=\(memoryDbPath)")
        }
        let agentName = agent?.name ?? "main"
        env.append("CONCLAWD_AGENT_NAME=\(agentName)")
        env.append("CONCLAWD_SESSION_ID=\(newSessionId.uuidString)")

        args += buildMcpConfigArgs(memoryDbPath: memoryDbPath, agentName: agentName, sessionId: newSessionId, provider: provider)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let escapedCli = cliPath.replacingOccurrences(of: " ", with: "\\ ")
        let escapedArgs = args.map { "\"\($0)\"" }.joined(separator: " ")
        let command = "\(escapedCli) \(escapedArgs)"

        terminalView.startProcess(
            executable: shell,
            args: ["-l", "-c", command],
            environment: env,
            execName: shell,
            currentDirectory: workingDirectory
        )

        let startTime = Date()
        let process = AgentProcess(agentId: agentId)
        process.pid = terminalView.process.shellPid
        process.status = .running
        logLifecycle("start", sessionId: newSessionId, pid: process.pid)
        process.cliProviderType = provider
        processes[newSessionId] = process
        terminalViews[newSessionId] = terminalView

        lastDataReceived[newSessionId] = startTime
        lastInteraction[newSessionId] = startTime
        startIdleTimer()

        if provider == .claude {
            probeClaudeSessionIdWithRetry(sessionId: newSessionId, workingDir: workingDirectory, startTime: startTime)
        }

        return newSessionId
    }

    // MARK: - Activity Tracking

    private func handleDataReceived(sessionId: UUID) {
        lastDataReceived[sessionId] = Date()

        if expectingResponse[sessionId] == true,
           let process = processes[sessionId],
           process.status == .waitingForInput {
            process.status = .running
            // Agent started responding — meaningful interaction
            lastInteraction[sessionId] = Date()
        }
    }

    private func handlePromptSubmitted(sessionId: UUID, promptText: String? = nil) {
        guard let process = processes[sessionId], process.status.isActive else { return }
        expectingResponse[sessionId] = true
        process.status = .running
        lastDataReceived[sessionId] = Date()
        // User submitted a prompt — meaningful interaction
        lastInteraction[sessionId] = Date()
        if let text = promptText, !text.isEmpty {
            lastUserPrompt[sessionId] = text
        }
    }

    private func startIdleTimer() {
        guard idleTimer == nil else { return }

        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkIdleSessions()
            }
        }
    }

    private func stopIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func checkIdleSessions() {
        let now = Date()
        var hasActiveProcesses = false

        for (sessionId, process) in processes {
            guard process.status.isActive else { continue }
            hasActiveProcesses = true

            if process.status == .running,
               let lastData = lastDataReceived[sessionId],
               now.timeIntervalSince(lastData) >= idleThreshold {
                process.status = .waitingForInput
                expectingResponse[sessionId] = false
                onStatusChanged?(sessionId, .waitingForInput)

                // Mark as unread only when the agent finishes responding (not on every data chunk)
                if !viewingSessionIds.contains(sessionId) {
                    process.hasUnreadOutput = true
                }
            }
        }

        if !hasActiveProcesses {
            stopIdleTimer()
        }
    }

    // MARK: - Resume ID Extraction

    /// Eagerly extracts the resume ID from terminal output.
    /// Called as soon as "--resume" is detected in incoming data,
    /// so the ID is captured before process termination / cleanup.
    private func tryExtractResumeId(sessionId: UUID) {
        guard let process = processes[sessionId],
              process.claudeResumeId == nil,
              let text = getTerminalText(sessionId: sessionId),
              let resumeId = Self.extractResumeId(from: text) else { return }
        process.claudeResumeId = resumeId
        print("[ResumeID] 経路1 tryExtractResumeId: \(resumeId) for \(sessionId)")
        onResumeIdDetected?(sessionId, resumeId)
    }

    /// Proactively detects the Claude session ID by scanning the Claude projects
    /// directory for a newly created .jsonl transcript file.
    /// Called shortly after session start so the resume ID is captured even if
    /// the app is later force-quit or crashes.
    /// Probes for the Claude session ID with retries at increasing intervals.
    /// .jsonl creation can take 40-90+ seconds, so a single early probe often misses.
    private func probeClaudeSessionIdWithRetry(sessionId: UUID, workingDir: String?, startTime: Date) {
        let delaysNs: [UInt64] = [
            3_000_000_000,   // 3 seconds
            15_000_000_000,  // 15 seconds
            60_000_000_000,  // 60 seconds
        ]
        Task { @MainActor [weak self] in
            for delay in delaysNs {
                try? await Task.sleep(nanoseconds: delay)
                guard let self,
                      let process = self.processes[sessionId],
                      process.claudeResumeId == nil else { return }
                guard let workingDir else { return }
                // Collect Claude session IDs already claimed by other processes
                // to avoid assigning the same .jsonl to multiple sessions.
                let claimedIds = self.claimedResumeIds(excluding: sessionId)
                if let resumeId = Self.findClaudeSessionId(workingDirectory: workingDir, aroundTime: startTime, excludingIds: claimedIds) {
                    process.claudeResumeId = resumeId
                    print("[ResumeID] 経路2 probe found: \(resumeId) for \(sessionId)")
                    self.onResumeIdDetected?(sessionId, resumeId)
                    return
                }
            }
        }
    }

    /// Returns the set of Claude resume IDs already assigned to other processes.
    private func claimedResumeIds(excluding sessionId: UUID) -> Set<String> {
        var ids = Set<String>()
        for (id, process) in processes where id != sessionId {
            if let rid = process.claudeResumeId {
                ids.insert(rid)
            }
        }
        return ids
    }

    /// Scans `~/.claude/projects/{project-hash}/` for a .jsonl transcript file
    /// created around the given time and returns its filename (= session ID) if found.
    /// - Parameter excludingIds: Claude session IDs already claimed by other processes — these are skipped.
    static func findClaudeSessionId(workingDirectory: String, aroundTime: Date, maxDelay: TimeInterval = 120, excludingIds: Set<String> = []) -> String? {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let trimmed = workingDirectory.hasSuffix("/") ? String(workingDirectory.dropLast()) : workingDirectory
        let projectHash = trimmed.replacingOccurrences(of: "/", with: "-")
        let projectDir = homeDir
            .appending(path: ".claude/projects")
            .appending(path: projectHash)

        guard let files = try? fm.contentsOfDirectory(
            at: projectDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        // Find .jsonl files created within a reasonable window of aroundTime.
        // The upper bound is generous (default 120s) because Claude CLI can take
        // 40-90+ seconds to create the transcript file.
        let candidates = files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (String, Date)? in
                let id = url.deletingPathExtension().lastPathComponent
                // Skip IDs already assigned to another session
                guard !excludingIds.contains(id) else { return nil }
                guard let attrs = try? url.resourceValues(forKeys: [.creationDateKey]),
                      let created = attrs.creationDate,
                      created >= aroundTime.addingTimeInterval(-5),
                      created <= aroundTime.addingTimeInterval(maxDelay) else { return nil }
                return (id, created)
            }
            .sorted { abs($0.1.timeIntervalSince(aroundTime)) < abs($1.1.timeIntervalSince(aroundTime)) }

        return candidates.first?.0
    }

    // MARK: - Codex Session ID Detection

    /// Probes for the Codex session ID with retries at increasing intervals.
    /// Codex stores sessions under `~/.codex/sessions/YYYY/MM/DD/{session-id}.jsonl`.
    private func probeCodexSessionIdWithRetry(sessionId: UUID, startTime: Date) {
        let delaysNs: [UInt64] = [
            3_000_000_000,   // 3 seconds
            15_000_000_000,  // 15 seconds
            60_000_000_000,  // 60 seconds
        ]
        Task { @MainActor [weak self] in
            for delay in delaysNs {
                try? await Task.sleep(nanoseconds: delay)
                guard let self,
                      let process = self.processes[sessionId],
                      process.claudeResumeId == nil else { return }
                let claimedIds = self.claimedResumeIds(excluding: sessionId)
                if let resumeId = Self.findCodexSessionId(aroundTime: startTime, excludingIds: claimedIds) {
                    process.claudeResumeId = resumeId
                    print("[ResumeID] Codex probe found: \(resumeId) for \(sessionId)")
                    self.onResumeIdDetected?(sessionId, resumeId)
                    return
                }
            }
            print("[ResumeID] Codex probe exhausted — no session file found for \(sessionId)")
        }
    }

    /// Scans `~/.codex/sessions/YYYY/MM/DD/` for a .jsonl file created around the given time.
    /// Returns the UUID portion of the filename (e.g. "019d4284-ced4-7df1-a525-cab4daedf52d")
    /// which is used as the thread ID for `codex resume {id}`.
    /// Filename format: `rollout-{YYYY-MM-DD}T{HH-MM-SS}-{UUID}.jsonl`
    static func findCodexSessionId(aroundTime: Date, maxDelay: TimeInterval = 120, excludingIds: Set<String> = []) -> String? {
        let fm = FileManager.default
        let codexHome: URL
        if let envHome = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            codexHome = URL(fileURLWithPath: envHome)
        } else {
            codexHome = fm.homeDirectoryForCurrentUser.appending(path: ".codex")
        }
        let sessionsDir = codexHome.appending(path: "sessions")

        // Codex stores sessions as YYYY/MM/DD/rollout-{timestamp}-{UUID}.jsonl
        // Scan date directories around the start time (today and yesterday to handle midnight edge)
        let calendar = Calendar.current
        let dates = [aroundTime, aroundTime.addingTimeInterval(-86400)]
        var allCandidates: [(String, Date)] = []

        // Regex to extract UUID from filename like "rollout-2026-03-31T15-11-33-019d4284-ced4-7df1-a525-cab4daedf52d"
        let uuidPattern = try? NSRegularExpression(
            pattern: #"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$"#
        )

        for date in dates {
            let year = String(format: "%04d", calendar.component(.year, from: date))
            let month = String(format: "%02d", calendar.component(.month, from: date))
            let day = String(format: "%02d", calendar.component(.day, from: date))
            let dayDir = sessionsDir
                .appending(path: year)
                .appending(path: month)
                .appending(path: day)

            guard let files = try? fm.contentsOfDirectory(
                at: dayDir,
                includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles
            ) else { continue }

            let candidates = files
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { url -> (String, Date)? in
                    let filename = url.deletingPathExtension().lastPathComponent
                    // Extract UUID from the end of the filename
                    guard let regex = uuidPattern,
                          let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
                          let range = Range(match.range(at: 1), in: filename) else {
                        print("[ResumeID] findCodexSessionId: could not extract UUID from filename: \(filename)")
                        return nil
                    }
                    let threadId = String(filename[range])
                    guard !excludingIds.contains(threadId) else { return nil }
                    guard let attrs = try? url.resourceValues(forKeys: [.creationDateKey]),
                          let created = attrs.creationDate,
                          created >= aroundTime.addingTimeInterval(-5),
                          created <= aroundTime.addingTimeInterval(maxDelay) else { return nil }
                    return (threadId, created)
                }
            allCandidates.append(contentsOf: candidates)
        }

        allCandidates.sort { abs($0.1.timeIntervalSince(aroundTime)) < abs($1.1.timeIntervalSince(aroundTime)) }
        let result = allCandidates.first?.0
        print("[ResumeID] findCodexSessionId: scanned ~/.codex/sessions/, found=\(result ?? "nil"), candidates=\(allCandidates.count)")
        return result
    }

    // MARK: - Process Termination

    func handleProcessTerminated(sessionId: UUID, exitCode: Int32?) {
        guard let process = processes[sessionId] else { return }
        // Status before overwrite distinguishes an expected death (we already
        // marked it .stopped via stop()) from a spontaneous one (.running).
        let wasExpected = !process.status.isActive
        SessionDiagnosticsLog.shared.log(
            "terminated (\(wasExpected ? "after stop" : "SPONTANEOUS")) "
            + "session=\(sessionId) pid=\(process.pid) "
            + SessionDiagnosticsLog.describeExitCode(exitCode))
        process.status = .stopped(exitCode: exitCode)
        process.stoppedAt = Date()

        // Capture terminal text before cleanup, then notify
        let text = getTerminalText(sessionId: sessionId)

        // Log terminal output for debugging resume ID extraction
        if let text {
            let lastLines = text.suffix(500)
            print("[ResumeID] 経路3 terminal output (last 500 chars) for \(sessionId) [provider=\(process.cliProviderType.rawValue)]:")
            print(lastLines)
        } else {
            print("[ResumeID] 経路3 terminal output: nil for \(sessionId)")
        }

        // Extract resume session ID from terminal output.
        if process.claudeResumeId == nil, let text {
            switch process.cliProviderType {
            case .claude:
                let extracted = Self.extractResumeId(from: text)
                process.claudeResumeId = extracted
                print("[ResumeID] 経路3 handleProcessTerminated (claude): \(extracted ?? "nil") for \(sessionId)")
            case .codex:
                // Codex doesn't print resume info to terminal.
                // Try filesystem fallback if probe hasn't found it yet.
                let claimedIds = claimedResumeIds(excluding: sessionId)
                let extracted = Self.findCodexSessionId(aroundTime: process.startedAt, excludingIds: claimedIds)
                process.claudeResumeId = extracted
                print("[ResumeID] 経路3 handleProcessTerminated (codex filesystem): \(extracted ?? "nil") for \(sessionId)")
            }
        } else {
            print("[ResumeID] 経路3 handleProcessTerminated: already set=\(process.claudeResumeId ?? "nil") for \(sessionId)")
        }

        onSessionTerminated?(sessionId, text, process.agentId)

        lastDataReceived.removeValue(forKey: sessionId)
    }

    /// Extracts a CLI resume session ID from terminal output.
    /// Matches Claude (`--resume "id"` / `--resume UUID`) and Codex (`codex resume UUID` / `codex resume "name"`).
    static func extractResumeId(from text: String) -> String? {
        // Search from the end since the resume line appears at the bottom.
        let patterns: [String] = [
            // Claude: --resume "session-name"
            #"--resume\s+"([^"]+)""#,
            // Claude: --resume UUID
            #"--resume\s+([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"#,
            // Codex: codex resume "session-name"
            #"codex\s+resume\s+"([^"]+)""#,
            // Codex: codex resume UUID
            #"codex\s+resume\s+([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return String(text[range])
        }
        return nil
    }

    // MARK: - Diagnostics

    /// Records a lifecycle event for a session process. `function` defaults to
    /// the caller, so start sites are attributed automatically.
    private func logLifecycle(_ event: String, sessionId: UUID, pid: pid_t, function: String = #function) {
        SessionDiagnosticsLog.shared.log("\(event) via \(function) session=\(sessionId) pid=\(pid)")
    }

    // MARK: - Stop / Kill

    func stop(sessionId: UUID, reason: String) {
        guard let process = processes[sessionId], process.status.isActive else { return }

        SessionDiagnosticsLog.shared.log(
            "SIGTERM (reason: \(reason)) session=\(sessionId) pid=\(process.pid)")
        if process.pid > 0 {
            kill(process.pid, SIGTERM)
        }

        process.status = .stopped(exitCode: nil)
        process.stoppedAt = Date()
        lastDataReceived.removeValue(forKey: sessionId)
    }

    func forceKill(sessionId: UUID, reason: String) {
        guard let process = processes[sessionId], process.status.isActive else { return }

        SessionDiagnosticsLog.shared.log(
            "SIGKILL (reason: \(reason)) session=\(sessionId) pid=\(process.pid)")
        if process.pid > 0 {
            kill(process.pid, SIGKILL)
        }

        process.status = .stopped(exitCode: nil)
        process.stoppedAt = Date()
        lastDataReceived.removeValue(forKey: sessionId)
    }

    /// Registers a pre-built process for a given session (used for history resume).
    func registerProcess(sessionId: UUID, process: AgentProcess) {
        processes[sessionId] = process
    }

    /// Clears the unread flag for a session.
    func markAsRead(sessionId: UUID) {
        processes[sessionId]?.hasUnreadOutput = false
    }

    /// Removes the terminal view from the view hierarchy without destroying
    /// the process entry or delegate. This keeps the `processTerminated`
    /// callback alive so it can capture the resume ID after SIGTERM.
    func detachTerminalView(sessionId: UUID) {
        terminalViews[sessionId]?.removeFromSuperview()
    }

    func removeProcess(sessionId: UUID) {
        if let process = processes[sessionId] {
            SessionDiagnosticsLog.shared.log(
                "removeProcess session=\(sessionId) pid=\(process.pid) "
                + "stillActive=\(process.status.isActive)")
        }
        if let terminalView = terminalViews[sessionId] {
            terminalView.removeFromSuperview()
        }
        processes.removeValue(forKey: sessionId)
        terminalViews.removeValue(forKey: sessionId)
        delegates.removeValue(forKey: sessionId)
        lastDataReceived.removeValue(forKey: sessionId)
        lastInteraction.removeValue(forKey: sessionId)
        expectingResponse.removeValue(forKey: sessionId)
        lastUserPrompt.removeValue(forKey: sessionId)
    }

    // MARK: - Status

    func isRunning(sessionId: UUID) -> Bool {
        processes[sessionId]?.status.isActive ?? false
    }

    func status(sessionId: UUID) -> AgentProcessStatus {
        processes[sessionId]?.status ?? .stopped(exitCode: nil)
    }

    /// Last activity timestamp for a session (data received or user input).
    func lastActivity(sessionId: UUID) -> Date? {
        lastDataReceived[sessionId]
    }

    // MARK: - Context Sharing

    /// Retrieves the terminal buffer text for a session.
    func getTerminalText(sessionId: UUID) -> String? {
        guard let terminalView = terminalViews[sessionId] else { return nil }
        let terminal = terminalView.getTerminal()
        let data = terminal.getBufferAsData(kind: .active, encoding: .utf8)
        return String(data: data, encoding: .utf8)
    }

    /// Sends text input to a session's terminal as if the user typed it.
    func sendInput(sessionId: UUID, text: String) {
        guard let terminalView = terminalViews[sessionId] else { return }
        terminalView.send(txt: text)
    }

    /// Sends text as a bracketed paste, matching drag & drop behavior.
    func sendPasteInput(sessionId: UUID, text: String) {
        guard let terminalView = terminalViews[sessionId] else { return }
        terminalView.sendAsInput(text)
    }

    /// Notifies the process manager that a prompt was programmatically submitted
    /// (e.g. by scheduled execution), so it can update status tracking.
    func notifyPromptSubmitted(sessionId: UUID, promptText: String? = nil) {
        handlePromptSubmitted(sessionId: sessionId, promptText: promptText)
    }

    // MARK: - Cleanup

    func terminateAll() {
        stopIdleTimer()
        for (sessionId, process) in processes where process.status.isActive {
            stop(sessionId: sessionId, reason: "terminateAll")
        }
    }

    // MARK: - Theme

    /// Helper: 8-bit RGB (0-255) → SwiftTerm.Color (16-bit, 0-65535).
    private static func rgb8(_ r: Int, _ g: Int, _ b: Int) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(r * 257), green: UInt16(g * 257), blue: UInt16(b * 257))
    }

    /// ANSI 16-color palette tuned for the Claude beige background (#F5EFE6).
    /// Colors are selected to be readable on a warm light background.
    private static let claudeAnsiPalette: [SwiftTerm.Color] = [
        rgb8(59,  50,  38),   // 0 black        — #3B3226
        rgb8(175, 48,  41),   // 1 red          — #AF3029
        rgb8(102, 128, 11),   // 2 green        — #66800B
        rgb8(173, 131, 1),    // 3 yellow       — #AD8301
        rgb8(32,  94,  166),  // 4 blue         — #205EA6
        rgb8(160, 47,  111),  // 5 magenta      — #A02F6F
        rgb8(36,  131, 123),  // 6 cyan         — #24837B
        rgb8(107, 93,  74),   // 7 white (dim)  — #6B5D4A
        rgb8(100, 85,  66),   // 8 bright black — #645542
        rgb8(209, 77,  65),   // 9 bright red
        rgb8(135, 154, 57),   // 10 bright green
        rgb8(190, 144, 0),    // 11 bright yellow
        rgb8(67,  133, 190),  // 12 bright blue
        rgb8(206, 93,  151),  // 13 bright magenta
        rgb8(58,  169, 159),  // 14 bright cyan
        rgb8(59,  50,  38),   // 15 bright white — matches foreground
    ]

    /// Standard xterm ANSI palette (fallback when not in Claude theme).
    private static let defaultAnsiPalette: [SwiftTerm.Color] = [
        rgb8(0,   0,   0),    // 0 black
        rgb8(205, 0,   0),    // 1 red
        rgb8(0,   205, 0),    // 2 green
        rgb8(205, 205, 0),    // 3 yellow
        rgb8(0,   0,   238),  // 4 blue
        rgb8(205, 0,   205),  // 5 magenta
        rgb8(0,   205, 205),  // 6 cyan
        rgb8(229, 229, 229),  // 7 white
        rgb8(127, 127, 127),  // 8 bright black
        rgb8(255, 0,   0),    // 9 bright red
        rgb8(0,   255, 0),    // 10 bright green
        rgb8(255, 255, 0),    // 11 bright yellow
        rgb8(92,  92,  255),  // 12 bright blue
        rgb8(255, 0,   255),  // 13 bright magenta
        rgb8(0,   255, 255),  // 14 bright cyan
        rgb8(255, 255, 255),  // 15 bright white
    ]

    /// Creates and configures a new terminal view with the current theme.
    private func createTerminalView(sessionId: UUID) -> IMETerminalView {
        let theme = TerminalTheme.current
        let fontSize = UserDefaults.standard.double(forKey: "terminalFontSize")
        let size = fontSize > 0 ? fontSize : 13.0

        let terminalView = IMETerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminalView.changeScrollback(10_000)
        terminalView.nativeBackgroundColor = theme.background
        terminalView.nativeForegroundColor = theme.foreground
        terminalView.font = NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)

        // Install ANSI palette matching the current theme
        terminalView.installColors(NSColor.isClaudeTheme ? Self.claudeAnsiPalette : Self.defaultAnsiPalette)

        // Apply cursor style from settings
        let cursorKey = UserDefaults.standard.string(forKey: "terminalCursorStyle") ?? TerminalCursorStyleSetting.block.rawValue
        if let cursorSetting = TerminalCursorStyleSetting(rawValue: cursorKey) {
            let swiftTermStyle: CursorStyle = switch cursorSetting {
            case .block: .steadyBlock
            case .bar: .steadyBar
            case .underline: .steadyUnderline
            }
            terminalView.getTerminal().setCursorStyle(swiftTermStyle)
        }

        let bridge = TerminalDelegateBridge(sessionId: sessionId, manager: self)
        terminalView.processDelegate = bridge
        delegates[sessionId] = bridge

        terminalView.onDataReceived = { [weak self] in
            Task { @MainActor in
                self?.handleDataReceived(sessionId: sessionId)
            }
        }
        terminalView.onPromptSubmitted = { [weak self] promptText in
            Task { @MainActor in
                self?.handlePromptSubmitted(sessionId: sessionId, promptText: promptText)
            }
        }
        terminalView.onResumeLineDetected = { [weak self] in
            Task { @MainActor in
                self?.tryExtractResumeId(sessionId: sessionId)
            }
        }

        return terminalView
    }

    /// Update the theme for all existing terminal views (e.g., when appearance changes).
    func updateTheme() {
        let theme = TerminalTheme.current
        let isClaude = NSColor.isClaudeTheme
        for (_, terminalView) in terminalViews {
            terminalView.nativeBackgroundColor = theme.background
            terminalView.nativeForegroundColor = theme.foreground
            terminalView.installColors(isClaude ? Self.claudeAnsiPalette : Self.defaultAnsiPalette)
            terminalView.needsDisplay = true
        }
    }

    // MARK: - Helpers

    private func buildEnvironment() -> [String] {
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        // Augmented PATH ensures npm-installed shims like `codex` can always
        // find their `node` interpreter even when the app was launched from
        // Finder and did not inherit terminal-specific PATH entries.
        env.append("PATH=\(CLIPathResolver.augmentedPATH())")
        env.append("FORCE_COLOR=1")
        // Session-control integration: lets in-session Claude ask the app to
        // split a topic into a new session tab (conclawd-session-split skill).
        if let helperPath = Self.sessionControlCLIPath {
            env.append("CONCLAWD_CLI=\(helperPath)")
        }
        env.append("CONCLAWD_SOCKET=\(SessionControlProtocol.defaultSocketPath)")
        return env
    }

    /// Path to the bundled `conclawd` helper CLI, if present in the app bundle.
    private static let sessionControlCLIPath: String? = {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/conclawd")
        let path = url.path(percentEncoded: false)
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }()

    // MARK: - Claude Agent Args Builder

    /// Builds CLI arguments for launching an agent session with Claude.
    private func buildClaudeAgentArgs(agent: Agent, effectiveModel: AgentModel, memoryContext: String?, env: inout [String]) -> [String] {
        var args: [String] = []

        // `claude --agent <name>` only works when the CLI can discover the
        // agent's definition, which requires a non-empty `description` in the
        // frontmatter AND the .md file to exist on disk. Otherwise the CLI
        // reports `--agent '<name>' not found. Available agents: ...`.
        // When the agent isn't discoverable, fall back to launching without
        // `--agent` and injecting the agent's settings (system prompt, tools)
        // directly via flags so the session still starts.
        let fileExists = agent.filePath.map {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        } ?? false
        let isDiscoverable = !agent.description.isEmpty && fileExists

        if isDiscoverable {
            args += ["--agent", agent.name]
        } else {
            print("[AgentProcessManager] Agent '\(agent.name)' not discoverable via --agent "
                + "(description empty: \(agent.description.isEmpty), file exists: \(fileExists)); "
                + "falling back to inline system prompt injection")
            if !agent.tools.isEmpty {
                args += ["--allowedTools", agent.tools.joined(separator: ",")]
            }
            if !agent.disallowedTools.isEmpty {
                args += ["--disallowedTools", agent.disallowedTools.joined(separator: ",")]
            }
        }

        if effectiveModel != .inherit {
            args += ["--model", effectiveModel.cliModelId(for: .claude)]
        }
        args += agent.permissionMode.cliArgs(for: .claude)

        // Assemble the appended system prompt. In the fallback path the agent's
        // own system prompt must be injected here (normally `--agent` carries
        // it); memory context is appended in both paths.
        var appendParts: [String] = []
        if !isDiscoverable, !agent.systemPrompt.isEmpty {
            appendParts.append(agent.systemPrompt)
        }
        if let memoryContext, !memoryContext.isEmpty {
            appendParts.append(memoryContext)
        }
        appendClaudeSystemPrompt(
            memoryContext: appendParts.isEmpty ? nil : appendParts.joined(separator: "\n\n---\n\n"),
            args: &args, env: &env)
        return args
    }

    /// Appends `--append-system-prompt` carrying the Conclawd integration
    /// instructions (when the helper CLI is bundled) plus any extra context.
    /// The payload travels through an environment variable so it never hits
    /// the command line.
    private func appendClaudeSystemPrompt(memoryContext: String?, args: inout [String], env: inout [String]) {
        guard let prompt = SessionControlPrompt.combined(
            with: memoryContext, cliAvailable: Self.sessionControlCLIPath != nil) else { return }
        env.append("_AGENT_TERMINAL_APPEND_PROMPT=\(prompt)")
        args += ["--append-system-prompt", "$_AGENT_TERMINAL_APPEND_PROMPT"]
    }

    /// Codex counterpart of `appendClaudeSystemPrompt`: passes the Conclawd
    /// integration instructions through `-c developer_instructions=...`. The
    /// whole TOML assignment travels in an environment variable that the login
    /// shell expands into a single argument, so nothing is written to disk.
    private func appendCodexDeveloperInstructions(args: inout [String], env: inout [String]) {
        guard Self.sessionControlCLIPath != nil else { return }
        let assignment = "developer_instructions=" + SessionControlPrompt.tomlBasicString(SessionControlPrompt.text)
        env.append("_CONCLAWD_CODEX_INSTRUCTIONS=\(assignment)")
        args += ["-c", "$_CONCLAWD_CODEX_INSTRUCTIONS"]
    }

    // MARK: - Codex Agent Args Builder

    /// Builds CLI arguments for launching an agent session with Codex.
    /// Generates a temporary AGENTS.md to inject the agent's system prompt and memory context.
    private func buildCodexAgentArgs(agent: Agent, effectiveModel: AgentModel, memoryContext: String?, workingDirectory: String?, env: inout [String]) -> [String] {
        var args: [String] = []

        // Model
        if effectiveModel != .inherit {
            args += ["-m", effectiveModel.cliModelId(for: .codex)]
        }

        // Permission mode
        args += agent.permissionMode.cliArgs(for: .codex)

        // Explicitly set working directory so Codex records the correct CWD in its thread DB
        if let workingDirectory {
            args += ["-C", workingDirectory]
        }

        appendCodexDeveloperInstructions(args: &args, env: &env)

        // Inject system prompt + memory via temporary AGENTS.md
        var agentsMdContent = ""
        if !agent.systemPrompt.isEmpty {
            agentsMdContent += agent.systemPrompt
        }
        if let memoryContext, !memoryContext.isEmpty {
            if !agentsMdContent.isEmpty { agentsMdContent += "\n\n---\n\n" }
            agentsMdContent += memoryContext
        }
        if !agentsMdContent.isEmpty {
            writeTemporaryAgentsMd(systemPrompt: agentsMdContent, workingDirectory: workingDirectory)
        }

        return args
    }

    // MARK: - Temporary AGENTS.md

    /// Writes a temporary AGENTS.md file for Codex sessions.
    /// Codex reads AGENTS.md from the working directory for system instructions.
    /// The file is prefixed with a comment so we can identify and clean it up later.
    private func writeTemporaryAgentsMd(systemPrompt: String, workingDirectory: String?) {
        guard let workingDir = workingDirectory else { return }
        let agentsMdPath = URL(filePath: workingDir).appending(path: "AGENTS.md")
        let marker = "<!-- conclawd-temporary -->"
        let content = "\(marker)\n\(systemPrompt)\n"

        // Don't overwrite an existing AGENTS.md that isn't ours
        if FileManager.default.fileExists(atPath: agentsMdPath.path(percentEncoded: false)) {
            if let existing = try? String(contentsOf: agentsMdPath, encoding: .utf8),
               !existing.hasPrefix(marker) {
                // Existing AGENTS.md not created by us — prepend to it instead
                let merged = "\(content)\n---\n\n\(existing)"
                try? merged.write(to: agentsMdPath, atomically: true, encoding: .utf8)
                return
            }
        }
        try? content.write(to: agentsMdPath, atomically: true, encoding: .utf8)
    }

    /// Removes temporary AGENTS.md files created by Conclawd.
    func cleanupTemporaryAgentsMd(workingDirectory: String?) {
        guard let workingDir = workingDirectory else { return }
        let agentsMdPath = URL(filePath: workingDir).appending(path: "AGENTS.md")
        guard let content = try? String(contentsOf: agentsMdPath, encoding: .utf8),
              content.hasPrefix("<!-- conclawd-temporary -->") else { return }
        try? FileManager.default.removeItem(at: agentsMdPath)
    }

    /// Build MCP config arguments for the Conclawd MCP server.
    /// For Claude: returns ["--mcp-config", path]. For Codex: returns ["-c", "key=value", ...].
    private func buildMcpConfigArgs(memoryDbPath: String?, agentName: String, sessionId: UUID, provider: CLIProviderType = .claude) -> [String] {
        let nodeCommand = cliPathResolver.resolveBinary(named: "node") ?? "node"

        // Resolve the MCP server entry point (built JS)
        let mcpServerPath = Bundle.main.resourceURL?
            .deletingLastPathComponent()  // Contents/Resources → Contents/
            .deletingLastPathComponent()  // Contents/ → .app/
            .deletingLastPathComponent()  // .app/ → parent directory
            .appending(path: "app-mcp/dist/index.js")
            .path(percentEncoded: false)
            ?? ""

        // Fallback: try relative to the project source tree (development mode)
        let resolvedPath: String
        if FileManager.default.fileExists(atPath: mcpServerPath) {
            resolvedPath = mcpServerPath
        } else {
            // Development: resolve from CONCLAWD_PROJECT_ROOT environment variable
            guard let projectRoot = ProcessInfo.processInfo.environment["CONCLAWD_PROJECT_ROOT"] else { return [] }
            let devPath = projectRoot + "/app-mcp/dist/index.js"
            guard FileManager.default.fileExists(atPath: devPath) else { return [] }
            resolvedPath = devPath
        }

        var env: [String: String] = [
            "CONCLAWD_AGENT_NAME": agentName,
            "CONCLAWD_SESSION_ID": sessionId.uuidString,
        ]
        if let memoryDbPath {
            env["CONCLAWD_MEMORY_DB_PATH"] = memoryDbPath
        }

        // Build MCP config as a temporary JSON file (--mcp-config expects a file path)
        let config: [String: Any] = [
            "mcpServers": [
                "conclawd-memory": [
                    "type": "stdio",
                    "command": nodeCommand,
                    "args": [resolvedPath],
                    "env": env,
                ]
            ]
        ]

        switch provider {
        case .claude:
            let config: [String: Any] = [
                "mcpServers": [
                    "conclawd-memory": [
                        "type": "stdio",
                        "command": nodeCommand,
                        "args": [resolvedPath],
                        "env": env,
                    ]
                ]
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: config),
                  let jsonString = String(data: data, encoding: .utf8) else { return [] }

            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("conclawd-mcp", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let configFile = tmpDir.appendingPathComponent("\(sessionId.uuidString).json")
            try? jsonString.write(to: configFile, atomically: true, encoding: .utf8)
            return ["--mcp-config", configFile.path]

        case .codex:
            // Codex uses -c key=value (TOML syntax) for per-session MCP config
            let escapedPath = resolvedPath.replacingOccurrences(of: "\"", with: "\\\"")
            let escapedNodeCommand = nodeCommand.replacingOccurrences(of: "\"", with: "\\\"")
            var configArgs = [
                "-c", "mcp_servers.conclawd-memory.command=\"\(escapedNodeCommand)\"",
                "-c", "mcp_servers.conclawd-memory.args=[\"\(escapedPath)\"]",
            ]
            for (key, value) in env {
                let escapedValue = value.replacingOccurrences(of: "\"", with: "\\\"")
                configArgs += ["-c", "mcp_servers.conclawd-memory.env.\(key)=\"\(escapedValue)\""]
            }
            return configArgs
        }
    }
}

// MARK: - Delegate Bridge

final class TerminalDelegateBridge: NSObject, LocalProcessTerminalViewDelegate, @unchecked Sendable {
    let sessionId: UUID
    private weak var manager: AgentProcessManager?

    init(sessionId: UUID, manager: AgentProcessManager) {
        self.sessionId = sessionId
        self.manager = manager
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            manager?.handleProcessTerminated(sessionId: sessionId, exitCode: exitCode)
        }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

// MARK: - Errors

enum ProcessManagerError: Error, LocalizedError {
    case cliNotFound(CLIProviderType)
    case concurrencyLimitReached
    case noResumeId

    /// Backward-compatible static for existing code that references `.claudeNotFound`.
    static var claudeNotFound: ProcessManagerError { .cliNotFound(.claude) }

    var errorDescription: String? {
        switch self {
        case .cliNotFound(let provider):
            return "Could not find the '\(provider.binaryName)' CLI binary. Please install \(provider.displayName) or set the path in Preferences."
        case .concurrencyLimitReached:
            return "Maximum number of concurrent agents reached. Stop an existing session or increase the limit in Settings."
        case .noResumeId:
            return "No resume ID available for this session."
        }
    }
}
