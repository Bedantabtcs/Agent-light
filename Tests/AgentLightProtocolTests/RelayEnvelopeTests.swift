import XCTest
@testable import AgentLightProtocol

final class RelayEnvelopeTests: XCTestCase {
    func testRejectsOversizedWorkspaceAndUnknownVersion() throws {
        let oversized = RelayEnvelope(
            version: 1,
            integrationID: AppIdentity.integrationIdentifier,
            source: .codex,
            event: "UserPromptSubmit",
            sessionID: "session",
            workspace: String(repeating: "x", count: 513),
            status: nil,
            emittedAtMilliseconds: 1
        )
        XCTAssertThrowsError(try oversized.validated())
        XCTAssertThrowsError(try RelayEnvelope(
            version: 2,
            integrationID: AppIdentity.integrationIdentifier,
            source: .cursor,
            event: "stop",
            sessionID: "session",
            workspace: nil,
            status: "completed",
            emittedAtMilliseconds: 1
        ).validated())
    }
}
