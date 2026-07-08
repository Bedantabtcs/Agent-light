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
                emittedAtMilliseconds: 42,
                activity: nil
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
        XCTAssertNil(object["activity"])
        XCTAssertEqual(RelayEnvelope.maximumEncodedBytes, 2_048)
        XCTAssertLessThanOrEqual(encoded.count, RelayEnvelope.maximumEncodedBytes)
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

    func testSanitizerClassifiesBoundedToolActivity() throws {
        let cases: [(AgentSource, String, [String: Any], RelayActivity)] = [
            (.codex, "PreToolUse", ["tool_name": "Read"], .reading),
            (.claudeCode, "PreToolUse", ["tool_name": "Edit"], .editing),
            (.cursor, "preToolUse", ["toolName": "apply_patch"], .editing),
            (.cursor, "beforeShellExecution", ["command": "swift test --parallel"], .testing),
            (
                .codex,
                "PreToolUse",
                ["tool_name": "Bash", "tool_input": ["command": "git status"]],
                .working
            )
        ]

        for (source, event, fields, expected) in cases {
            var input = fields
            input["session_id"] = "session"
            let data = try JSONSerialization.data(withJSONObject: input)
            let envelope = try RelayInputSanitizer.makeEnvelope(
                arguments: validArguments(source: source.rawValue, event: event),
                input: data,
                nowMilliseconds: 1
            )
            XCTAssertEqual(envelope.activity, expected)
        }
    }

    func testSanitizerClassifiesRawHookFixtures() throws {
        let cases: [(String, AgentSource, String, RelayActivity)] = [
            ("codex-read-hook", .codex, "PreToolUse", .reading),
            ("claude-edit-hook", .claudeCode, "PreToolUse", .editing),
            ("cursor-test-hook", .cursor, "beforeShellExecution", .testing)
        ]

        for (fixture, source, event, expected) in cases {
            let url = try XCTUnwrap(Bundle.module.url(forResource: fixture, withExtension: "json"))
            let envelope = try RelayInputSanitizer.makeEnvelope(
                arguments: validArguments(source: source.rawValue, event: event),
                input: Data(contentsOf: url),
                nowMilliseconds: 1
            )
            XCTAssertEqual(envelope.activity, expected)
        }
    }

    func testClassifierIgnoresActivityOnNonToolStartEvents() throws {
        let input = try JSONSerialization.data(withJSONObject: [
            "session_id": "session",
            "tool_name": "Read"
        ])
        let envelope = try RelayInputSanitizer.makeEnvelope(
            arguments: validArguments(source: "codex", event: "PostToolUse"),
            input: input,
            nowMilliseconds: 1
        )
        XCTAssertNil(envelope.activity)
    }

    func testClassifierFallsBackToWorkingForBoundedInvalidInputs() throws {
        let unsafeCharacters = ["\n", "\r", ";", "&", "|", "<", ">", "$", "`"]
        let cases: [(AgentSource, String, [String: Any])] = [
            (.codex, "PreToolUse", ["tool_name": String(repeating: "a", count: 257)]),
            (
                .cursor,
                "beforeShellExecution",
                ["command": String(repeating: "a", count: 4_097)]
            ),
            (.cursor, "preToolUse", ["tool_name": "Read", "toolName": "Read"]),
            (.claudeCode, "PreToolUse", ["tool_name": "UnknownTool"]),
            (.codex, "PreToolUse", ["tool_name": "Bash", "tool_input": "invalid"]),
            (.codex, "PreToolUse", ["tool_name": "Bash", "tool_input": ["command": 42]]),
            (.cursor, "preToolUse", ["toolName": "terminal", "toolInput": ["command": ["nested"]]])
        ] + unsafeCharacters.map { character in
            (
                .codex,
                "PreToolUse",
                ["tool_name": "Bash", "tool_input": ["command": "swift test\(character)echo unsafe"]]
            )
        }

        for (source, event, fields) in cases {
            var input = fields
            input["session_id"] = "session"
            let data = try JSONSerialization.data(withJSONObject: input)
            let envelope = try RelayInputSanitizer.makeEnvelope(
                arguments: validArguments(source: source.rawValue, event: event),
                input: data,
                nowMilliseconds: 1
            )
            XCTAssertEqual(envelope.activity, .working)
        }
    }

    func testSanitizerDoesNotEncodeRawActivityInputs() throws {
        let cases: [(AgentSource, String, [String: Any])] = [
            (
                .codex,
                "PreToolUse",
                [
                    "thread_id": "session",
                    "tool_name": "CANARY_TOOL",
                    "tool_input": [
                        "command": "CANARY_COMMAND",
                        "path": "CANARY_PRIVATE_PATH"
                    ]
                ]
            ),
            (
                .claudeCode,
                "PreToolUse",
                [
                    "session_id": "session",
                    "tool_name": "Read",
                    "tool_input": ["file_path": "CANARY_PRIVATE_PATH"]
                ]
            ),
            (
                .cursor,
                "beforeShellExecution",
                [
                    "conversation_id": "session",
                    "toolName": "terminal",
                    "command": "CANARY_COMMAND"
                ]
            )
        ]
        let forbiddenStrings = [
            "CANARY_TOOL", "CANARY_COMMAND", "CANARY_PRIVATE_PATH",
            "tool_name", "toolName", "tool_input", "command"
        ]

        for (source, event, input) in cases {
            let data = try JSONSerialization.data(withJSONObject: input)
            let envelope = try RelayInputSanitizer.makeEnvelope(
                arguments: validArguments(source: source.rawValue, event: event),
                input: data,
                nowMilliseconds: 1
            )
            let encoded = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)

            for forbiddenString in forbiddenStrings {
                XCTAssertFalse(encoded.contains(forbiddenString))
            }
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
