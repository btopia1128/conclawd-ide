import Foundation

/// Discovers the path to CLI binaries (claude, codex).
/// Replaces the old ClaudePathResolver with multi-provider support.
final class CLIPathResolver: @unchecked Sendable {

    /// Cached resolved paths keyed by provider type.
    private var cachedPaths: [CLIProviderType: String] = [:]

    /// UserDefaults keys for manual path overrides.
    static let manualClaudePathKey = "claudeBinaryPath"
    static let manualCodexPathKey = "codexBinaryPath"

    /// Backward-compatible alias used by Settings UI.
    static let manualPathKey = manualClaudePathKey

    /// Resolve the path to a CLI binary for the given provider.
    func resolve(for provider: CLIProviderType = .claude) -> String? {
        let manualKey = provider == .claude ? Self.manualClaudePathKey : Self.manualCodexPathKey
        if let manualPath = UserDefaults.standard.string(forKey: manualKey),
           !manualPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: manualPath) {
            return manualPath
        }

        if let cached = cachedPaths[provider] {
            return cached
        }

        let path = findBinaryPath(named: provider.binaryName)
        cachedPaths[provider] = path
        return path
    }

    /// Resolve an arbitrary executable path using the same search strategy as the CLI providers.
    func resolveBinary(named name: String) -> String? {
        findBinaryPath(named: name)
    }

    /// Backward-compatible resolve that defaults to Claude.
    func resolve() -> String? {
        resolve(for: .claude)
    }

    /// Search for the binary in common locations.
    private func findBinaryPath(named name: String) -> String? {
        let fm = FileManager.default

        // 1. Check well-known install locations (Homebrew, npm -g,
        //    node version managers, native installers).
        for dir in Self.commonBinDirectories() {
            let path = dir + "/" + name
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }

        // 2. Try `which <binary>` using the user's shell
        if let path = runWhich(name) {
            return path
        }

        return nil
    }

    // MARK: - Subprocess PATH

    /// Directories where CLI binaries and their runtimes (node etc.) are
    /// commonly installed, covering the major install methods and node
    /// version managers. Only directories that exist are returned.
    static func commonBinDirectories() -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path(percentEncoded: false)

        var dirs = [
            "/usr/local/bin",                  // Homebrew (Intel), npm -g, n
            "/opt/homebrew/bin",               // Homebrew (Apple Silicon)
            home + ".local/bin",               // claude native installer
            home + ".volta/bin",               // Volta
            home + ".asdf/shims",              // asdf
            home + ".local/share/mise/shims",  // mise
            home + ".nodebrew/current/bin",    // nodebrew
            home + ".bun/bin",                 // Bun
        ]

        // fnm keeps a "default" alias under a base directory that varies
        // by install method.
        for fnmBase in [
            home + ".fnm",
            home + ".local/share/fnm",
            home + "Library/Application Support/fnm",
        ] {
            dirs.append(fnmBase + "/aliases/default/bin")
        }

        // nvm has no stable "current" symlink; list installed versions,
        // newest first.
        let nvmDir = home + ".nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmDir) {
            let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            dirs.append(contentsOf: sorted.map { nvmDir + "/" + $0 + "/bin" })
        }

        return dirs.filter { fm.fileExists(atPath: $0) }
    }

    /// PATH from a non-interactive login shell, resolved once. Recovers
    /// entries the user exports in .zprofile/.bash_profile, which GUI apps
    /// launched from Finder/Dock don't inherit. Entries added only in
    /// .zshrc/.bashrc are NOT picked up here — commonBinDirectories()
    /// covers those installations instead.
    private static let loginShellPATH: String? = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "echo $PATH"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty else {
            return nil
        }
        return output
    }()

    /// PATH for launching CLI subprocesses from the GUI app. Puts the CLI's
    /// own directory first so npm shims (`#!/usr/bin/env node`) resolve the
    /// node interpreter installed next to them, then the inherited PATH,
    /// the login-shell PATH, and common install locations.
    static func augmentedPATH(cliPath: String? = nil) -> String {
        var entries: [String] = []
        if let cliPath, !cliPath.isEmpty {
            entries.append((cliPath as NSString).deletingLastPathComponent)
        }
        if let inherited = ProcessInfo.processInfo.environment["PATH"] {
            entries.append(contentsOf: inherited.components(separatedBy: ":"))
        }
        if let loginPath = loginShellPATH {
            entries.append(contentsOf: loginPath.components(separatedBy: ":"))
        }
        entries.append(contentsOf: commonBinDirectories())
        entries.append(contentsOf: ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])

        var seen = Set<String>()
        let deduped = entries.filter { !$0.isEmpty && seen.insert($0).inserted }
        return deduped.joined(separator: ":")
    }

    /// Process environment with the augmented PATH applied.
    static func augmentedEnvironment(cliPath: String? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = augmentedPATH(cliPath: cliPath)
        return env
    }

    /// Run `which <binary>` in the user's default shell.
    private func runWhich(_ name: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "which \(name)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty,
                  FileManager.default.isExecutableFile(atPath: output) else {
                return nil
            }
            return output
        } catch {
            return nil
        }
    }

    /// Clear cached paths (e.g., when user changes settings).
    func clearCache() {
        cachedPaths.removeAll()
    }

    /// Set a manual override path for a provider.
    func setManualPath(_ path: String, for provider: CLIProviderType = .claude) {
        cachedPaths[provider] = path
    }
}

/// Backward-compatible type alias so existing code compiles without changes.
typealias ClaudePathResolver = CLIPathResolver
