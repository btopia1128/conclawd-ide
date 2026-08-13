import CoreML
import Foundation

/// Generates 384-dimensional embeddings using the multilingual-e5-small CoreML model.
/// Thread-safe — uses an actor for serialized access to the model.
actor EmbeddingService {

    static let embeddingDimension = 384
    static let maxSequenceLength = 128

    private var model: MLModel?
    private var tokenizer: Tokenizer?
    private var isLoaded = false
    private var loadFailed = false

    // MARK: - Initialization

    /// Lazily loads the CoreML model and tokenizer on first use.
    /// If loading fails once, all subsequent calls throw immediately (no retry).
    private func ensureLoaded() async throws {
        if loadFailed { throw EmbeddingError.notReady }
        guard !isLoaded else { return }

        do {
            // Load CoreML model from app bundle
            guard let modelURL = Bundle.main.url(forResource: "MultilingualE5Small", withExtension: "mlmodelc")
                    ?? Bundle.main.url(forResource: "MultilingualE5Small", withExtension: "mlpackage") else {
                throw EmbeddingError.modelNotFound
            }

            let config = MLModelConfiguration()
            config.computeUnits = .all  // ANE > GPU > CPU auto-select
            model = try MLModel(contentsOf: modelURL, configuration: config)

            // Load tokenizer from bundled tokenizer.json
            guard let tokenizerDir = Bundle.main.url(forResource: "e5_tokenizer", withExtension: nil) else {
                throw EmbeddingError.tokenizerNotFound
            }

            tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerDir)

            isLoaded = true
        } catch {
            loadFailed = true
            print("[EmbeddingService] Load failed permanently: \(error)")
            throw error
        }
    }

    // MARK: - Public API

    /// Generate an embedding vector for the given text.
    /// Returns a 384-dimensional Float array.
    func generateEmbedding(for text: String) async throws -> [Float] {
        try await ensureLoaded()
        guard let model, let tokenizer else {
            throw EmbeddingError.notReady
        }

        // E5 requires "query: " or "passage: " prefix for best results.
        // Memory content is treated as passages.
        let prefixedText = "passage: \(text)"

        // Tokenize
        let encoded = tokenizer.encode(text: prefixedText)
        let tokenIds = Array(encoded.prefix(Self.maxSequenceLength))

        // Pad to maxSequenceLength
        let padId = 1  // <pad> token ID for XLM-RoBERTa
        var inputIds = [Int32](repeating: Int32(padId), count: Self.maxSequenceLength)
        var attentionMask = [Int32](repeating: 0, count: Self.maxSequenceLength)

        for (i, id) in tokenIds.enumerated() {
            inputIds[i] = Int32(id)
            attentionMask[i] = 1
        }

        // Create MLMultiArray inputs
        let inputIdsArray = try MLMultiArray(shape: [1, NSNumber(value: Self.maxSequenceLength)], dataType: .int32)
        let maskArray = try MLMultiArray(shape: [1, NSNumber(value: Self.maxSequenceLength)], dataType: .int32)

        for i in 0..<Self.maxSequenceLength {
            inputIdsArray[[0, i] as [NSNumber]] = NSNumber(value: inputIds[i])
            maskArray[[0, i] as [NSNumber]] = NSNumber(value: attentionMask[i])
        }

        // Run inference
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIdsArray),
            "attention_mask": MLFeatureValue(multiArray: maskArray),
        ])

        nonisolated(unsafe) let localModel = model
        let output = try await localModel.prediction(from: provider)

        guard let embeddingValue = output.featureValue(for: "embedding"),
              let embeddingArray = embeddingValue.multiArrayValue else {
            throw EmbeddingError.invalidOutput
        }

        // Convert MLMultiArray to [Float]
        var embedding = [Float](repeating: 0, count: Self.embeddingDimension)
        let ptr = embeddingArray.dataPointer.bindMemory(to: Float.self, capacity: Self.embeddingDimension)
        for i in 0..<Self.embeddingDimension {
            embedding[i] = ptr[i]
        }

        // L2 normalize
        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            for i in 0..<embedding.count {
                embedding[i] /= norm
            }
        }

        return embedding
    }

    /// Generate an embedding for a search query.
    /// Uses "query: " prefix for E5 model's asymmetric retrieval.
    func generateQueryEmbedding(for query: String) async throws -> [Float] {
        try await ensureLoaded()
        guard let model, let tokenizer else {
            throw EmbeddingError.notReady
        }

        let prefixedText = "query: \(query)"
        let encoded = tokenizer.encode(text: prefixedText)
        let tokenIds = Array(encoded.prefix(Self.maxSequenceLength))

        let padId = 1
        var inputIds = [Int32](repeating: Int32(padId), count: Self.maxSequenceLength)
        var attentionMask = [Int32](repeating: 0, count: Self.maxSequenceLength)

        for (i, id) in tokenIds.enumerated() {
            inputIds[i] = Int32(id)
            attentionMask[i] = 1
        }

        let inputIdsArray = try MLMultiArray(shape: [1, NSNumber(value: Self.maxSequenceLength)], dataType: .int32)
        let maskArray = try MLMultiArray(shape: [1, NSNumber(value: Self.maxSequenceLength)], dataType: .int32)

        for i in 0..<Self.maxSequenceLength {
            inputIdsArray[[0, i] as [NSNumber]] = NSNumber(value: inputIds[i])
            maskArray[[0, i] as [NSNumber]] = NSNumber(value: attentionMask[i])
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIdsArray),
            "attention_mask": MLFeatureValue(multiArray: maskArray),
        ])

        nonisolated(unsafe) let localModel = model
        let output = try await localModel.prediction(from: provider)

        guard let embeddingValue = output.featureValue(for: "embedding"),
              let embeddingArray = embeddingValue.multiArrayValue else {
            throw EmbeddingError.invalidOutput
        }

        var embedding = [Float](repeating: 0, count: Self.embeddingDimension)
        let ptr = embeddingArray.dataPointer.bindMemory(to: Float.self, capacity: Self.embeddingDimension)
        for i in 0..<Self.embeddingDimension {
            embedding[i] = ptr[i]
        }

        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            for i in 0..<embedding.count {
                embedding[i] /= norm
            }
        }

        return embedding
    }

    // MARK: - Utility

    /// Compute cosine similarity between two normalized vectors.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
        }
        return dot  // Already normalized, so dot product = cosine similarity
    }

    /// Serialize an embedding to Data (for SQLite BLOB storage).
    static func serialize(_ embedding: [Float]) -> Data {
        embedding.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    /// Deserialize an embedding from Data.
    static func deserialize(_ data: Data) -> [Float]? {
        guard data.count == embeddingDimension * MemoryLayout<Float>.size else { return nil }
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }

    /// Whether the model is available in the app bundle.
    static var isModelAvailable: Bool {
        let hasModel = Bundle.main.url(forResource: "MultilingualE5Small", withExtension: "mlmodelc") != nil
            || Bundle.main.url(forResource: "MultilingualE5Small", withExtension: "mlpackage") != nil
        guard hasModel else { return false }
        // Also verify tokenizer directory exists with required files
        guard let tokenizerDir = Bundle.main.url(forResource: "e5_tokenizer", withExtension: nil) else { return false }
        let tokenizerFile = tokenizerDir.appending(path: "tokenizer.json")
        return FileManager.default.fileExists(atPath: tokenizerFile.path(percentEncoded: false))
    }
}

// MARK: - Errors

enum EmbeddingError: Error, LocalizedError {
    case modelNotFound
    case tokenizerNotFound
    case notReady
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .modelNotFound: return "MultilingualE5Small not found in app bundle"
        case .tokenizerNotFound: return "e5_tokenizer directory not found in app bundle"
        case .notReady: return "EmbeddingService not initialized"
        case .invalidOutput: return "CoreML model returned unexpected output"
        }
    }
}
