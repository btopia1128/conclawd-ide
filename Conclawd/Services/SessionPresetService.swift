import Foundation

/// Persists session presets in a single JSON file under ~/.claude/agent-terminal/.
struct SessionPresetService {

    private static let fileURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/agent-terminal/session-presets.json")
    }()

    // MARK: - Public

    func loadPresets() -> [SessionPreset] {
        let path = Self.fileURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        do {
            let data = try Data(contentsOf: Self.fileURL)
            return try JSONDecoder().decode([SessionPreset].self, from: data)
        } catch {
            print("[SessionPresetService] Failed to load presets: \(error)")
            return []
        }
    }

    func savePresets(_ presets: [SessionPreset]) {
        let dir = Self.fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(presets)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            print("[SessionPresetService] Failed to save presets: \(error)")
        }
    }
}
