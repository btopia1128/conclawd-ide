import Foundation

/// Persists shell presets in a single JSON file under ~/.claude/agent-terminal/.
struct ShellPresetService {

    private static let fileURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/agent-terminal/shell-presets.json")
    }()

    // MARK: - Public

    func loadPresets() -> [ShellPreset] {
        let path = Self.fileURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        do {
            let data = try Data(contentsOf: Self.fileURL)
            return try JSONDecoder().decode([ShellPreset].self, from: data)
        } catch {
            print("[ShellPresetService] Failed to load presets: \(error)")
            return []
        }
    }

    func savePresets(_ presets: [ShellPreset]) {
        let dir = Self.fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(presets)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            print("[ShellPresetService] Failed to save presets: \(error)")
        }
    }
}
