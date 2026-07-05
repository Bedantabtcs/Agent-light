import Foundation
import XCTest
@testable import AgentLightProtocol

final class RelayEncodingTests: XCTestCase {
    func testSanitizerCreatesAllowlistedEnvelope() throws {
        let input = try JSONSerialization.data(withJSONObject: [
            "session_id": "session-from-input",
            "cwd": "/Users/example/Secure Access",
            "status": "completed",
            "prompt": "private hook input",
            "token": "secret"
        ])

        let envelope = try RelayInputSanitizer.makeEnvelope(
            arguments: validArguments(source: "codex", event: "UserPromptSubmit"),
            input: input,
            nowMilliseconds: 42
        )

        XCTAssertEqual(
            envelope,
            RelayEnvelope(
                version: 1,
                integrationID: AppIdentity.integrationIdentifier,
                source: .codex,
                event: "UserPromptSubmit",
                sessionID: "session-from-input",
                workspace: "Secure Access",
                status: "completed",
                emittedAtMilliseconds: 42
            )
        )

        let encoded = try JSONEncoder().encode(envelope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            Set([
                "version", "integrationID", "source", "event", "sessionID",
                "workspace", "status", "emittedAtMilliseconds"
            ])
        )
        XCTAssertNil(object["prompt"])
        XCTAssertNil(object["token"])
        XCTAssertLessThanOrEqual(encoded.count, 4_096)
    }

    func testSanitizerUsesArgumentSessionWhenInputHasNoSession() throws {
        let envelope = try RelayInputSanitizer.makeEnvelope(
            arguments: validArguments(
                source: "cursor",
                event: "stop",
                additional: ["--session-id", "session-from-arguments"]
            ),
            input: Data("{}".utf8),
            nowMilliseconds: 7
        )

        XCTAssertEqual(envelope.sessionID, "session-from-arguments")
        XCTAssertEqual(envelope.source, .cursor)
        XCTAssertNil(envelope.workspace)
        XCTAssertNil(envelope.status)
    }

    func testSanitizerRejectsOversizedInputBeforeParsing() {
        let input = Data(repeating: 0, count: RelayInputSanitizer.maximumInputBytes + 1)

        XCTAssertThrowsError(
            try RelayInputSanitizer.makeEnvelope(
                arguments: validArguments(source: "codex", event: "stop"),
                input: input,
                nowMilliseconds: 1
            )
        ) { error in
            XCTAssertEqual(error as? RelayInputError, .inputTooLarge)
        }
    }

    func testSanitizerRejectsMissingSessionAndInvalidArguments() {
        XCTAssertThrowsError(
            try RelayInputSanitizer.makeEnvelope(
                arguments: validArguments(source: "claudeCode", event: "PermissionRequest"),
                input: Data("{}".utf8),
                nowMilliseconds: 1
            )
        ) { error in
            XCTAssertEqual(error as? RelayInputError, .missingSession)
        }

        XCTAssertThrowsError(
            try RelayInputSanitizer.makeEnvelope(
                arguments: [
                    "relay", "--integration-id", "unexpected", "--source", "codex",
                    "--event", "stop", "--session-id", "session"
                ],
                input: Data("{}".utf8),
                nowMilliseconds: 1
            )
        ) { error in
            XCTAssertEqual(error as? RelayInputError, .invalidArguments)
        }
    }

    private func validArguments(
        source: String,
        event: String,
        additional: [String] = []
    ) -> [String] {
        [
            "relay", "--integration-id", AppIdentity.integrationIdentifier,
            "--source", source, "--event", event
        ] + additional
    }
}
