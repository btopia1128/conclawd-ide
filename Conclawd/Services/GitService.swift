import Foundation

/// Provides git operations by shelling out to the `git` CLI.
final class GitService: Sendable {

    // MARK: - Repository Detection

    /// Returns `true` if the directory is inside a git work tree.
    func isGitRepository(at path: URL) -> Bool {
        let (output, exitCode) = run(["rev-parse", "--is-inside-work-tree"], at: path)
        return exitCode == 0 && output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    // MARK: - Status

    /// Returns the current git status, or `nil` if not a git repository.
    func getStatus(at path: URL) async -> GitStatus? {
        guard isGitRepository(at: path) else { return nil }

        // Current branch name
        let (branchOutput, _) = run(["rev-parse", "--abbrev-ref", "HEAD"], at: path)
        let branch = branchOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDetached = branch == "HEAD"

        // Uncommitted changes
        let (statusOutput, _) = run(["status", "--porcelain"], at: path)
        let hasChanges = !statusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Ahead / behind counts (may fail if no upstream is set)
        var ahead = 0
        var behind = 0
        let (aheadOutput, aheadExit) = run(["rev-list", "--count", "@{u}..HEAD"], at: path)
        if aheadExit == 0, let n = Int(aheadOutput.trimmingCharacters(in: .whitespacesAndNewlines)) {
            ahead = n
        }
        let (behindOutput, behindExit) = run(["rev-list", "--count", "HEAD..@{u}"], at: path)
        if behindExit == 0, let n = Int(behindOutput.trimmingCharacters(in: .whitespacesAndNewlines)) {
            behind = n
        }

        return GitStatus(
            currentBranch: branch,
            hasUncommittedChanges: hasChanges,
            ahead: ahead,
            behind: behind,
            isDetachedHead: isDetached
        )
    }

    // MARK: - Branches

    /// Lists all local and remote branches.
    func listBranches(at path: URL) async -> [GitBranch] {
        let format = "%(refname)\t%(refname:short)\t%(objectname:short)\t%(committerdate:iso-strict)\t%(subject)\t%(HEAD)"
        let (output, exitCode) = run(["branch", "--all", "--sort=-committerdate", "--format=\(format)"], at: path)
        guard exitCode == 0 else { return [] }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()

        var branches: [GitBranch] = []
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 6 else { continue }

            let fullRef = parts[0]
            let shortName = parts[1]
            let dateString = parts[3]
            let subject = parts[4]
            let headMarker = parts[5].trimmingCharacters(in: .whitespaces)

            // Skip HEAD pointer (refs/remotes/origin/HEAD)
            if fullRef.hasSuffix("/HEAD") { continue }

            let isRemote = fullRef.hasPrefix("refs/remotes/")
            let isCurrent = headMarker == "*"

            // Extract remote name (e.g. "origin" from "refs/remotes/origin/main")
            var remoteName: String?
            var displayName = shortName
            if isRemote {
                let components = fullRef.replacingOccurrences(of: "refs/remotes/", with: "")
                    .components(separatedBy: "/")
                remoteName = components.first
                // Remove "origin/" prefix from display name
                if let remote = remoteName, displayName.hasPrefix("\(remote)/") {
                    displayName = String(displayName.dropFirst(remote.count + 1))
                }
            }

            let date = dateFormatter.date(from: dateString) ?? fallbackFormatter.date(from: dateString)

            branches.append(GitBranch(
                fullRef: fullRef,
                name: displayName,
                isRemote: isRemote,
                isCurrent: isCurrent,
                remoteName: remoteName,
                lastCommitDate: date,
                lastCommitMessage: subject.isEmpty ? nil : subject
            ))
        }

        return branches
    }

    // MARK: - Branch Operations

    /// Switches to the specified local branch.
    func switchBranch(to branch: String, at path: URL) async throws {
        let (output, exitCode) = run(["switch", branch], at: path)
        guard exitCode == 0 else {
            throw GitError.switchFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Creates a new branch from the current HEAD and switches to it.
    func createBranch(name: String, at path: URL) async throws {
        let (output, exitCode) = run(["switch", "-c", name], at: path)
        guard exitCode == 0 else {
            throw GitError.createFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Checks out a remote branch as a new local tracking branch.
    func checkoutRemoteBranch(_ remoteBranch: String, localName: String, at path: URL) async throws {
        let (output, exitCode) = run(["switch", "-c", localName, "--track", remoteBranch], at: path)
        guard exitCode == 0 else {
            throw GitError.switchFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Fetches all remotes.
    func fetch(at path: URL) async throws {
        let (output, exitCode) = run(["fetch", "--all", "--prune"], at: path)
        guard exitCode == 0 else {
            throw GitError.fetchFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Changed Files

    /// Returns the list of changed files from `git status --porcelain`.
    func getChangedFiles(at path: URL) -> [GitChangedFile] {
        let (output, exitCode) = run(["status", "--porcelain"], at: path)
        guard exitCode == 0 else { return [] }
        return output.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { line in
                let code = String(line.prefix(2)).trimmingCharacters(in: .whitespaces)
                let filePath = String(line.dropFirst(3))
                return GitChangedFile(statusCode: code.isEmpty ? "??" : code, path: filePath)
            }
    }

    /// Returns a diff summary suitable for AI commit message generation.
    func getDiffSummary(at path: URL, maxChars: Int = 8000) -> String {
        let (stat, _) = run(["diff", "--stat", "HEAD"], at: path)
        let (untracked, _) = run(["ls-files", "--others", "--exclude-standard"], at: path)
        let (diff, _) = run(["diff", "HEAD"], at: path)

        var result = "=== Changed files ===\n\(stat)\n"
        let untrackedTrimmed = untracked.trimmingCharacters(in: .whitespacesAndNewlines)
        if !untrackedTrimmed.isEmpty {
            result += "\n=== Untracked files ===\n\(untrackedTrimmed)\n"
        }
        result += "\n=== Diff ===\n"
        if diff.count > maxChars {
            result += String(diff.prefix(maxChars)) + "\n... (truncated)"
        } else {
            result += diff
        }
        return result
    }

    // MARK: - Commit / Push / Pull

    /// Stages all changes and commits with the given message.
    func commitAll(message: String, at path: URL) async throws {
        let (addOutput, addExit) = run(["add", "-A"], at: path)
        guard addExit == 0 else {
            throw GitError.stageFailed(addOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let (commitOutput, commitExit) = run(["commit", "-m", message], at: path)
        guard commitExit == 0 else {
            throw GitError.commitFailed(commitOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Pushes the current branch to origin. Auto-sets upstream if needed.
    func push(at path: URL, branch: String? = nil) async throws {
        let (output, exitCode) = run(["push"], at: path)
        if exitCode != 0 {
            let msg = output.trimmingCharacters(in: .whitespacesAndNewlines)
            // Auto set-upstream on first push
            if msg.contains("no upstream") || msg.contains("has no upstream"), let branch = branch {
                let (retryOutput, retryExit) = run(["push", "--set-upstream", "origin", branch], at: path)
                guard retryExit == 0 else {
                    throw GitError.pushFailed(retryOutput.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } else {
                throw GitError.pushFailed(msg)
            }
        }
    }

    /// Pulls from the remote for the current branch.
    func pull(at path: URL) async throws {
        let (output, exitCode) = run(["pull"], at: path)
        guard exitCode == 0 else {
            throw GitError.pullFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Errors

    enum GitError: LocalizedError {
        case switchFailed(String)
        case createFailed(String)
        case fetchFailed(String)
        case stageFailed(String)
        case commitFailed(String)
        case pushFailed(String)
        case pullFailed(String)

        var errorDescription: String? {
            switch self {
            case .switchFailed(let msg): return "Branch switch failed: \(msg)"
            case .createFailed(let msg): return "Branch creation failed: \(msg)"
            case .fetchFailed(let msg): return "Fetch failed: \(msg)"
            case .stageFailed(let msg): return "Staging failed: \(msg)"
            case .commitFailed(let msg): return "Commit failed: \(msg)"
            case .pushFailed(let msg): return "Push failed: \(msg)"
            case .pullFailed(let msg): return "Pull failed: \(msg)"
            }
        }
    }

    // MARK: - Private

    /// User's full PATH resolved from their login shell (includes nvm, nodebrew, homebrew, etc.).
    /// Cached as a static to avoid running a shell process on every git command.
    private static let resolvedPath: String = {
        let process = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "echo $PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
    }()

    /// Runs a git command synchronously and returns (stdout+stderr, exit code).
    private func run(_ arguments: [String], at workingDirectory: URL) -> (String, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        // Use the user's full PATH so pre-commit hooks can find node, etc.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.resolvedPath
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (error.localizedDescription, -1)
        }

        // Read before waitUntilExit to avoid pipe buffer deadlock.
        // If output exceeds ~64KB, the process blocks on write until the pipe is drained.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, process.terminationStatus)
    }
}
