// Minimal HubApi stub for local tokenizer loading.
// Replaces the full HubApi from swift-transformers which depends on swift-nio, swift-crypto, etc.

import Foundation

public struct HubApi: Sendable {
    public static let shared = HubApi()

    public init() {}

    /// Parse a JSON file into a Config object.
    func configuration(fileURL: URL) throws -> Config {
        let data = try Data(contentsOf: fileURL)
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = parsed as? [NSString: Any] else {
            throw NSError(domain: "HubApi", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON in \(fileURL.lastPathComponent)"])
        }
        return Config(dictionary)
    }
}
