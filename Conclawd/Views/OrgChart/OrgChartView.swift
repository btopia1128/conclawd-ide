import SwiftUI

/// Org chart view displayed inline in the center pane.
/// The toolbar controls (Auto Layout, filter, stats) are shown in the tab bar by TerminalTabView.
struct OrgChartView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    var viewModel: OrgChartViewModel
    var filter: OrgChartFilter
    @Binding var showGlobalAgents: Bool
    @State private var showingNewAgent = false
    @State private var showingAICreation = false
    @State private var isAddButtonHovered = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if viewModel.nodes.isEmpty {
                ContentUnavailableView {
                    Label("No Agents", systemImage: "person.3")
                } description: {
                    if filter == .project {
                        Text("No agents in this project. Switch to \"All\" to see all agents.")
                    } else {
                        Text("Create agents to see the organization chart.")
                    }
                }
            } else {
                OrgChartCanvasView(viewModel: viewModel)
            }

            HStack(spacing: 8) {
                if filter == .project {
                    globalAgentsToggle
                }
                addAgentButton
            }
            .padding(16)
        }
        .sheet(isPresented: $showingNewAgent) {
            NewAgentSheet()
        }
        .sheet(isPresented: $showingAICreation) {
            AICreationSheet(kind: .agent)
        }
    }

    // MARK: - Floating Add Button

    private var addAgentButton: some View {
        Menu {
            Button {
                showingAICreation = true
            } label: {
                Label(l10n.createWithAI, systemImage: "sparkles")
            }

            Button {
                showingNewAgent = true
            } label: {
                Label(l10n.createManually, systemImage: "square.and.pencil")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                Text("New Agent")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.accentColor)
            .clipShape(Capsule())
            .shadow(color: .appShadowStrong, radius: 6, y: 3)
            .scaleEffect(isAddButtonHovered ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isAddButtonHovered)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isAddButtonHovered = $0 }
    }

    // MARK: - Global Agents Toggle

    private var globalAgentsToggle: some View {
        Button {
            showGlobalAgents.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showGlobalAgents ? "person.fill" : "person")
                    .font(.system(size: 12))
                Text("Global")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(showGlobalAgents ? .white : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(showGlobalAgents ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            .clipShape(Capsule())
            .shadow(color: .appShadowStrong, radius: 6, y: 3)
        }
        .buttonStyle(.plain)
    }

}
