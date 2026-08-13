import SwiftUI
import UniformTypeIdentifiers

/// Chat UI view for a single session — replaces the terminal view.
struct ChatView: View {
    let chatManager: ChatSessionManager
    @State private var inputText = ""
    @State private var attachments: [ChatAttachment] = []
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            inputBar
        }
        .themedBackground(Color.appSurface)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(chatManager.messages) { message in
                        ChatBubbleView(message: message)
                            .id(message.id)
                    }

                    if chatManager.isProcessing,
                       let last = chatManager.messages.last,
                       last.role == .assistant, last.content.isEmpty, last.toolUses.isEmpty {
                        thinkingIndicator
                            .id("thinking")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .onChange(of: chatManager.messages.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if let lastId = chatManager.messages.last?.id {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    } else if chatManager.isProcessing {
                        proxy.scrollTo("thinking", anchor: .bottom)
                    }
                }
            }
            .onChange(of: chatManager.messages.last?.content) {
                if let lastId = chatManager.messages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }

    private var thinkingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("考えています...")
                .font(.system(size: 12))
                .foregroundStyle(Color.appSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Attachment preview
            if !attachments.isEmpty {
                attachmentPreviewBar
                Divider()
            }

            HStack(alignment: .bottom, spacing: 8) {
                // Attachment buttons
                HStack(spacing: 2) {
                    Button { pickImage() } label: {
                        Image(systemName: "photo")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.appSecondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("画像を添付")

                    Button { pickFile() } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.appSecondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("ファイルを添付")
                }

                TextField("メッセージを入力...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...8)
                    .focused($isInputFocused)
                    .onSubmit {
                        if MainActor.assumeIsolated({ NSApp.currentEvent?.modifierFlags.contains(.shift) == true }) {
                            return // Shift+Enter: newline
                        }
                        send()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.appBorder, lineWidth: 1)
                    )

                Button {
                    send()
                } label: {
                    Image(systemName: chatManager.isProcessing ? "stop.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(
                            canSend || chatManager.isProcessing
                                ? Color.accentColor
                                : Color.appIconMuted
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !chatManager.isProcessing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .themedBackground(Color.appSurface)
        .onAppear { isInputFocused = true }
    }

    // MARK: - Attachment Preview

    private var attachmentPreviewBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    attachmentChip(attachment)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func attachmentChip(_ attachment: ChatAttachment) -> some View {
        HStack(spacing: 4) {
            Image(systemName: attachment.isImage ? "photo" : "doc")
                .font(.system(size: 10))
                .foregroundStyle(Color.appSecondary)
            Text(attachment.fileName)
                .font(.system(size: 11))
                .lineLimit(1)
            Button {
                attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.appTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.appBorder, lineWidth: 0.5)
        )
    }

    // MARK: - File Pickers

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ChatAttachment.imageContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK {
                for url in panel.urls {
                    attachments.append(ChatAttachment(url: url, type: .image))
                }
            }
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK {
                for url in panel.urls {
                    let isImage = ChatAttachment.imageContentTypes.contains(where: { utType in
                        UTType(filenameExtension: url.pathExtension)?.conforms(to: utType) == true
                    })
                    attachments.append(ChatAttachment(url: url, type: isImage ? .image : .file))
                }
            }
        }
    }

    // MARK: - Send

    private var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !attachments.isEmpty) && !chatManager.isProcessing
    }

    private func send() {
        if chatManager.isProcessing {
            chatManager.cancel()
            return
        }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let currentAttachments = attachments
        inputText = ""
        attachments = []
        chatManager.sendMessage(text, attachments: currentAttachments)
    }
}
