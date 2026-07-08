import AgentLightProtocol
import Foundation
import XCTest
@testable import AgentLightCore

final class AgentAdapterTests: XCTestCase {
    func testApprovedMappings() throws {
        XCTAssertEqual(
            try CodexAdapter().map(envelope(source: .codex, event: "UserPromptSubmit"), sequence: 1).state,
            .thinking
        )
        XCTAssertEqual(
            try ClaudeCodeAdapter().map(envelope(source: .claudeCode, event: "PermissionRequest"), sequence: 2).state,
            .needsYou
        )
        XCTAssertEqual(
            try CursorAdapter().map(envelope(source: .cursor, event: "stop", status: "error"), sequence: 3).state,
            .error
        )
    }

    func testEveryDeclaredMappingProducesExpectedEvent() throws {
        let codexStates: [String: AgentState] = [
            "UserPromptSubmit": .thinking,
            "PreToolUse": .working,
            "PostToolUse": .thinking,
            "PermissionRequest": .needsYou,
            "Stop": .completed
        ]
        let claudeStates: [String: AgentState] = [
            "UserPromptSubmit": .thinking,
            "PreToolUse": .working,
            "PostToolUse": .thinking,
            "PermissionRequest": .needsYou,
            "Stop": .completed,
            "StopFailure": .error,
            "SessionEnd": .idle
        ]
        let cursorStates: [String: AgentState] = [
            "beforeSubmitPrompt": .thinking,
            "preToolUse": .working,
            "beforeShellExecution": .working,
            "postToolUse": .thinking,
            "afterShellExecution": .thinking,
            "sessionEnd": .idle
        ]

        for (event, state) in codexStates {
            let mapped = try CodexAdapter().map(envelope(source: .codex, event: event), sequence: 4)
            XCTAssertEqual(mapped, agentEvent(source: .codex, state: state, sequence: 4))
        }
        for (event, state) in claudeStates {
            let mapped = try ClaudeCodeAdapter().map(envelope(source: .claudeCode, event: event), sequence: 5)
            XCTAssertEqual(mapped, agentEvent(source: .claudeCode, state: state, sequence: 5))
        }
        for (event, state) in cursorStates {
            let mapped = try CursorAdapter().map(envelope(source: .cursor, event: event), sequence: 6)
            XCTAssertEqual(mapped, agentEvent(source: .cursor, state: state, sequence: 6))
        }
    }

    func testConditionalMappingsUseSanitizedStatus() throws {
        XCTAssertEqual(
            try ClaudeCodeAdapter().map(
                envelope(source: .claudeCode, event: "Notification", status: "agent_needs_input"),
                sequence: 1
            ).state,
            .needsYou
        )
        XCTAssertEqual(
            try ClaudeCodeAdapter().map(
                envelope(source: .claudeCode, event: "Notification", status: "agent_completed"),
                sequence: 2
            ).state,
            .completed
        )
        XCTAssertEqual(
            try CursorAdapter().map(envelope(source: .cursor, event: "stop", status: "completed"), sequence: 3).state,
            .completed
        )
        XCTAssertEqual(
            try CursorAdapter().map(envelope(source: .cursor, event: "stop", status: "error"), sequence: 4).state,
            .error
        )
    }

    func testToolStartUsesSanitizedActivityCategory() throws {
        let cases: [(RelayActivity?, AgentState)] = [
            (.reading, .reading), (.editing, .editing), (.testing, .testing),
            (.working, .working), (nil, .working)
        ]
        for (activity, expected) in cases {
            XCTAssertEqual(
                try CodexAdapter().map(
                    envelope(source: .codex, event: "PreToolUse", activity: activity),
                    sequence: 1
                ).state,
                expected
            )
            XCTAssertEqual(
                try ClaudeCodeAdapter().map(
                    envelope(source: .claudeCode, event: "PreToolUse", activity: activity),
                    sequence: 1
                ).state,
                expected
            )
        }
    }

    func testCursorDistinguishesCancelledFromError() throws {
        XCTAssertEqual(
            try CursorAdapter().map(envelope(source: .cursor, event: "stop", status: "aborted"), sequence: 1).state,
            .cancelled
        )
        XCTAssertEqual(
            try CursorAdapter().map(envelope(source: .cursor, event: "stop", status: "error"), sequence: 2).state,
            .error
        )
    }

    func testCursorToolStartsUseSanitizedActivityCategory() throws {
        let cases: [(RelayActivity?, AgentState)] = [
            (.reading, .reading), (.editing, .editing), (.testing, .testing),
            (.working, .working), (nil, .working)
        ]
        for event in ["preToolUse", "beforeShellExecution"] {
            for (activity, expected) in cases {
                XCTAssertEqual(
                    try CursorAdapter().map(
                        envelope(source: .cursor, event: event, activity: activity),
                        sequence: 1
                    ).state,
                    expected
                )
            }
        }
    }

    func testWrongSourceAndUnknownEventsThrow() {
        XCTAssertThrowsError(
            try CodexAdapter().map(envelope(source: .cursor, event: "Stop"), sequence: 1)
        ) { error in
            XCTAssertEqual(error as? AdapterError, .wrongSource)
        }
        XCTAssertThrowsError(
            try ClaudeCodeAdapter().map(envelope(source: .claudeCode, event: "Unknown"), sequence: 1)
        ) { error in
            XCTAssertEqual(error as? AdapterError, .unsupportedEvent("Unknown"))
        }
        XCTAssertThrowsError(
            try CursorAdapter().map(envelope(source: .cursor, event: "stop", status: "unknown"), sequence: 1)
        ) { error in
            XCTAssertEqual(error as? AdapterError, .unsupportedEvent("stop"))
        }
    }

    func testSanitizedFixturesDecodeAndMap() throws {
        let cases: [(String, AgentSource, AgentState)] = [
            ("codex-user-prompt", .codex, .thinking),
            ("claude-permission", .claudeCode, .needsYou),
            ("cursor-stop-error", .cursor, .error),
            ("codex-read", .codex, .reading),
            ("claude-edit", .claudeCode, .editing),
            ("cursor-test", .cursor, .testing),
            ("cursor-cancelled", .cursor, .cancelled)
        ]

        for (name, source, expectedState) in cases {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
            let envelope = try JSONDecoder().decode(RelayEnvelope.self, from: Data(contentsOf: url))
            let state: AgentState
            switch source {
            case .codex:
                state = try CodexAdapter().map(envelope, sequence: 1).state
            case .claudeCode:
                state = try ClaudeCodeAdapter().map(envelope, sequence: 1).state
            case .cursor:
                state = try CursorAdapter().map(envelope, sequence: 1).state
            }
            XCTAssertEqual(state, expectedState)
        }
    }

    private func envelope(
        source: AgentSource,
        event: String,
        status: String? = nil,
        activity: RelayActivity? = nil
    ) -> RelayEnvelope {
        RelayEnvelope(
            version: 1,
            integrationID: AppIdentity.integrationIdentifier,
            source: source,
            event: event,
            sessionID: "session",
            workspace: "Workspace",
            status: status,
            emittedAtMilliseconds: 1,
            activity: activity
        )
    }

    private func agentEvent(source: AgentSource, state: AgentState, sequence: UInt64) -> AgentEvent {
        AgentEvent(
            source: source,
            sessionID: "session",
            workspace: "Workspace",
            state: state,
            sequence: sequence
        )
    }
}
