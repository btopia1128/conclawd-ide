import SwiftUI

/// Center pane editor for the selected agent's system prompt.
struct AgentEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.l10n) private var l10n

    var body: some View {
        if appState.editingAgentContent != nil {
            // ⌘S is owned by File > Save (AppState.saveFromMenu).
            VStack(spacing: 0) {
                editor
                bottomBar
            }
        } else {
            emptyState
        }
    }

    // MARK: - Editor

    private var editor: some View {
        @Bindable var state = appState

        return SyntaxHighlightTextView(
            text: Binding(
                get: { state.editingAgentContent ?? "" },
                set: { state.editingAgentContent = $0; state.agentEditorHasChanges = true }
            ),
            language: "markdown",
            showLineNumbers: state.editorShowLineNumbers,
            wordWrap: state.editorWordWrap,
            placeholder: l10n.agentPromptPlaceholder
        )
        .filePathDrop(text: Binding(
            get: { state.editingAgentContent ?? "" },
            set: { state.editingAgentContent = $0; state.agentEditorHasChanges = true }
        ))
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if let agent = appState.selectedAgent {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(agent.color.swiftUIColor)
                    .frame(width: 3, height: 16)

                Text(agent.name)
                    .font(.system(size: 12, weight: .medium))

                if let filePath = agent.filePath {
                    Text(filePath.path(percentEncoded: false))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.appTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer()

            Button(l10n.revert) {
                appState.revertAgentEditor()
            }
            .controlSize(.small)
            .disabled(!appState.agentEditorHasChanges)
            .pointingHandCursor()

            Button(l10n.save) {
                appState.saveAgentEditor()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(!appState.agentEditorHasChanges)
            .pointingHandCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .themedBackground(Color.appSurface)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(Color.appIconMuted)
            Text(l10n.noAgentSelected)
                .font(.headline)
                .foregroundStyle(Color.appMuted)
            Text(l10n.selectAgentToEdit)
                .font(.subheadline)
                .foregroundStyle(Color.appSubtle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedBackground(Color.appSurface)
    }
}
