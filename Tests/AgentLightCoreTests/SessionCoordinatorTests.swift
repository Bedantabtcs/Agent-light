import XCTest
import AgentLightProtocol
@testable import AgentLightCore

final class SessionCoordinatorTests: XCTestCase {
    func testEmptyCoordinatorHasNoWinnerOrSnapshots() async {
        let coordinator = SessionCoordinator()

        let winner = await coordinator.currentWinner()
        let snapshots = await coordinator.snapshots()

        XCTAssertNil(winner)
        XCTAssertEqual(snapshots, [])
    }

    func testMatchingSessionIdentifiersFromDifferentSourcesRemainIndependent() async {
        let coordinator = SessionCoordinator()
        await coordinator.accept(event(source: .codex, session: "shared", state: .thinking, sequence: 1))
        await coordinator.accept(event(source: .claudeCode, session: "shared", state: .working, sequence: 2))

        let winner = await coordinator.currentWinner()
        let snapshots = await coordinator.snapshots()

        XCTAssertEqual(winner?.source, .claudeCode)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(Set(snapshots.map(\.source)), Set([.codex, .claudeCode]))
    }

    func testIdleRemovesOnlyMatchingSourceAndSession() async {
        let coordinator = SessionCoordinator()
        await coordinator.accept(event(source: .codex, session: "shared", state: .thinking, sequence: 1))
        await coordinator.accept(event(source: .claudeCode, session: "shared", state: .working, sequence: 2))

        await coordinator.accept(event(source: .codex, session: "shared", state: .idle, sequence: 3))

        let snapshots = await coordinator.snapshots()
        XCTAssertEqual(snapshots.map(\.source), [.claudeCode])
    }

    func testStaleExpiryCannotRemoveReplacementForSameIdentity() async {
        let coordinator = SessionCoordinator()
        await coordinator.accept(event(source: .codex, session: "same", state: .completed, sequence: 1))
        await coordinator.accept(event(source: .codex, session: "same", state: .error, sequence: 2))

        await coordinator.expireTerminalState(source: .codex, sessionID: "same", sequence: 1)

        let winner = await coordinator.currentWinner()
        XCTAssertEqual(winner?.sequence, 2)
        XCTAssertEqual(winner?.state, .error)
    }

    func testTerminalExpiryCannotRemoveNewerNonterminalEventForSameIdentity() async {
        let coordinator = SessionCoordinator()
        await coordinator.accept(event(source: .codex, session: "same", state: .completed, sequence: 1))
        await coordinator.accept(event(source: .codex, session: "same", state: .working, sequence: 2))

        await coordinator.expireTerminalState(source: .codex, sessionID: "same", sequence: 2)

        let winner = await coordinator.currentWinner()
        XCTAssertEqual(winner?.state, .working)
    }

    func testExpiryForMissingIdentityLeavesOtherSessionsUnchanged() async {
        let coordinator = SessionCoordinator()
        await coordinator.accept(event(source: .codex, session: "present", state: .completed, sequence: 1))

        await coordinator.expireTerminalState(source: .cursor, sessionID: "missing", sequence: 1)

        let snapshots = await coordinator.snapshots()
        XCTAssertEqual(snapshots.map(\.sessionID), ["present"])
    }

    func testOlderSequenceForSameIdentityIsRejected() async {
        let coordinator = SessionCoordinator()
        await coordinator.accept(event(source: .cursor, session: "same", state: .working, sequence: 8))

        await coordinator.accept(event(source: .cursor, session: "same", state: .error, sequence: 7))

        let winner = await coordinator.currentWinner()
        XCTAssertEqual(winner?.sequence, 8)
        XCTAssertEqual(winner?.state, .working)
    }

    func testTerminalExpiryFallsBackToNewestActiveSession() async {
        let coordinator = SessionCoordinator()
        await coordinator.accept(event(source: .claudeCode, session: "a", state: .thinking, sequence: 1))
        await coordinator.accept(event(source: .codex, session: "b", state: .completed, sequence: 2))

        await coordinator.expireTerminalState(source: .codex, sessionID: "b", sequence: 2)

        let winner = await coordinator.currentWinner()
        XCTAssertEqual(winner?.sessionID, "a")
    }

    @available(*, deprecated, message: "Compatibility coverage")
    func testLegacySourceLessExpiryRemovesUniqueExactTerminalIdentity() async {
        let coordinator = SessionCoordinator()
        await coordinator.accept(event(source: .codex, session: "legacy", state: .completed, sequence: 4))
        await coordinator.accept(event(source: .cursor, session: "other", state: .working, sequence: 5))

        await coordinator.expireTerminalState(sessionID: "legacy", sequence: 4)

        let snapshots = await coordinator.snapshots()
        XCTAssertEqual(snapshots.map(\.sessionID), ["other"])
    }

    @available(*, deprecated, message: "Compatibility coverage")
    func testLegacySourceLessExpiryFailsClosedForAmbiguousProviderIdentity() async {
        let coordinator = SessionCoordinator()
        await coordinator.accept(event(source: .codex, session: "shared", state: .completed, sequence: 7))
        await coordinator.accept(event(source: .claudeCode, session: "shared", state: .error, sequence: 7))

        await coordinator.expireTerminalState(sessionID: "shared", sequence: 7)

        let snapshots = await coordinator.snapshots()
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(Set(snapshots.map(\.source)), Set([.codex, .claudeCode]))
    }

    func testEqualSequenceReverseInsertionUsesStableLexicalTieBreak() async {
        let coordinator = SessionCoordinator()
        await coordinator.accept(event(source: .cursor, session: "beta", state: .working, sequence: 7))
        await coordinator.accept(event(source: .codex, session: "alpha", state: .thinking, sequence: 7))

        let winner = await coordinator.currentWinner()
        let snapshots = await coordinator.snapshots()

        XCTAssertEqual(winner?.sessionID, "beta")
        XCTAssertEqual(snapshots.map(\.sessionID), ["beta", "alpha"])
    }

    func testEqualSequenceAndSessionAcrossProvidersUsesSourceLexicalTieBreak() async {
        let coordinator = SessionCoordinator()
        await coordinator.accept(event(source: .codex, session: "shared", state: .working, sequence: 7))
        await coordinator.accept(event(source: .claudeCode, session: "shared", state: .thinking, sequence: 7))

        let winner = await coordinator.currentWinner()
        let snapshots = await coordinator.snapshots()

        XCTAssertEqual(winner?.source, .codex)
        XCTAssertEqual(snapshots.map(\.source), [.codex, .claudeCode])
    }

    func testEqualSequenceForSameIdentityReplacesPriorEvent() async {
        let coordinator = SessionCoordinator()
        await coordinator.accept(event(source: .codex, session: "shared", state: .thinking, sequence: 9))
        await coordinator.accept(event(source: .codex, session: "shared", state: .working, sequence: 9))

        let snapshots = await coordinator.snapshots()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.state, .working)
    }

    private func event(
        source: AgentSource,
        session: String,
        state: AgentState,
        sequence: UInt64
    ) -> AgentEvent {
        AgentEvent(
            source: source,
            sessionID: session,
            workspace: nil,
            state: state,
            sequence: sequence
        )
    }
}
