import Foundation

/// A saved Claude session configuration that can be launched with one click.
/// Unlike Agent (.md), this does not use --agent flag and passes all settings
/// directly as CLI arguments via startStandaloneSession().
struct SessionPreset: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var model: AgentModel = .inherit
    var permissionMode: PermissionMode = .default
    var directory: String = ""
    var systemPrompt: String?
    var customFlags: String?
    var provider: CLIProviderType = .claude
    /// When set, this raw CLI argument string is used instead of model/permissionMode/systemPrompt/customFlags.
    var rawCommand: String?

    enum CodingKeys: String, CodingKey {
        case id, name, model, permissionMode, directory, systemPrompt, customFlags, provider, rawCommand
    }

    var isCommandMode: Bool { rawCommand != nil }

    init(
        id: UUID = UUID(),
        name: String,
        model: AgentModel = .inherit,
        permissionMode: PermissionMode = .default,
        directory: String = "",
        systemPrompt: String? = nil,
        customFlags: String? = nil,
        provider: CLIProviderType = .claude,
        rawCommand: String? = nil
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.permissionMode = permissionMode
        self.directory = directory
        self.systemPrompt = systemPrompt
        self.customFlags = customFlags
        self.provider = provider
        self.rawCommand = rawCommand
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        model = try container.decodeIfPresent(AgentModel.self, forKey: .model) ?? .inherit
        permissionMode = try container.decodeIfPresent(PermissionMode.self, forKey: .permissionMode) ?? .default
        directory = try container.decodeIfPresent(String.self, forKey: .directory) ?? ""
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        customFlags = try container.decodeIfPresent(String.self, forKey: .customFlags)
        provider = try container.decodeIfPresent(CLIProviderType.self, forKey: .provider) ?? .claude
        rawCommand = try container.decodeIfPresent(String.self, forKey: .rawCommand)
    }
}
