import SwiftUI

/// Displays the memory section in the agent inspector.
struct MemoryCardView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n
    let agent: Agent
    @State private var memories: [AgentMemory] = []
    @State private var editingMemory: AgentMemory?
    @State private var isExpanded = false
    @State private var showSettings = false

    private let initialDisplayLimit = 5

    /// Use editingAgent for live reactivity, falling back to the passed-in agent.
    private var editAgent: Agent { appState.editingAgent ?? agent }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 6) {
                Text(l10n.memory)
                    .textCase(.uppercase)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.appSecondary)

                if !memories.isEmpty {
                    Text("(\(memories.count))")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appTertiary)
                }

                Spacer()

                // Settings gear
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSettings.toggle()
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10))
                        .foregroundStyle(showSettings ? Color.accentColor : Color.appSecondary)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                // ON/OFF toggle
                Toggle("", isOn: Binding(
                    get: { appState.editingAgent?.memoryEnabled ?? true },
                    set: { appState.editingAgent?.memoryEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            // Memory list
            if !editAgent.memoryEnabled {
                Text(l10n.memoryDisabledForAgent)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appTertiary)
            } else if memories.isEmpty {
                Text(l10n.noMemoriesYet)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appTertiary)
            } else {
                let visibleMemories = isExpanded ? memories : Array(memories.prefix(initialDisplayLimit))
                VStack(spacing: 4) {
                    ForEach(visibleMemories) { memory in
                        memoryRow(memory)
                    }

                    if memories.count > initialDisplayLimit {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            Text(isExpanded ? l10n.showLessMemories : "\(l10n.showMoreMemories) (\(memories.count - initialDisplayLimit))")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                        .pointingHandCursor()
                    }
                }
            }

            // Inline settings (collapsed by default)
            if showSettings {
                settingsSection
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary)
        .cornerRadius(8)
        .onAppear { refreshMemories() }
        .onChange(of: agent.stableIdentity) {
            isExpanded = false
            refreshMemories()
        }
        .sheet(item: $editingMemory) { memory in
            MemoryEditSheet(memory: memory, agent: agent) {
                refreshMemories()
            }
        }
    }

    // MARK: - Inline Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            // Storage picker (only for project-scope agents)
            if editAgent.scope == .project {
                HStack {
                    Text(l10n.memoryStorage)
                        .font(.system(size: 11))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { appState.editingAgent?.memoryStorage ?? .shared },
                        set: { appState.editingAgent?.memoryStorage = $0 }
                    )) {
                        ForEach(MemoryStorage.allCases, id: \.self) { storage in
                            Text(storage.displayName).tag(storage)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 100)
                }
            }

            // Ownership picker
            HStack {
                Text("Ownership")
                    .font(.system(size: 11))
                Spacer()
                Picker("", selection: Binding(
                    get: { appState.editingAgent?.memoryOwnership ?? .agent },
                    set: { appState.editingAgent?.memoryOwnership = $0 }
                )) {
                    ForEach(MemoryOwnership.allCases, id: \.self) { ownership in
                        Text(ownership.displayName).tag(ownership)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 100)
            }

            // Inject limit
            HStack {
                Text("Inject limit")
                    .font(.system(size: 11))
                Spacer()
                TextField("", value: Binding(
                    get: { appState.editingAgent?.effectiveMemoryLimit ?? 20 },
                    set: {
                        let clamped = max(1, min(100, $0))
                        appState.editingAgent?.memoryLimit = clamped == 20 ? nil : clamped
                    }
                ), format: .number)
                .font(.system(size: 11))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 40)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            }

            Divider()

            // Layer toggles
            Text("Layers")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.appSecondary)
                .textCase(.uppercase)

            layerToggle("Extraction", description: "LLM-based memory extraction",
                isOn: Binding(
                    get: { appState.editingAgent?.memoryExtractionEnabled ?? true },
                    set: { appState.editingAgent?.memoryExtractionEnabled = $0 }
                ))
            layerToggle("DB Sync", description: "FTS5 full-text search",
                isOn: Binding(
                    get: { appState.editingAgent?.memoryDbSyncEnabled ?? true },
                    set: { appState.editingAgent?.memoryDbSyncEnabled = $0 }
                ))
            layerToggle("Embedding", description: "Vector semantic search",
                isOn: Binding(
                    get: { appState.editingAgent?.memoryEmbeddingEnabled ?? true },
                    set: { appState.editingAgent?.memoryEmbeddingEnabled = $0 }
                ))
        }
    }

    // MARK: - Memory Row

    private func memoryRow(_ memory: AgentMemory) -> some View {
        HStack(spacing: 6) {
            // Pin button
            Button {
                togglePin(memory)
            } label: {
                Image(systemName: memory.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 9))
                    .foregroundStyle(memory.pinned ? Color.accentColor : Color.appTertiary)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(memory.type.displayName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(memoryTypeColor(memory.type))
                        .textCase(.uppercase)

                    if editAgent.scope == .project {
                        Text(memory.storage == .shared ? "Shared" : "Private")
                            .font(.system(size: 8, weight: .medium))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(memory.storage == .shared ? .green.opacity(0.15) : .orange.opacity(0.15))
                            .foregroundStyle(memory.storage == .shared ? .green : .orange)
                            .cornerRadius(2)
                    }
                }

                Text(memory.description)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            Text(formatDate(memory.updatedAt))
                .font(.system(size: 9))
                .foregroundStyle(Color.appTertiary)

            Button {
                withAnimation {
                    appState.deleteMemory(memory, for: agent)
                    refreshMemories()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.appSecondary)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.fill.quaternary)
        .cornerRadius(5)
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .pointingHandCursor()
        .onTapGesture {
            editingMemory = memory
        }
    }

    // MARK: - Helpers

    private func refreshMemories() {
        let loaded = appState.loadMemories(for: agent)
        memories = loaded.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func togglePin(_ memory: AgentMemory) {
        var updated = memory
        updated.pinned.toggle()
        appState.updateMemory(updated, for: agent)
        refreshMemories()
    }

    private func layerToggle(_ label: String, description: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11))
                Text(description)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.appTertiary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    private func memoryTypeColor(_ type: AgentMemoryType) -> Color {
        switch type {
        case .feedback: return .orange
        case .user: return .blue
        case .project: return .purple
        case .reference: return .cyan
        case .learned: return .green
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: date)
    }
}
