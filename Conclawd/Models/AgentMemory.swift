import Foundation

// MARK: - Agent Memory

struct AgentMemory: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var description: String
    var type: AgentMemoryType
    var content: String
    var createdAt: Date
    var updatedAt: Date
    var filePath: URL?
    var storage: MemoryStorage = .shared
    var ownership: MemoryOwnership = .agent
    var pinned: Bool = false

    init(
        id: UUID = UUID(),
        name: String,
        description: String,
        type: AgentMemoryType,
        content: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        filePath: URL? = nil,
        storage: MemoryStorage = .shared,
        ownership: MemoryOwnership = .agent,
        pinned: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.type = type
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.filePath = filePath
        self.storage = storage
        self.ownership = ownership
        self.pinned = pinned
    }
}

// MARK: - Memory Type

enum AgentMemoryType: String, Codable, CaseIterable, Hashable {
    case user
    case feedback
    case project
    case reference
    case learned

    var displayName: String {
        switch self {
        case .user: return "User"
        case .feedback: return "Feedback"
        case .project: return "Project"
        case .reference: return "Reference"
        case .learned: return "Learned"
        }
    }
}

// MARK: - Memory Action (from LLM extraction)

enum MemoryAction: Codable {
    case create(name: String, description: String, type: AgentMemoryType, content: String)
    case update(existingFile: String, content: String)
    case delete(existingFile: String, reason: String)
}

// MARK: - Extraction Response (JSON from LLM)

struct MemoryExtractionResponse: Codable {
    let memories: [MemoryExtractionEntry]
}

struct MemoryExtractionEntry: Codable {
    let action: String
    let name: String?
    let description: String?
    let type: String?
    let content: String?
    let existingFile: String?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case action, name, description, type, content, reason
        case existingFile = "existing_file"
    }

    func toMemoryAction() -> MemoryAction? {
        switch action {
        case "create":
            guard let name, let description, let typeStr = type, let content,
                  let memoryType = AgentMemoryType(rawValue: typeStr) else { return nil }
            return .create(name: name, description: description, type: memoryType, content: content)
        case "update":
            guard let existingFile, let content else { return nil }
            return .update(existingFile: existingFile, content: content)
        case "delete":
            guard let existingFile else { return nil }
            return .delete(existingFile: existingFile, reason: reason ?? "")
        default:
            return nil
        }
    }
}
