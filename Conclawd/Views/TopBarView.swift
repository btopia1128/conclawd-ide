import SwiftUI

/// Full-width top bar at traffic-light height.
/// Project selector is centered; panel toggles and settings on the right.
struct TopBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    @Binding var showSidebar: Bool
    @Binding var showInspector: Bool

    var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        #endif
        ZStack {
            // Center: project selector + branch selector + git actions
            HStack(spacing: 6) {
                projectMenu

                if appState.isGitRepository {
                    BranchSelectorView()
                    GitActionsView()
                }
            }

            // Right: panel toggles + settings
            HStack(spacing: 12) {
                Spacer()

                Button {
                    withAnimation { showSidebar.toggle() }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 11))
                        .foregroundStyle(showSidebar ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .help(showSidebar ? l10n.hideSidebar : l10n.showSidebar)

                Button {
                    withAnimation { appState.toggleSplitView() }
                } label: {
                    Image(systemName: appState.secondaryPane == nil
                          ? "rectangle.split.2x1"
                          : "rectangle.split.2x1.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(appState.secondaryPane == nil ? .secondary : .primary)
                }
                .buttonStyle(.plain)
                .help(appState.secondaryPane == nil ? "Split editor" : "Close split")

                Button {
                    withAnimation { showInspector.toggle() }
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 11))
                        .foregroundStyle(showInspector ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .help(showInspector ? l10n.hideInspector : l10n.showInspector)

                Button {
                    withAnimation {
                        if appState.centerPane == .settings {
                            appState.centerPane = .terminal
                        } else {
                            appState.settingsTabOpen = true
                            appState.centerPane = .settings
                        }
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .help(l10n.settings)
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 32)
        .themedBackground(Color.appSurface)
    }

    private var projectMenu: some View {
        Menu {
            // "Home" option
            Button {
                appState.selectHome()
            } label: {
                HStack {
                    if appState.projectSelection == .home {
                        Image(systemName: "checkmark")
                    }
                    Text(l10n.home)
                }
            }
            .disabled(appState.projectSelection == .home)

            if !appState.projects.isEmpty {
                Divider()

                // "All Projects" option
                Button {
                    appState.selectAll()
                } label: {
                    HStack {
                        if appState.projectSelection == .all {
                            Image(systemName: "checkmark")
                        }
                        Text(l10n.allProjects)
                    }
                }
                .disabled(appState.projectSelection == .all)

                Divider()

                ForEach(appState.projects) { project in
                    Button {
                        appState.loadProject(project)
                    } label: {
                        HStack {
                            if appState.selectedProject?.id == project.id {
                                Image(systemName: "checkmark")
                            }
                            Text(project.name)
                        }
                    }
                    .disabled(appState.selectedProject?.id == project.id)
                }
            }

            Divider()

            Button {
                openProjectViaPanel()
            } label: {
                Label(l10n.openProject, systemImage: "folder.badge.plus")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appState.projectSelection.iconName)
                    .font(.system(size: 11))

                Text(appState.projectSelection.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.appTertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(.fill.secondary, in: Capsule())
    }

    private func openProjectViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = l10n.selectProjectDirectory

        if panel.runModal() == .OK, let url = panel.url {
            appState.openProject(directory: url)
        }
    }
}
