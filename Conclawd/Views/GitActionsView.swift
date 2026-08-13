import AppKit
import SwiftUI

/// Commit, pull, and push buttons shown next to the branch selector in the top bar.
struct GitActionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n

    @State private var showingCommitPopover = false
    @State private var commitMessage = ""
    @State private var isGeneratingMessage = false
    @State private var isPushing = false
    @State private var isPulling = false
    @State private var showingErrorPopover = false

    var body: some View {
        HStack(spacing: 2) {
            commitButton
            pullButton
            pushButton
            if appState.lastGitError != nil {
                gitErrorButton
            }
        }
        .popover(isPresented: $showingCommitPopover, arrowEdge: .bottom) {
            commitPopover
        }
    }

    // MARK: - Commit Button

    private var commitButton: some View {
        Button {
            appState.refreshGitChangedFiles()
            commitMessage = ""
            showingCommitPopover = true
        } label: {
            Text(l10n.commit)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(
                    appState.gitStatus?.hasUncommittedChanges == true
                        ? Color.orange : .secondary
                )
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(appState.gitStatus?.hasUncommittedChanges != true)
    }

    // MARK: - Pull Button

    private var pullButton: some View {
        Button {
            performPull()
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 9))
                if let behind = appState.gitStatus?.behind, behind > 0 {
                    Text("\(behind)")
                        .font(.system(size: 9))
                }
                Text(l10n.pull)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(
                isPulling ? .tertiary :
                    (appState.gitStatus?.behind ?? 0) > 0 ? .primary : .secondary
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPulling || appState.isGitOperationInProgress)
    }

    // MARK: - Push Button

    private var pushButton: some View {
        Button {
            performPush()
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 9))
                if let ahead = appState.gitStatus?.ahead, ahead > 0 {
                    Text("\(ahead)")
                        .font(.system(size: 9))
                }
                Text(l10n.push)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(
                isPushing ? .tertiary :
                    (appState.gitStatus?.ahead ?? 0) > 0 ? .primary : .secondary
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPushing || appState.isGitOperationInProgress)
    }

    // MARK: - Git Error Button

    private var gitErrorButton: some View {
        Button {
            showingErrorPopover = true
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingErrorPopover, arrowEdge: .bottom) {
            gitErrorPopover
        }
    }

    private var gitErrorPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 12))
                Text(l10n.gitOperationFailed)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            if let error = appState.lastGitError {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Button {
                    if let error = appState.lastGitError {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(error, forType: .string)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                        Text(l10n.copyError)
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    appState.lastGitError = nil
                    showingErrorPopover = false
                } label: {
                    Text(l10n.dismissError)
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(width: 320)
    }

    // MARK: - Commit Popover

    private var commitPopover: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(l10n.commitChanges)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(appState.gitChangedFiles.count) \(l10n.filesChanged)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            // Changed files list
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(appState.gitChangedFiles) { file in
                        HStack(spacing: 6) {
                            Text(file.statusCode)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(colorForStatus(file.statusCode))
                                .frame(width: 20)
                            Text(file.path)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(maxHeight: 150)

            Divider()

            // Message input + actions
            VStack(spacing: 6) {
                TextField(l10n.commitMessagePlaceholder, text: $commitMessage, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(3...6)
                    .padding(8)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))

                HStack {
                    // AI generate button
                    Button {
                        generateMessage()
                    } label: {
                        HStack(spacing: 3) {
                            if isGeneratingMessage {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10))
                            }
                            Text(l10n.generateMessage)
                                .font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isGeneratingMessage)

                    Spacer()

                    // Commit button
                    Button(l10n.commit) {
                        performCommit()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(10)
        }
        .frame(width: 320)
    }

    // MARK: - Logic

    private func performCommit() {
        let message = commitMessage.trimmingCharacters(in: .whitespaces)
        guard !message.isEmpty else { return }
        showingCommitPopover = false
        Task {
            do {
                try await appState.gitCommitAll(message: message)
            } catch {
                appState.lastGitError = error.localizedDescription
            }
        }
    }

    private func performPush() {
        isPushing = true
        Task {
            do {
                try await appState.gitPush()
            } catch {
                appState.lastGitError = error.localizedDescription
            }
            isPushing = false
        }
    }

    private func performPull() {
        isPulling = true
        Task {
            do {
                try await appState.gitPull()
            } catch {
                appState.lastGitError = error.localizedDescription
            }
            isPulling = false
        }
    }

    private func generateMessage() {
        isGeneratingMessage = true
        Task {
            do {
                commitMessage = try await appState.generateCommitMessage()
            } catch {
                appState.lastGitError = error.localizedDescription
            }
            isGeneratingMessage = false
        }
    }

    private func colorForStatus(_ code: String) -> Color {
        switch code {
        case "M": return .orange
        case "A", "??": return .green
        case "D": return .red
        case "R": return .blue
        default: return .secondary
        }
    }
}
