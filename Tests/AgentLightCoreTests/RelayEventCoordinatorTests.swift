import XCTest
import AgentLightProtocol
@testable import AgentLightCore

final class RelayEventCoordinatorTests: XCTestCase {
    func testValidatesMapsAndSequencesRelayEventsBeforeMonitoring() async throws {
        let monitor = RelayRecordingMonitor()
        let coordinator = RelayEventCoordinator(monitor: monitor)
        let first = RelayEnvelope(
            version: 1,
            integrationID: AppIdentity.integrationIdentifier,
            source: .codex,
            event: "UserPromptSubmit",
            sessionID: "CANARY_SESSION",
            workspace: "/CANARY/WORKSPACE",
            status: nil,
            emittedAtMilliseconds: 1
        )
        let second = RelayEnvelope(
            version: 1,
            integrationID: AppIdentity.integrationIdentifier,
            source: .cursor,
            event: "preToolUse",
            sessionID: "CANARY_CURSOR",
            workspace: nil,
            status: nil,
            emittedAtMilliseconds: 2
        )

        await coordinator.accept(try JSONEncoder().encode(first))
        await coordinator.accept(Data("not-json".utf8))
        await coordinator.accept(try JSONEncoder().encode(second))

        let events = await monitor.events
        XCTAssertEqual(events.map(\.sequence), [1, 2])
        XCTAssertEqual(events.map(\.state), [.thinking, .working])
    }
}

private actor RelayRecordingMonitor: MonitoringOrchestrating {
    private(set) var events: [AgentEvent] = []
    func start() async throws {}
    func accept(_ event: AgentEvent) async { events.append(event) }
    func pause() async {}
    func resume() async throws {}
    func stop() async {}
    func reconnect() async {}
    func recoverIfNeeded() async throws {}
    func updates() async -> AsyncStream<MonitoringSnapshot> { AsyncStream { $0.finish() } }
    func currentSnapshot() async -> MonitoringSnapshot {
        MonitoringSnapshot(state: .idle, sessions: [], connection: .connected)
    }
}
