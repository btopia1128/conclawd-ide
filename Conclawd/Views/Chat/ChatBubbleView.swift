import SwiftUI

/// Renders a single chat message as a bubble.
struct ChatBubbleView: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            assistantBubble
        case .system:
            systemBubble
        }
    }

    // MARK: - User Bubble

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 6) {
                // Attachment chips
                if !message.attachments.isEmpty {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(message.attachments) { attachment in
                            HStack(spacing: 4) {
                                Image(systemName: attachment.isImage ? "photo" : "doc")
                                    .font(.system(size: 9))
                                Text(attachment.fileName)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(4)
                        }
                    }
                    .foregroundStyle(.white)
                }

                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor)
            .cornerRadius(16)
            .cornerRadius(4, corners: .topTrailing)
        }
    }

    // MARK: - Assistant Bubble

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tool uses (shown above text)
            if !message.toolUses.isEmpty {
                VStack(spacing: 4) {
                    ForEach(message.toolUses) { tool in
                        if tool.name == "recall_memory" {
                            RecallMemoryToolCardView(toolUse: tool)
                        } else {
                            ToolUseCardView(toolUse: tool)
                        }
                    }
                }
            }

            // Text content
            if !message.content.isEmpty {
                Text(message.content)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.appBorder, lineWidth: 0.5)
                    )
                    .cornerRadius(16)
                    .cornerRadius(4, corners: .topLeading)
            }

            // Streaming indicator
            if message.isStreaming && message.content.isEmpty && message.toolUses.isEmpty {
                // Handled by parent view's thinkingIndicator
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - System Bubble

    private var systemBubble: some View {
        Text(message.content)
            .font(.system(size: 11))
            .foregroundStyle(Color.appSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
    }
}

// MARK: - Tool Use Card

struct ToolUseCardView: View {
    let toolUse: ChatToolUse
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: toolUse.iconName)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appSecondary)
                        .frame(width: 16)

                    Text(toolUse.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)

                    if !toolUse.inputSummary.isEmpty {
                        Text(toolUse.inputSummary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.appSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    if toolUse.isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.appTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            // Expanded detail
            if isExpanded && !toolUse.input.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(formatJson(toolUse.input))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.appSecondary)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(maxHeight: 120)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.appBorder, lineWidth: 0.5)
        )
        .cornerRadius(8)
    }

    /// Attempts to pretty-print a JSON string, falls back to raw string.
    private func formatJson(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: pretty, encoding: .utf8) else {
            return raw
        }
        return result
    }
}

// MARK: - Corner Radius Helper

private struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: RectCorner

    func path(in rect: CGRect) -> Path {
        let tl = corners.contains(.topLeading) ? radius : 0
        let tr = corners.contains(.topTrailing) ? radius : 0
        let bl = corners.contains(.bottomLeading) ? radius : 0
        let br = corners.contains(.bottomTrailing) ? radius : 0

        var path = Path()
        path.move(to: CGPoint(x: tl, y: 0))
        path.addLine(to: CGPoint(x: rect.width - tr, y: 0))
        path.addArc(tangent1End: CGPoint(x: rect.width, y: 0), tangent2End: CGPoint(x: rect.width, y: tr), radius: tr)
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - br))
        path.addArc(tangent1End: CGPoint(x: rect.width, y: rect.height), tangent2End: CGPoint(x: rect.width - br, y: rect.height), radius: br)
        path.addLine(to: CGPoint(x: bl, y: rect.height))
        path.addArc(tangent1End: CGPoint(x: 0, y: rect.height), tangent2End: CGPoint(x: 0, y: rect.height - bl), radius: bl)
        path.addLine(to: CGPoint(x: 0, y: tl))
        path.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: tl, y: 0), radius: tl)
        path.closeSubpath()
        return path
    }
}

struct RectCorner: OptionSet {
    let rawValue: Int
    static let topLeading = RectCorner(rawValue: 1 << 0)
    static let topTrailing = RectCorner(rawValue: 1 << 1)
    static let bottomLeading = RectCorner(rawValue: 1 << 2)
    static let bottomTrailing = RectCorner(rawValue: 1 << 3)
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: RectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}
