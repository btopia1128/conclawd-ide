import SwiftUI

/// Project selector dropdown in the sidebar titlebar area.
struct ProjectSelectorView: View {
    @Environment(AppState.self) private var appState
    @Binding var showSidebar: Bool

    var body: some View {
        HStack(spacing: 6) {
            projectMenu
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                withAnimation { showSidebar = false }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appSecondary)
            }
            .buttonStyle(.plain)
            .help("Hide Sidebar")
        }
        .padding(.horizontal, 12)
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
                    Text("Home")
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
                        Text("All Projects")
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
                Label("Open Project...", systemImage: "folder.badge.plus")
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
    }

    private func openProjectViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a project directory"

        if panel.runModal() == .OK, let url = panel.url {
            appState.openProject(directory: url)
        }
    }
}
