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
        var payload = try JSONEncoder().encode(makeEnvelope())
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
            #"{"emittedAtMilliseconds":1,"event":"UserPromptSubmit","integrationID":"com.bbatchas.agentlight.hook.v1","sessionID":"session","source":"unknown-provider","version":1}"#.utf8
        )

        assertValidationError(.invalidSource) {
            try RelayEnvelope.decodeValidated(from: payload)
        }
    }

    func testValidationRejectsEachInvalidScalarBoundary() {
        let cases: [(RelayValidationError, RelayEnvelope)] = [
            (.unsupportedVersion, makeEnvelope(version: 2)),
            (.invalidIntegration, makeEnvelope(integrationID: "invalid-integration")),
            (.invalidEvent, makeEnvelope(event: String(repeating: "e", count: 129))),
            (.invalidSession, makeEnvelope(sessionID: "")),
            (.invalidWorkspace, makeEnvelope(workspace: String(repeating: "w", count: 513))),
            (.invalidStatus, makeEnvelope(status: String(repeating: "s", count: 65)))
        ]

        for (expected, envelope) in cases {
            assertValidationError(expected) {
                try envelope.validated()
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
        status: String? = nil
    ) -> RelayEnvelope {
        RelayEnvelope(
            version: version,
            integrationID: integrationID,
            source: .codex,
            event: event,
            sessionID: sessionID,
            workspace: workspace,
            status: status,
            emittedAtMilliseconds: 1
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
