import CoreML
import Foundation

/// Standalone CLI tool for generating query embeddings using the CoreML E5 model.
/// Used by the MCP server (Node.js) to compute query embeddings for hybrid search.
///
/// Usage:
///   conclawd-embed --resources-dir <dir> <text>
///   conclawd-embed <model-path> <tokenizer-path> <text>
///
/// Output: JSON array of 384 floats to stdout.
/// Errors go to stderr. Exit code 0 on success, 1 on failure.

let args = CommandLine.arguments

let modelPath: String
let tokenizerPath: String
let queryText: String

if args.count == 4, args[1] == "--resources-dir" {
    let dir = args[2]
    modelPath = (dir as NSString).appendingPathComponent("MultilingualE5Small.mlmodelc")
    tokenizerPath = (dir as NSString).appendingPathComponent("e5_tokenizer")
    queryText = args[3]
} else if args.count == 4 {
    modelPath = args[1]
    tokenizerPath = args[2]
    queryText = args[3]
} else {
    FileHandle.standardError.write(Data("Usage: conclawd-embed --resources-dir <dir> <text>\n       conclawd-embed <model-path> <tokenizer-path> <text>\n".utf8))
    _exit(1)
}

// MARK: - Embedding Generation

let embeddingDimension = 384
let maxSequenceLength = 128

do {
    // Load CoreML model
    guard FileManager.default.fileExists(atPath: modelPath) else {
        throw NSError(domain: "ConclawdEmbed", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not found: \(modelPath)"])
    }
    let config = MLModelConfiguration()
    config.computeUnits = .all
    let model = try MLModel(contentsOf: URL(filePath: modelPath), configuration: config)

    // Load tokenizer
    guard FileManager.default.fileExists(atPath: tokenizerPath) else {
        throw NSError(domain: "ConclawdEmbed", code: 1, userInfo: [NSLocalizedDescriptionKey: "Tokenizer not found: \(tokenizerPath)"])
    }
    let tokenizer = try await AutoTokenizer.from(modelFolder: URL(filePath: tokenizerPath))

    // E5 query prefix for asymmetric retrieval
    let prefixedText = "query: \(queryText)"
    let encoded = tokenizer.encode(text: prefixedText)
    let tokenIds = Array(encoded.prefix(maxSequenceLength))

    // Pad to maxSequenceLength
    let padId = 1
    var inputIds = [Int32](repeating: Int32(padId), count: maxSequenceLength)
    var attentionMask = [Int32](repeating: 0, count: maxSequenceLength)
    for (i, id) in tokenIds.enumerated() {
        inputIds[i] = Int32(id)
        attentionMask[i] = 1
    }

    // Create MLMultiArray inputs
    let inputIdsArray = try MLMultiArray(shape: [1, NSNumber(value: maxSequenceLength)], dataType: .int32)
    let maskArray = try MLMultiArray(shape: [1, NSNumber(value: maxSequenceLength)], dataType: .int32)
    for i in 0..<maxSequenceLength {
        inputIdsArray[[0, i] as [NSNumber]] = NSNumber(value: inputIds[i])
        maskArray[[0, i] as [NSNumber]] = NSNumber(value: attentionMask[i])
    }

    // Run inference
    let provider = try MLDictionaryFeatureProvider(dictionary: [
        "input_ids": MLFeatureValue(multiArray: inputIdsArray),
        "attention_mask": MLFeatureValue(multiArray: maskArray),
    ])
    let output = try await model.prediction(from: provider)

    guard let embeddingValue = output.featureValue(for: "embedding"),
          let embeddingArray = embeddingValue.multiArrayValue else {
        throw NSError(domain: "ConclawdEmbed", code: 1, userInfo: [NSLocalizedDescriptionKey: "CoreML model returned unexpected output"])
    }

    // Convert to [Float]
    var embedding = [Float](repeating: 0, count: embeddingDimension)
    let ptr = embeddingArray.dataPointer.bindMemory(to: Float.self, capacity: embeddingDimension)
    for i in 0..<embeddingDimension {
        embedding[i] = ptr[i]
    }

    // L2 normalize
    let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
    if norm > 0 {
        for i in 0..<embedding.count {
            embedding[i] /= norm
        }
    }

    // Output as JSON array to stdout
    let jsonData = try JSONSerialization.data(withJSONObject: embedding, options: [])
    FileHandle.standardOutput.write(jsonData)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    _exit(1)
}
