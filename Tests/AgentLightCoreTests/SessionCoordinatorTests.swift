import XCTest
import AgentLightProtocol
@testable import AgentLightCore

final class SessionCoordinatorTests: XCTestCase {
    func testNewestEventWinsAndOlderTerminalExpiryCannotOverrideIt() async {
        let coordinator = SessionCoordinator()
        await coordinator.accept(
            AgentEvent(
                source: .codex,
                sessionID: "a",
                workspace: "One",
                state: .completed,
                sequence: 1
            )
        )
        await coordinator.accept(
            AgentEvent(
                source: .cursor,
                sessionID: "b",
                workspace: "Two",
                state: .working,
                sequence: 2
            )
        )

        await coordinator.expireTerminalState(sessionID: "a", sequence: 1)

        let winner = await coordinator.currentWinner()
        XCTAssertEqual(winner?.sessionID, "b")
        XCTAssertEqual(winner?.state, .working)
    }

    func testTerminalExpiryFallsBackToNewestActiveSession() async {
        let coordinator = SessionCoordinator()
        await coordinator.accept(
            AgentEvent(
                source: .claudeCode,
                sessionID: "a",
                workspace: nil,
                state: .thinking,
                sequence: 1
            )
        )
        await coordinator.accept(
            AgentEvent(
                source: .codex,
                sessionID: "b",
                workspace: nil,
                state: .completed,
                sequence: 2
            )
        )

        await coordinator.expireTerminalState(sessionID: "b", sequence: 2)

        let winner = await coordinator.currentWinner()
        XCTAssertEqual(winner?.sessionID, "a")
    }

    func testEqualSequenceAcrossSessionsUsesStableLexicalTieBreak() async {
        let coordinator = SessionCoordinator()
        await coordinator.accept(
            AgentEvent(
                source: .codex,
                sessionID: "alpha",
                workspace: nil,
                state: .thinking,
                sequence: 7
            )
        )
        await coordinator.accept(
            AgentEvent(
                source: .cursor,
                sessionID: "beta",
                workspace: nil,
                state: .working,
                sequence: 7
            )
        )

        let winner = await coordinator.currentWinner()
        let snapshots = await coordinator.snapshots()

        XCTAssertEqual(winner?.sessionID, "beta")
        XCTAssertEqual(snapshots.map(\.sessionID), ["beta", "alpha"])
    }

    func testEqualSequenceForSameSessionReplacesPriorEvent() async {
        let coordinator = SessionCoordinator()
        await coordinator.accept(
            AgentEvent(
                source: .codex,
                sessionID: "shared",
                workspace: "Before",
                state: .thinking,
                sequence: 9
            )
        )
        await coordinator.accept(
            AgentEvent(
                source: .cursor,
                sessionID: "shared",
                workspace: "After",
                state: .working,
                sequence: 9
            )
        )

        let snapshots = await coordinator.snapshots()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.source, .cursor)
        XCTAssertEqual(snapshots.first?.workspace, "After")
        XCTAssertEqual(snapshots.first?.state, .working)
    }
}
