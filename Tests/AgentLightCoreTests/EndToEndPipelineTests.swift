import AgentLightProtocol
import Foundation
import XCTest
@testable import AgentLightCore

final class EndToEndPipelineTests: XCTestCase {
    func testCodexFixtureReachesFakeLightAsThinkingThroughSocket() async throws {
        let applied = try await runFixtureThroughProductionPipeline(named: "codex-user-prompt")

        XCTAssertEqual(applied, DesiredLightState(color: try XCTUnwrap(AgentState.thinking.color)))
    }

    func testClaudeFixtureReachesFakeLightAsNeedsYouThroughSocket() async throws {
        let applied = try await runFixtureThroughProductionPipeline(named: "claude-permission")

        XCTAssertEqual(applied, DesiredLightState(color: try XCTUnwrap(AgentState.needsYou.color)))
    }

    func testCursorFixtureReachesFakeLightAsErrorThroughSocket() async throws {
        let applied = try await runFixtureThroughProductionPipeline(named: "cursor-stop-error")

        XCTAssertEqual(applied, DesiredLightState(color: try XCTUnwrap(AgentState.error.color)))
    }

    private func runFixtureThroughProductionPipeline(named name: String) async throws -> DesiredLightState? {
        let fixture = try fixtureData(named: name)
        let path = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString + ".sock").path
        let light = RecordingLightController()
        let clock = ManualClock()
        let orchestrator = MonitoringOrchestrator(
            light: light,
            recoveryStore: MemoryRecoveryStore(),
            clock: clock
        )
        let coordinator = RelayEventCoordinator(monitor: orchestrator)
        let server = UnixDatagramServer(path: path)
        let delivered = expectation(description: "fixture delivered to relay coordinator")

        do {
            try await orchestrator.start()
            try await server.start { data in
                await coordinator.accept(data)
                delivered.fulfill()
            }
            XCTAssertTrue(UnixDatagramSender(path: path).sendFailOpen(fixture))
            await fulfillment(of: [delivered], timeout: 1)
            let sleepScheduled = await eventually { await clock.sleepRequestCount() >= 1 }
            XCTAssertTrue(sleepScheduled)
            await clock.advance(by: .seconds(1))
            let commandApplied = await eventually { await light.appliedStates().count == 1 }
            XCTAssertTrue(commandApplied)
            let applied = await light.appliedStates().last
            await server.stop()
            let stop = Task { await orchestrator.stop() }
            await orchestrator.waitForLifecycleRequestNumber(2)
            await clock.advance(by: .seconds(1))
            await stop.value
            return applied
        } catch {
            await server.stop()
            let stop = Task { await orchestrator.stop() }
            await orchestrator.waitForLifecycleRequestNumber(2)
            await clock.advance(by: .seconds(1))
            await stop.value
            throw error
        }
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
