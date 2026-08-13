import Foundation
import UniformTypeIdentifiers

/// A single message in a chat session.
struct ChatMessage: Identifiable {
    let id: UUID
    var role: ChatMessageRole
    var content: String
    let timestamp: Date
    var toolUses: [ChatToolUse]
    var attachments: [ChatAttachment]
    var isStreaming: Bool

    init(role: ChatMessageRole, content: String = "", toolUses: [ChatToolUse] = [], attachments: [ChatAttachment] = [], isStreaming: Bool = false) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.toolUses = toolUses
        self.attachments = attachments
        self.isStreaming = isStreaming
    }
}

/// An attachment (image or file) associated with a chat message.
struct ChatAttachment: Identifiable {
    let id: UUID
    let url: URL
    let type: AttachmentType

    enum AttachmentType {
        case image
        case file
    }

    init(url: URL, type: AttachmentType) {
        self.id = UUID()
        self.url = url
        self.type = type
    }

    var fileName: String { url.lastPathComponent }
    var isImage: Bool { type == .image }

    /// Image-compatible UTTypes for the file picker.
    static let imageContentTypes: [UTType] = [.image, .png, .jpeg, .gif, .webP, .svg]
}

enum ChatMessageRole: String {
    case user
    case assistant
    case system
}

/// Represents a tool use within an assistant message.
struct ChatToolUse: Identifiable {
    let id: String
    let name: String
    var input: String
    var isComplete: Bool

    init(id: String, name: String, input: String = "", isComplete: Bool = false) {
        self.id = id
        self.name = name
        self.input = input
        self.isComplete = isComplete
    }

    /// User-friendly icon for the tool.
    var iconName: String {
        switch name {
        case "Read": return "doc.text"
        case "Edit": return "pencil"
        case "Write": return "doc.badge.plus"
        case "Bash": return "terminal"
        case "Grep": return "magnifyingglass"
        case "Glob": return "folder.badge.magnifyingglass"
        case "WebSearch": return "globe"
        case "WebFetch": return "arrow.down.doc"
        case "Agent": return "person.2"
        case "recall_memory": return "brain.head.profile"
        default: return "wrench"
        }
    }

    /// User-friendly label for the tool.
    var displayName: String {
        switch name {
        case "Read": return "ファイルを読む"
        case "Edit": return "ファイルを編集"
        case "Write": return "ファイルを作成"
        case "Bash": return "コマンドを実行"
        case "Grep": return "コードを検索"
        case "Glob": return "ファイルを検索"
        case "WebSearch": return "Web検索"
        case "WebFetch": return "Webページ取得"
        case "Agent": return "サブエージェント"
        case "recall_memory": return "メモリ検索"
        default: return name
        }
    }

    /// Summary text extracted from the tool input JSON.
    var inputSummary: String {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }

        switch name {
        case "Read":
            if let path = json["file_path"] as? String {
                return URL(fileURLWithPath: path).lastPathComponent
            }
        case "Edit":
            if let path = json["file_path"] as? String {
                return URL(fileURLWithPath: path).lastPathComponent
            }
        case "Write":
            if let path = json["file_path"] as? String {
                return URL(fileURLWithPath: path).lastPathComponent
            }
        case "Bash":
            if let cmd = json["command"] as? String {
                let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
                return String(trimmed.prefix(80))
            }
        case "Grep":
            return json["pattern"] as? String ?? ""
        case "Glob":
            return json["pattern"] as? String ?? ""
        case "recall_memory":
            return json["query"] as? String ?? ""
        default:
            break
        }
        return ""
    }
}
