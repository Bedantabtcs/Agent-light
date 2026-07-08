import Foundation
import XCTest
@testable import AgentLightProtocol

final class RelayEnvelopeTests: XCTestCase {
    func testDecodeValidatedAcceptsExactlyMaximumEncodedBytes() throws {
        let envelope = makeEnvelope()
        var payload = try JSONEncoder().encode(envelope)
        payload.append(Data(repeating: 0x20, count: RelayEnvelope.maximumEncodedBytes - payload.count))

        XCTAssertEqual(payload.count, 2_048)
        XCTAssertEqual(try RelayEnvelope.decodeValidated(from: payload), envelope)
    }

    func testDecodeValidatedRejectsPayloadAboveMaximumBeforeDecoding() throws {
        var payload = try JSONEncoder().encode(makeEnvelope(workspace: "CANARY_PAYLOAD"))
        payload.append(Data(repeating: 0x20, count: RelayEnvelope.maximumEncodedBytes + 1 - payload.count))

        XCTAssertEqual(payload.count, 2_049)
        assertValidationError(.payloadTooLarge) {
            try RelayEnvelope.decodeValidated(from: payload)
        }
    }

    func testDecodeValidatedMapsMalformedPayloadToSanitizedError() {
        assertValidationError(.invalidPayload) {
            try RelayEnvelope.decodeValidated(from: Data(#"{"sessionID":"CANARY""#.utf8))
        }
    }

    func testDecodeValidatedMapsUnknownSourceToSanitizedError() {
        let payload = Data(
            #"{"emittedAtMilliseconds":1,"event":"UserPromptSubmit","integrationID":"com.bbatchas.agentlight.hook.v1","sessionID":"session","source":"CANARY_SOURCE","version":1}"#.utf8
        )

        assertValidationError(.invalidSource) {
            try RelayEnvelope.decodeValidated(from: payload)
        }
    }

    func testActivityRoundTripsWithoutChangingVersion() throws {
        let envelope = makeEnvelope(activity: .reading)
        let encoded = try JSONEncoder().encode(envelope)

        XCTAssertEqual(try RelayEnvelope.decodeValidated(from: encoded), envelope)
        XCTAssertEqual(envelope.version, 1)
    }

    func testLegacyEnvelopeWithoutActivityStillDecodes() throws {
        let payload = Data(
            #"{"emittedAtMilliseconds":1,"event":"PreToolUse","integrationID":"com.bbatchas.agentlight.hook.v1","sessionID":"session","source":"codex","version":1}"#.utf8
        )

        XCTAssertNil(try RelayEnvelope.decodeValidated(from: payload).activity)
    }

    func testUnknownActivityMapsToSanitizedInvalidPayload() {
        let payload = Data(
            #"{"activity":"CANARY_ACTIVITY","emittedAtMilliseconds":1,"event":"PreToolUse","integrationID":"com.bbatchas.agentlight.hook.v1","sessionID":"session","source":"codex","version":1}"#.utf8
        )

        assertValidationError(.invalidPayload) {
            try RelayEnvelope.decodeValidated(from: payload)
        }
    }

    func testDecodeValidatedRejectsEachInvalidScalarBoundaryWithTypedSanitizedError() throws {
        let cases: [(RelayValidationError, RelayEnvelope)] = [
            (.unsupportedVersion, makeEnvelope(version: 2, workspace: "CANARY_VERSION")),
            (.invalidIntegration, makeEnvelope(integrationID: "CANARY_INTEGRATION")),
            (.invalidEvent, makeEnvelope(event: "CANARY_EVENT" + String(repeating: "e", count: 118))),
            (.invalidEvent, makeEnvelope(event: "", workspace: "CANARY_EMPTY_EVENT")),
            (.invalidSession, makeEnvelope(sessionID: "", workspace: "CANARY_EMPTY_SESSION")),
            (.invalidWorkspace, makeEnvelope(workspace: "CANARY_WORKSPACE" + String(repeating: "w", count: 497))),
            (.invalidStatus, makeEnvelope(status: "CANARY_STATUS" + String(repeating: "s", count: 53)))
        ]

        for (expected, envelope) in cases {
            assertValidationError(expected) {
                try RelayEnvelope.decodeValidated(from: JSONEncoder().encode(envelope))
            }
        }
    }

    func testValidationAcceptsEachMaximumScalarBoundary() throws {
        let envelope = makeEnvelope(
            event: String(repeating: "e", count: 128),
            sessionID: String(repeating: "i", count: 256),
            workspace: String(repeating: "w", count: 512),
            status: String(repeating: "s", count: 64)
        )

        XCTAssertEqual(try envelope.validated(), envelope)
    }

    private func makeEnvelope(
        version: Int = 1,
        integrationID: String = AppIdentity.integrationIdentifier,
        event: String = "UserPromptSubmit",
        sessionID: String = "session",
        workspace: String? = nil,
        status: String? = nil,
        activity: RelayActivity? = nil
    ) -> RelayEnvelope {
        RelayEnvelope(
            version: version,
            integrationID: integrationID,
            source: .codex,
            event: event,
            sessionID: sessionID,
            workspace: workspace,
            status: status,
            emittedAtMilliseconds: 1,
            activity: activity
        )
    }

    private func assertValidationError<T>(
        _ expected: RelayValidationError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? RelayValidationError, expected, file: file, line: line)
            XCTAssertFalse(String(describing: error).contains("CANARY"), file: file, line: line)
        }
    }
}
