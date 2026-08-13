import XCTest
@testable import Conclawd

final class AgentConfigServiceTests: XCTestCase {

    let service = AgentConfigService()

    // MARK: - Frontmatter Parsing

    func testSplitFrontmatter() {
        let content = """
        ---
        name: test-agent
        model: sonnet
        ---

        You are a test agent.
        """

        let (frontmatter, body) = service.splitFrontmatter(content)
        XCTAssertNotNil(frontmatter)
        XCTAssertTrue(frontmatter!.contains("name: test-agent"))
        XCTAssertTrue(frontmatter!.contains("model: sonnet"))
        XCTAssertTrue(body.contains("You are a test agent."))
    }

    func testSplitFrontmatterNoFrontmatter() {
        let content = "Just a plain markdown file."
        let (frontmatter, body) = service.splitFrontmatter(content)
        XCTAssertNil(frontmatter)
        XCTAssertEqual(body, content)
    }

    func testParseAgentContent() {
        let content = """
        ---
        name: code-reviewer
        description: Reviews code for quality
        model: sonnet
        color: blue
        tools: Read, Grep, Glob, Agent(tester)
        permissionMode: plan
        maxTurns: 50
        ---

        You are a code reviewer.
        """

        let agent = service.parseAgentContent(content)
        XCTAssertNotNil(agent)
        XCTAssertEqual(agent?.name, "code-reviewer")
        XCTAssertEqual(agent?.description, "Reviews code for quality")
        XCTAssertEqual(agent?.model, .sonnet)
        XCTAssertEqual(agent?.color, .blue)
        XCTAssertEqual(agent?.tools, ["Read", "Grep", "Glob", "Agent(tester)"])
        XCTAssertEqual(agent?.permissionMode, .plan)
        XCTAssertEqual(agent?.maxTurns, 50)
        XCTAssertEqual(agent?.systemPrompt, "You are a code reviewer.")
        XCTAssertEqual(agent?.subAgentNames, ["tester"])
    }

    func testParseAgentContentMinimal() {
        let content = """
        ---
        name: minimal
        ---
        """

        let agent = service.parseAgentContent(content)
        XCTAssertNotNil(agent)
        XCTAssertEqual(agent?.name, "minimal")
        XCTAssertEqual(agent?.model, .inherit)
        XCTAssertEqual(agent?.tools, [])
        XCTAssertTrue(agent?.systemPrompt.isEmpty ?? false)
    }

    func testParseAgentContentMultipleSubAgents() {
        let content = """
        ---
        name: orchestrator
        tools: Read, Bash, Agent(coder, reviewer, tester)
        ---
        """

        let agent = service.parseAgentContent(content)
        XCTAssertNotNil(agent)
        XCTAssertEqual(agent?.subAgentNames, ["coder", "reviewer", "tester"])
    }

    // MARK: - Serialization

    func testSerializeAgent() {
        var agent = Agent()
        agent.name = "test-agent"
        agent.description = "A test agent"
        agent.model = .opus
        agent.color = .green
        agent.tools = ["Read", "Bash", "Agent(helper)"]
        agent.permissionMode = .dontAsk
        agent.maxTurns = 100
        agent.systemPrompt = "You are a test agent.\n\nDo your best."

        let content = service.serializeAgent(agent)

        XCTAssertTrue(content.contains("name: test-agent"))
        XCTAssertTrue(content.contains("description: A test agent"))
        XCTAssertTrue(content.contains("model: opus"))
        XCTAssertTrue(content.contains("color: green"))
        XCTAssertTrue(content.contains("tools: Read, Bash, Agent(helper)"))
        XCTAssertTrue(content.contains("permissionMode: dontAsk"))
        XCTAssertTrue(content.contains("maxTurns: 100"))
        XCTAssertTrue(content.contains("You are a test agent."))
    }

    // MARK: - Roundtrip

    func testRoundtrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var agent = Agent()
        agent.name = "roundtrip-test"
        agent.description = "Testing roundtrip"
        agent.model = .sonnet
        agent.color = .purple
        agent.tools = ["Read", "Bash"]
        agent.permissionMode = .acceptEdits
        agent.systemPrompt = "You handle roundtrip tests."

        try service.saveAgent(agent, to: tmpDir)

        let loaded = service.loadAgents(from: tmpDir, scope: .project)
        XCTAssertEqual(loaded.count, 1)

        let result = loaded[0]
        XCTAssertEqual(result.name, "roundtrip-test")
        XCTAssertEqual(result.description, "Testing roundtrip")
        XCTAssertEqual(result.model, .sonnet)
        XCTAssertEqual(result.color, .purple)
        XCTAssertEqual(result.tools, ["Read", "Bash"])
        XCTAssertEqual(result.permissionMode, .acceptEdits)
        XCTAssertEqual(result.systemPrompt, "You handle roundtrip tests.")
    }
}

// Make loadAgents accessible for tests
extension AgentConfigService {
    func loadAgents(from directory: URL, scope: AgentScope) -> [Agent] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path(percentEncoded: false)) else { return [] }

        do {
            let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return files
                .filter { $0.pathExtension == "md" }
                .compactMap { url in
                    parseAgentFile(at: url, scope: scope)
                }
        } catch {
            return []
        }
    }
}
