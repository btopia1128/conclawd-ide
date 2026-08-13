import SwiftUI

/// VSCode-style branch selector shown in the top bar.
/// Displays the current branch name and opens a popover to switch branches.
struct BranchSelectorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n

    @State private var showingPopover = false
    @State private var searchText = ""
    @State private var showingNewBranchSheet = false
    @State private var newBranchName = ""
    @State private var showingDirtyWarning = false
    @State private var pendingBranch: String?
    @State private var errorMessage: String?
    @State private var isRefreshing = false

    var body: some View {
        HStack(spacing: 2) {
            branchButton
            reloadButton
        }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                branchPopover
            }
            .alert(l10n.uncommittedChanges, isPresented: $showingDirtyWarning) {
                Button(l10n.cancel, role: .cancel) {
                    pendingBranch = nil
                }
                Button(l10n.switchBranch) {
                    if let branch = pendingBranch {
                        performSwitch(to: branch)
                    }
                }
            }
            .alert(l10n.branchSwitchFailed, isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                if let msg = errorMessage {
                    Text(msg)
                }
            }
            .sheet(isPresented: $showingNewBranchSheet) {
                newBranchSheet
            }
    }

    // MARK: - Branch Button

    private var branchButton: some View {
        Button {
            appState.refreshGitStatus()
            appState.refreshGitBranches()
            showingPopover.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))

                if let status = appState.gitStatus {
                    Text(status.isDetachedHead ? "HEAD" : status.currentBranch)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if status.hasUncommittedChanges {
                        Circle()
                            .fill(.orange)
                            .frame(width: 5, height: 5)
                    }
                } else {
                    Text("–")
                        .font(.system(size: 11))
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Color.appTertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Reload Button

    private var reloadButton: some View {
        Button {
            isRefreshing = true
            appState.refreshGitStatus()
            appState.refreshGitBranches()
            // Brief visual feedback
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isRefreshing = false
            }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                .animation(isRefreshing ? .linear(duration: 0.5) : .default, value: isRefreshing)
        }
        .buttonStyle(.plain)
        .help(l10n.refresh)
    }

    // MARK: - Popover

    private var branchPopover: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(l10n.searchBranches, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            // Branch list
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Local branches
                    let localBranches = filteredBranches.filter { !$0.isRemote }
                    if !localBranches.isEmpty {
                        sectionHeader(l10n.localBranches)
                        ForEach(localBranches) { branch in
                            branchRow(branch)
                        }
                    }

                    // Remote branches (excluding those that match a local branch)
                    let localNames = Set(localBranches.map(\.name))
                    let remoteBranches = filteredBranches.filter { $0.isRemote && !localNames.contains($0.name) }
                    if !remoteBranches.isEmpty {
                        sectionHeader(l10n.remoteBranches)
                        ForEach(remoteBranches) { branch in
                            branchRow(branch)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)

            Divider()

            // Create new branch button
            Button {
                showingPopover = false
                newBranchName = ""
                showingNewBranchSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                    Text(l10n.createNewBranch)
                        .font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 280)
    }

    // MARK: - Branch Row

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func branchRow(_ branch: GitBranch) -> some View {
        Button {
            handleBranchSelection(branch)
        } label: {
            HStack(spacing: 6) {
                if branch.isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.accentColor)
                        .frame(width: 14)
                } else {
                    Color.clear.frame(width: 14)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(branch.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let message = branch.lastCommitMessage {
                        Text(message)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if branch.isRemote, let remote = branch.remoteName {
                    Text(remote)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.fill.secondary, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(branch.isCurrent)
    }

    // MARK: - New Branch Sheet

    private var newBranchSheet: some View {
        VStack(spacing: 16) {
            Text(l10n.createNewBranch)
                .font(.headline)

            TextField(l10n.newBranchName, text: $newBranchName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button(l10n.cancel) {
                    showingNewBranchSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(l10n.create) {
                    showingNewBranchSheet = false
                    performCreateBranch()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newBranchName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    // MARK: - Logic

    private var filteredBranches: [GitBranch] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return appState.gitBranches }
        return appState.gitBranches.filter { $0.name.lowercased().contains(query) }
    }

    private func handleBranchSelection(_ branch: GitBranch) {
        showingPopover = false
        searchText = ""

        if branch.isRemote {
            // Remote branch: check out as local tracking branch
            let localName = branch.name
            Task {
                do {
                    try await appState.checkoutRemoteGitBranch(
                        "\(branch.remoteName ?? "origin")/\(branch.name)",
                        localName: localName
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }

        // Check for uncommitted changes
        if appState.gitStatus?.hasUncommittedChanges == true {
            pendingBranch = branch.name
            showingDirtyWarning = true
            return
        }

        performSwitch(to: branch.name)
    }

    private func performSwitch(to branchName: String) {
        pendingBranch = nil
        Task {
            do {
                try await appState.switchGitBranch(to: branchName)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performCreateBranch() {
        let name = newBranchName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            do {
                try await appState.createGitBranch(name: name)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
