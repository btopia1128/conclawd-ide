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

        let path = findBinaryPath(for: provider)
        cachedPaths[provider] = path
        return path
    }

    /// Backward-compatible resolve that defaults to Claude.
    func resolve() -> String? {
        resolve(for: .claude)
    }

    /// Search for the binary in common locations.
    private func findBinaryPath(for provider: CLIProviderType) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let name = provider.binaryName

        // 1. Check common paths
        let commonPaths = [
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
        ]
        for path in commonPaths {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }

        // 2. Try `which <binary>` using the user's shell
        if let path = runWhich(name) {
            return path
        }

        // 3. Check nodebrew current
        let nodebrewPath = home + ".nodebrew/current/bin/\(name)"
        if fm.isExecutableFile(atPath: nodebrewPath) {
            return nodebrewPath
        }

        // 4. Check nvm versions (newest first)
        let nvmDir = home + ".nvm/versions/node"
        if fm.fileExists(atPath: nvmDir),
           let versions = try? fm.contentsOfDirectory(atPath: nvmDir) {
            for version in versions.sorted().reversed() {
                let path = nvmDir + "/\(version)/bin/\(name)"
                if fm.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }

        return nil
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
