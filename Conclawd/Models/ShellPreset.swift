import Foundation

/// A saved shell configuration that can be launched with one click.
struct ShellPreset: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var directory: String          // Relative path from project root (e.g. "app-api")
    var command: String?           // Command to run on launch (e.g. "npm run dev")
    var shell: ShellType

    enum CodingKeys: String, CodingKey {
        case id, name, directory, command, shell
    }

    init(id: UUID = UUID(), name: String, directory: String, command: String? = nil, shell: ShellType = .zsh) {
        self.id = id
        self.name = name
        self.directory = directory
        self.command = command
        self.shell = shell
    }
}
