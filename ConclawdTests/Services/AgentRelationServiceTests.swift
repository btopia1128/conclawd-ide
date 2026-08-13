import XCTest
@testable import Conclawd

final class AgentRelationServiceTests: XCTestCase {

    let service = AgentRelationService()

    func testExtractRelations() {
        var parent = Agent()
        parent.name = "orchestrator"
        parent.tools = ["Read", "Bash", "Agent(coder, reviewer)"]

        var coder = Agent()
        coder.name = "coder"

        var reviewer = Agent()
        reviewer.name = "reviewer"

        let agents = [parent, coder, reviewer]
        let relations = service.extractRelations(agents: agents)

        XCTAssertEqual(relations.count, 2)
        XCTAssertTrue(relations.contains { $0.parentAgentId == parent.id && $0.childAgentId == coder.id })
        XCTAssertTrue(relations.contains { $0.parentAgentId == parent.id && $0.childAgentId == reviewer.id })
    }

    func testExtractRelationsNoAgentTool() {
        var agent = Agent()
        agent.name = "standalone"
        agent.tools = ["Read", "Bash"]

        let relations = service.extractRelations(agents: [agent])
        XCTAssertTrue(relations.isEmpty)
    }

    func testWouldCreateCycleDetection() {
        var a = Agent()
        a.name = "a"
        a.tools = ["Agent(b)"]

        var b = Agent()
        b.name = "b"
        b.tools = ["Agent(c)"]

        var c = Agent()
        c.name = "c"

        let agents = [a, b, c]

        // c -> a would create cycle: a -> b -> c -> a
        XCTAssertTrue(service.wouldCreateCycle(agents: agents, parentId: c.id, childId: a.id))

        // a -> c would not create a new cycle (already a -> b -> c path, but a -> c directly is fine as DAG)
        XCTAssertFalse(service.wouldCreateCycle(agents: agents, parentId: a.id, childId: c.id))
    }

    // MARK: - Cross-Project Detection

    func testIsCrossProject() {
        var a = Agent()
        a.name = "agent-a"
        a.scope = .project
        a.sourceProjectName = "ProjectA"

        var b = Agent()
        b.name = "agent-b"
        b.scope = .project
        b.sourceProjectName = "ProjectB"

        XCTAssertTrue(service.isCrossProject(parent: a, child: b))
    }

    func testIsCrossProjectSameProject() {
        var a = Agent()
        a.name = "agent-a"
        a.scope = .project
        a.sourceProjectName = "ProjectA"

        var b = Agent()
        b.name = "agent-b"
        b.scope = .project
        b.sourceProjectName = "ProjectA"

        XCTAssertFalse(service.isCrossProject(parent: a, child: b))
    }

    func testIsCrossProjectUserScope() {
        var a = Agent()
        a.name = "agent-a"
        a.scope = .user

        var b = Agent()
        b.name = "agent-b"
        b.scope = .project
        b.sourceProjectName = "ProjectB"

        XCTAssertFalse(service.isCrossProject(parent: a, child: b))
    }

    // MARK: - Broken References

    func testFindBrokenReferences() {
        var parent = Agent()
        parent.name = "orchestrator"
        parent.tools = ["Read", "Agent(coder, deleted_agent)"]

        var coder = Agent()
        coder.name = "coder"

        let broken = service.findBrokenReferences(agents: [parent, coder])
        XCTAssertEqual(broken.count, 1)
        XCTAssertEqual(broken.first?.unresolvedName, "deleted_agent")
        XCTAssertEqual(broken.first?.parent.name, "orchestrator")
    }

    func testFindBrokenReferencesNone() {
        var parent = Agent()
        parent.name = "orchestrator"
        parent.tools = ["Agent(coder)"]

        var coder = Agent()
        coder.name = "coder"

        let broken = service.findBrokenReferences(agents: [parent, coder])
        XCTAssertTrue(broken.isEmpty)
    }

    // MARK: - Full Warnings

    func testFindAllWarningsCrossProject() {
        var parent = Agent()
        parent.name = "parent"
        parent.scope = .project
        parent.sourceProjectName = "ProjA"
        parent.tools = ["Agent(child)"]

        var child = Agent()
        child.name = "child"
        child.scope = .project
        child.sourceProjectName = "ProjB"

        let warnings = service.findAllWarnings(agents: [parent, child])
        XCTAssertTrue(warnings.contains {
            if case .crossProjectReference = $0.kind { return true }
            return false
        })
    }

    func testFindAllWarningsBrokenRef() {
        var parent = Agent()
        parent.name = "parent"
        parent.tools = ["Agent(ghost)"]

        let warnings = service.findAllWarnings(agents: [parent])
        XCTAssertTrue(warnings.contains {
            if case .brokenReference = $0.kind { return true }
            return false
        })
    }
}
