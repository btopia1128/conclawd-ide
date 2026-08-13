import SwiftUI

/// Sheet for editing a single memory entry.
struct MemoryEditSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.l10n) private var l10n

    @State private var name: String
    @State private var description: String
    @State private var type: AgentMemoryType
    @State private var content: String

    let memory: AgentMemory
    let agent: Agent
    let onSave: () -> Void

    init(memory: AgentMemory, agent: Agent, onSave: @escaping () -> Void) {
        self.memory = memory
        self.agent = agent
        self.onSave = onSave
        _name = State(initialValue: memory.name)
        _description = State(initialValue: memory.description)
        _type = State(initialValue: memory.type)
        _content = State(initialValue: memory.content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text(l10n.editMemory)
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.appSecondary)
                }
                .buttonStyle(.plain)
            }

            // Fields
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n.name)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appSecondary)
                    TextField(l10n.memoryName, text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(l10n.type)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.appSecondary)
                        Picker("", selection: $type) {
                            ForEach(AgentMemoryType.allCases, id: \.self) { t in
                                Text(t.displayName).tag(t)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n.description)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appSecondary)
                    TextField(l10n.oneLineDescription, text: $description)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n.content)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appSecondary)
                    TextEditor(text: $content)
                        .font(.system(size: 11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.fill.quinary)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.separator, lineWidth: 1)
                        )
                        .frame(minHeight: 120)
                }
            }

            // Actions
            HStack {
                Spacer()
                Button(l10n.cancel) {
                    dismiss()
                }
                .controlSize(.small)

                Button(l10n.save) {
                    save()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || content.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 520)
    }

    private func save() {
        var updated = memory
        updated.name = name
        updated.description = description
        updated.type = type
        updated.content = content
        updated.updatedAt = Date()
        appState.updateMemory(updated, for: agent)
        onSave()
        dismiss()
    }
}
