import SwiftUI

/// Parsed recall_memory result entry.
struct RecallEntry: Identifiable {
    let id = UUID()
    let name: String
    let score: Double
    let matchLayer: String
    let agentName: String?   // non-nil when scope = "all"
    let type: String?        // "transcript" when applicable
    let preview: String
}

/// Parses the recall_memory MCP tool output into structured entries.
struct RecallMemoryResult {
    let query: String
    let entries: [RecallEntry]
    let scope: String?

    /// Parse from the text output of recall_memory tool.
    /// Expected format from recall-tool.ts:
    /// ```
    /// Found N relevant memories for "query":
    ///
    /// **name** [agentName] (transcript) (score: 0.82)
    /// preview text...
    ///
    /// **name2** (score: 0.71)
    /// preview text...
    /// ```
    static func parse(from text: String) -> RecallMemoryResult? {
        let lines = text.components(separatedBy: "\n")
        guard let firstLine = lines.first,
              firstLine.hasPrefix("Found "),
              let queryRange = firstLine.range(of: "\""),
              let queryEndRange = firstLine.range(of: "\":", options: .backwards) else {
            return nil
        }

        let queryStart = firstLine.index(after: queryRange.lowerBound)
        let query = String(firstLine[queryStart..<queryEndRange.lowerBound])

        var entries: [RecallEntry] = []
        var currentName: String?
        var currentScore: Double = 0
        var currentAgent: String?
        var currentType: String?
        var currentPreview: [String] = []

        let headerPattern = try? NSRegularExpression(
            pattern: #"\*\*(.+?)\*\*(?:\s+\[(.+?)\])?(?:\s+\(transcript\))?\s+\(score:\s+([\d.]+)\)"#
        )

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let match = headerPattern?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
                // Flush previous entry
                if let name = currentName {
                    entries.append(RecallEntry(
                        name: name, score: currentScore, matchLayer: "fts5",
                        agentName: currentAgent, type: currentType,
                        preview: currentPreview.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }

                let name = Range(match.range(at: 1), in: trimmed).map { String(trimmed[$0]) } ?? ""
                let agent = Range(match.range(at: 2), in: trimmed).map { String(trimmed[$0]) }
                let score = Range(match.range(at: 3), in: trimmed).flatMap { Double(trimmed[$0]) } ?? 0

                currentName = name
                currentScore = score
                currentAgent = agent
                currentType = trimmed.contains("(transcript)") ? "transcript" : nil
                currentPreview = []
            } else if currentName != nil && !trimmed.isEmpty {
                currentPreview.append(trimmed)
            }
        }

        // Flush last entry
        if let name = currentName {
            entries.append(RecallEntry(
                name: name, score: currentScore, matchLayer: "fts5",
                agentName: currentAgent, type: currentType,
                preview: currentPreview.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }

        guard !entries.isEmpty else { return nil }

        let hasOtherAgents = entries.contains { $0.agentName != nil }
        return RecallMemoryResult(query: query, entries: entries, scope: hasOtherAgents ? "all" : "self")
    }
}

// MARK: - Tool Card (used in ChatBubbleView)

/// Displays a recall_memory tool call as a specialized card in ChatBubbleView.
/// Shows the query from the tool input, and if complete, tries to parse results.
struct RecallMemoryToolCardView: View {
    let toolUse: ChatToolUse
    @State private var isExpanded = true

    private var query: String {
        guard let data = toolUse.input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let q = json["query"] as? String else {
            return toolUse.inputSummary
        }
        return q
    }

    private var scope: String {
        guard let data = toolUse.input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = json["scope"] as? String else {
            return "self"
        }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 10))
                        .foregroundStyle(.purple)
                        .frame(width: 16)

                    Text("recall_memory")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)

                    if scope == "all" {
                        Text("all")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.purple.opacity(0.15))
                            .foregroundStyle(.purple)
                            .cornerRadius(3)
                    }

                    if !query.isEmpty {
                        Text(query)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.appSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
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

            // Expanded: show query details
            if isExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Query:")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.appSecondary)
                        Text(query)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }

                    HStack(spacing: 4) {
                        Text("Scope:")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.appSecondary)
                        Text(scope)
                            .font(.system(size: 10))
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.purple.opacity(0.3), lineWidth: 0.5)
        )
        .cornerRadius(8)
    }
}

// MARK: - Full Result Card (for future use with tool results)

/// Displays a recall_memory result with full entry table.
/// Used when the tool result text is available and parseable.
struct RecallMemoryCardView: View {
    let result: RecallMemoryResult
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 10))
                        .foregroundStyle(.purple)
                        .frame(width: 16)

                    Text("recall_memory")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)

                    if result.scope == "all" {
                        Text("all")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.purple.opacity(0.15))
                            .foregroundStyle(.purple)
                            .cornerRadius(3)
                    }

                    Spacer()

                    Text("\(result.entries.count) results")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appSecondary)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.appTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    // Query
                    HStack(spacing: 4) {
                        Text("Query:")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.appSecondary)
                        Text(result.query)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    // Results table
                    VStack(spacing: 2) {
                        ForEach(result.entries) { entry in
                            HStack(spacing: 6) {
                                Text(String(format: "%.2f", entry.score))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(scoreColor(entry.score))
                                    .frame(width: 32, alignment: .trailing)

                                Text(entry.name)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Text(entry.matchLayer)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.appTertiary)

                                if let type = entry.type {
                                    Text(type)
                                        .font(.system(size: 9))
                                        .padding(.horizontal, 3)
                                        .padding(.vertical, 1)
                                        .background(.blue.opacity(0.1))
                                        .foregroundStyle(.blue)
                                        .cornerRadius(2)
                                }

                                if let agent = entry.agentName {
                                    Spacer()
                                    Text(agent)
                                        .font(.system(size: 9))
                                        .foregroundStyle(Color.appSecondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.purple.opacity(0.3), lineWidth: 0.5)
        )
        .cornerRadius(8)
    }

    private func scoreColor(_ score: Double) -> Color {
        if score >= 0.8 { return .green }
        if score >= 0.5 { return .orange }
        return Color.appSecondary
    }
}
