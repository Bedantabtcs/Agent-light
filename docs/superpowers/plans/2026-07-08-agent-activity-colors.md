# Agent Activity Colors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add privacy-preserving Reading, Editing, Testing, and Cancelled bulb states while keeping unknown activity blue and retaining all existing lifecycle behavior.

**Architecture:** The relay protocol gains one optional bounded `RelayActivity` enum. A new protocol-layer classifier inspects only verified hook fields, emits only that enum, and discards raw tool data; core adapters convert the enum into new `AgentState` cases. Existing coordination handles active states unchanged, while Cancelled joins the terminal-state path with an eight-second hold.

**Tech Stack:** Swift 6.2, Swift Package Manager, XCTest, Swift Concurrency actors, SwiftUI/AppKit, JSON relay envelopes, Unix datagram transport, Tuya cloud control.

## Global Constraints

- Target macOS 14 or later and keep Swift language mode 6.
- Keep relay envelope version 1 and the 2,048-byte encoded-envelope limit.
- Keep relay input capped at 1 MiB, tool identifiers capped at 256 UTF-8 bytes, and inspected commands capped at 4,096 UTF-8 bytes.
- Never forward, persist, or log raw tool names, commands, arguments, paths, prompts, outputs, source text, or hook JSON.
- Unknown, malformed, oversized, ambiguous, or unsupported activity must fall back to Working.
- Do not evaluate shell input, expand variables, execute classifier input, or parse chained commands.
- Preserve the one-second Tuya throttle, newest-event arbitration, 80% color value, retry spacing, and baseline restore behavior.
- Use test-driven development for every behavior change and make one focused commit per task.
- Do not change installed hook event sets or rewrite user hook files for this feature.

---

## File Structure

- Create `Sources/AgentLightProtocol/RelayActivity.swift`: wire-safe activity enum only.
- Create `Sources/AgentLightProtocol/RelayActivityClassifier.swift`: bounded source-aware extraction and deterministic allowlist classification.
- Modify `Sources/AgentLightProtocol/RelayEnvelope.swift`: optional activity field and backward-compatible initializer.
- Modify `Sources/AgentLightProtocol/RelayInputSanitizer.swift`: call the classifier after validating relay arguments.
- Modify `Sources/AgentLightCore/Domain/AgentState.swift`: four new states, approved colors, and terminal-state identity.
- Modify the three files under `Sources/AgentLightCore/Integrations/*Adapter.swift`: activity mapping and explicit Cursor cancellation.
- Modify `Sources/AgentLightCore/Integrations/AgentEventAdapter.swift`: shared `RelayActivity` to `AgentState` conversion.
- Modify `Sources/AgentLightCore/Coordination/SessionCoordinator.swift`: expire Cancelled like other terminal states.
- Modify `Sources/AgentLightCore/Coordination/MonitoringOrchestrator.swift`: Cancelled timer and recovery validation.
- Create `Sources/AgentLightUI/Views/AgentStatePresentation.swift`: one UI presentation mapping for labels and symbols.
- Modify `Sources/AgentLightUI/Views/AmbientBulbView.swift` and `MenuBarContentView.swift`: consume the shared presentation mapping.
- Modify protocol, core, coordination, UI, and end-to-end tests in their existing test targets.
- Add raw-hook fixtures under `Tests/AgentLightProtocolTests/Fixtures` and sanitized-envelope fixtures under `Tests/AgentLightCoreTests/Fixtures`.
- Modify `README.md`: document the expanded palette, privacy boundary, and manual checks.

---

### Task 1: Add the backward-compatible relay activity field

**Files:**
- Create: `Sources/AgentLightProtocol/RelayActivity.swift`
- Modify: `Sources/AgentLightProtocol/RelayEnvelope.swift`
- Modify: `Tests/AgentLightProtocolTests/RelayEnvelopeTests.swift`
- Modify: `Tests/AgentLightProtocolTests/RelayEncodingTests.swift`

**Interfaces:**
- Produces: `public enum RelayActivity: String, Codable, Equatable, Sendable`
- Produces: `RelayEnvelope.activity: RelayActivity?`
- Produces: `RelayEnvelope.init(..., emittedAtMilliseconds: Int64, activity: RelayActivity? = nil)`
- Preserves: every existing initializer call compiles without an activity argument.

- [ ] **Step 1: Write failing relay compatibility tests**

Add tests proving an activity round-trips, an omitted field remains valid, and an unknown wire value becomes a sanitized validation error:

```swift
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
```

Extend the local `makeEnvelope` helper with `activity: RelayActivity? = nil` and pass it through to the initializer. Update `testSanitizerCreatesAllowlistedEnvelope` only after the production initializer exists; its nil-activity encoded key set must remain unchanged.

- [ ] **Step 2: Run the focused tests and verify the expected compile failure**

Run:

```bash
swift test --filter 'RelayEnvelopeTests|RelayEncodingTests'
```

Expected: FAIL because `RelayActivity` and `RelayEnvelope.activity` do not exist.

- [ ] **Step 3: Add the minimal wire model and envelope property**

Create `RelayActivity.swift`:

```swift
public enum RelayActivity: String, Codable, Equatable, Sendable {
    case reading
    case editing
    case testing
    case working
}
```

Add the property and defaulted initializer parameter to `RelayEnvelope`:

```swift
public let activity: RelayActivity?

public init(
    version: Int,
    integrationID: String,
    source: AgentSource,
    event: String,
    sessionID: String,
    workspace: String?,
    status: String?,
    emittedAtMilliseconds: Int64,
    activity: RelayActivity? = nil
) {
    self.version = version
    self.integrationID = integrationID
    self.source = source
    self.event = event
    self.sessionID = sessionID
    self.workspace = workspace
    self.status = status
    self.emittedAtMilliseconds = emittedAtMilliseconds
    self.activity = activity
}
```

Rely on synthesized Codable behavior: absent optional values decode as nil and encode without a key.

- [ ] **Step 4: Run protocol tests**

Run:

```bash
swift test --filter 'RelayEnvelopeTests|RelayEncodingTests'
```

Expected: all selected tests PASS, including the legacy payload and unknown-category cases.

- [ ] **Step 5: Commit the relay model**

```bash
git add Sources/AgentLightProtocol/RelayActivity.swift Sources/AgentLightProtocol/RelayEnvelope.swift Tests/AgentLightProtocolTests/RelayEnvelopeTests.swift Tests/AgentLightProtocolTests/RelayEncodingTests.swift
git commit -m "feat: add relay activity category"
```

---

### Task 2: Classify hook activity locally without leaking inputs

**Files:**
- Modify: `Package.swift`
- Create: `Sources/AgentLightProtocol/RelayActivityClassifier.swift`
- Modify: `Sources/AgentLightProtocol/RelayInputSanitizer.swift`
- Create: `Tests/AgentLightProtocolTests/Fixtures/codex-read-hook.json`
- Create: `Tests/AgentLightProtocolTests/Fixtures/claude-edit-hook.json`
- Create: `Tests/AgentLightProtocolTests/Fixtures/cursor-test-hook.json`
- Modify: `Tests/AgentLightProtocolTests/RelayEncodingTests.swift`

**Interfaces:**
- Consumes: `RelayActivity` from Task 1.
- Produces: `enum RelayActivityClassifier` with `static func classify(source:event:object:) -> RelayActivity?`.
- Produces: `RelayInputSanitizer.makeEnvelope` setting only `RelayEnvelope.activity`.

- [ ] **Step 1: Add failing classification and privacy tests**

Add `.process("Fixtures")` resources to the `AgentLightProtocolTests` target. Create bounded, sanitized raw-hook fixtures with these source shapes:

```json
{"thread_id":"fixture-codex","cwd":"/Fixture","tool_name":"Read","tool_input":{"path":"CANARY_PRIVATE_PATH"}}
```

```json
{"session_id":"fixture-claude","cwd":"/Fixture","tool_name":"Edit","tool_input":{"file_path":"CANARY_PRIVATE_PATH"}}
```

```json
{"conversation_id":"fixture-cursor","workspace":"/Fixture","command":"swift test --parallel"}
```

Load those resources through `Bundle.module` and assert Reading, Editing, and Testing respectively. Also use table-driven inline tests in `RelayEncodingTests`:

```swift
func testSanitizerClassifiesBoundedToolActivity() throws {
    let cases: [(AgentSource, String, [String: Any], RelayActivity)] = [
        (.codex, "PreToolUse", ["tool_name": "Read"], .reading),
        (.claudeCode, "PreToolUse", ["tool_name": "Edit"], .editing),
        (.cursor, "preToolUse", ["toolName": "apply_patch"], .editing),
        (.cursor, "beforeShellExecution", ["command": "swift test --parallel"], .testing),
        (.codex, "PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "git status"]], .working)
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
```

Add fallback cases for a 257-byte tool name, a 4,097-byte command, duplicate `tool_name` and `toolName` aliases, unknown tools, commands containing `&&`, `;`, `|`, newline, `$`, backticks, `<`, or `>`, and invalid nested shapes. Each valid tool-start event must return `.working`, not throw.

Add a canary test that encodes each result and asserts the encoded text contains none of `CANARY_TOOL`, `CANARY_COMMAND`, `CANARY_PRIVATE_PATH`, `tool_name`, `toolName`, `tool_input`, or `command`.

- [ ] **Step 2: Run the sanitizer tests and verify failure**

Run:

```bash
swift test --filter RelayEncodingTests
```

Expected: FAIL because the sanitizer always emits nil activity.

- [ ] **Step 3: Implement bounded source-aware extraction**

Create `RelayActivityClassifier.swift` with these constants and entry point:

```swift
import Foundation

enum RelayActivityClassifier {
    static let maximumToolNameBytes = 256
    static let maximumCommandBytes = 4_096

    static func classify(
        source: AgentSource,
        event: String,
        object: [String: Any]?
    ) -> RelayActivity? {
        guard isToolStart(source: source, event: event) else { return nil }
        guard let object else { return .working }

        let toolName = uniqueBoundedString(
            in: object,
            paths: toolNamePaths(for: source),
            maximumBytes: maximumToolNameBytes
        )
        let command = uniqueBoundedString(
            in: object,
            paths: commandPaths(for: source),
            maximumBytes: maximumCommandBytes
        )

        if let toolName, isReadingTool(toolName) { return .reading }
        if let toolName, isEditingTool(toolName) { return .editing }
        if isCommandTool(toolName, source: source, event: event),
           let command,
           isRecognizedValidationCommand(command) {
            return .testing
        }
        return .working
    }
}
```

Implement `isToolStart` exactly as:

```swift
switch source {
case .codex, .claudeCode: event == "PreToolUse"
case .cursor: event == "preToolUse" || event == "beforeShellExecution"
}
```

Use explicit field paths: Codex and Claude use `tool_name` plus `tool_input.command`; Cursor accepts `toolName`, `tool_name`, top-level `command`, `toolInput.command`, or `tool_input.command`. `uniqueBoundedString` must return nil unless exactly one configured path resolves to a nonempty String within its byte limit.

Normalize tool names with `lowercased()` only. Use exact built-in names and exact MCP operation suffixes:

```swift
private static let readingTools: Set<String> = [
    "read", "grep", "glob", "webfetch", "websearch", "read_file",
    "list_directory", "search_files", "search", "find", "fetch", "get", "inspect", "view"
]

private static let editingTools: Set<String> = [
    "edit", "write", "apply_patch", "notebookedit", "write_file", "edit_file"
]
```

For MCP names, split only on `__` and compare the final component with the exact sets. Do not classify by arbitrary substring.

Command tools are exact normalized names `bash`, `exec_command`, `shell`, and `terminal`, plus Cursor `beforeShellExecution` without a tool name. Reject a command if it contains any of `\n`, `\r`, `;`, `&`, `|`, `<`, `>`, `$`, or `` ` ``. After trimming ASCII whitespace, match only equality or `prefix + " "` against this list:

```swift
private static let validationCommandPrefixes = [
    "swift test", "swift build", "xcodebuild",
    "npm test", "npm run test", "npm run build", "npm run lint", "npm run typecheck",
    "pnpm test", "pnpm build", "pnpm lint", "pnpm typecheck",
    "yarn test", "yarn build", "yarn lint", "yarn typecheck",
    "pytest", "python -m pytest", "python3 -m pytest",
    "go test", "cargo test", "cargo build", "dotnet test",
    "make test", "./gradlew test", "gradle test", "mvn test"
]
```

- [ ] **Step 4: Attach only the category to the envelope**

In `RelayInputSanitizer.makeEnvelope`, calculate:

```swift
let activity = RelayActivityClassifier.classify(
    source: options.source,
    event: options.event,
    object: object
)
```

Pass `activity: activity` to `RelayEnvelope`. Do not add raw extraction helpers or raw fields to the envelope.

- [ ] **Step 5: Run protocol and relay deadline tests**

Run:

```bash
swift test --filter 'RelayEncodingTests|RelayEnvelopeTests|RelayDeadlineTests'
```

Expected: all selected tests PASS, including leakage canaries and fail-open deadline tests.

- [ ] **Step 6: Commit the classifier**

```bash
git add Package.swift Sources/AgentLightProtocol/RelayActivityClassifier.swift Sources/AgentLightProtocol/RelayInputSanitizer.swift Tests/AgentLightProtocolTests/Fixtures/codex-read-hook.json Tests/AgentLightProtocolTests/Fixtures/claude-edit-hook.json Tests/AgentLightProtocolTests/Fixtures/cursor-test-hook.json Tests/AgentLightProtocolTests/RelayEncodingTests.swift
git commit -m "feat: classify relay activity privately"
```

---

### Task 3: Map activity categories to agent states and colors

**Files:**
- Modify: `Sources/AgentLightCore/Domain/AgentState.swift`
- Modify: `Sources/AgentLightCore/Integrations/AgentEventAdapter.swift`
- Modify: `Sources/AgentLightCore/Integrations/CodexAdapter.swift`
- Modify: `Sources/AgentLightCore/Integrations/ClaudeCodeAdapter.swift`
- Modify: `Sources/AgentLightCore/Integrations/CursorAdapter.swift`
- Modify: `Tests/AgentLightCoreTests/AgentStateTests.swift`
- Modify: `Tests/AgentLightCoreTests/AgentAdapterTests.swift`

**Interfaces:**
- Consumes: `RelayEnvelope.activity` from Tasks 1–2.
- Produces: `AgentState.reading`, `.editing`, `.testing`, and `.cancelled`.
- Produces: internal `agentState(for activity: RelayActivity?) -> AgentState`.

- [ ] **Step 1: Write failing palette and adapter tests**

Extend `testApprovedPaletteIsStable`:

```swift
XCTAssertEqual(AgentState.reading.color, RGBColor(hex: 0x06B6D4))
XCTAssertEqual(AgentState.editing.color, RGBColor(hex: 0x14B8A6))
XCTAssertEqual(AgentState.testing.color, RGBColor(hex: 0xEC4899))
XCTAssertEqual(AgentState.cancelled.color, RGBColor(hex: 0xF97316))
```

Add adapter cases:

```swift
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
```

Extend the test helper with `activity: RelayActivity? = nil`.

- [ ] **Step 2: Run core domain and adapter tests and verify failure**

Run:

```bash
swift test --filter 'AgentStateTests|AgentAdapterTests'
```

Expected: FAIL because the four states and activity mapping do not exist.

- [ ] **Step 3: Add states, colors, and the shared mapping**

Add enum cases and colors in `AgentState.swift`:

```swift
case reading
case editing
case testing
case cancelled
```

```swift
case .reading: RGBColor(hex: 0x06B6D4)
case .editing: RGBColor(hex: 0x14B8A6)
case .testing: RGBColor(hex: 0xEC4899)
case .cancelled: RGBColor(hex: 0xF97316)
```

Add the shared helper in `AgentEventAdapter.swift`:

```swift
func agentState(for activity: RelayActivity?) -> AgentState {
    switch activity {
    case .reading: .reading
    case .editing: .editing
    case .testing: .testing
    case .working, nil: .working
    }
}
```

In Codex and Claude adapters, remove the static `PreToolUse: .working` entry and handle it before the dictionary lookup with `agentState(for: envelope.activity)`. In Cursor, do the same for `preToolUse` and `beforeShellExecution`.

Change only Cursor stop handling:

```swift
case "completed": .completed
case "aborted": .cancelled
case "error": .error
default: nil
```

- [ ] **Step 4: Run state and adapter tests**

Run:

```bash
swift test --filter 'AgentStateTests|AgentAdapterTests'
```

Expected: all selected tests PASS; legacy nil activity remains Working.

- [ ] **Step 5: Commit normalized states and adapters**

```bash
git add Sources/AgentLightCore/Domain/AgentState.swift Sources/AgentLightCore/Integrations/AgentEventAdapter.swift Sources/AgentLightCore/Integrations/CodexAdapter.swift Sources/AgentLightCore/Integrations/ClaudeCodeAdapter.swift Sources/AgentLightCore/Integrations/CursorAdapter.swift Tests/AgentLightCoreTests/AgentStateTests.swift Tests/AgentLightCoreTests/AgentAdapterTests.swift
git commit -m "feat: map agent activity states"
```

---

### Task 4: Give Cancelled an eight-second terminal lifecycle

**Files:**
- Modify: `Sources/AgentLightCore/Domain/AgentState.swift`
- Modify: `Sources/AgentLightCore/Coordination/SessionCoordinator.swift`
- Modify: `Sources/AgentLightCore/Coordination/MonitoringOrchestrator.swift`
- Modify: `Tests/AgentLightCoreTests/SessionCoordinatorTests.swift`
- Modify: `Tests/AgentLightCoreTests/MonitoringOrchestratorTests.swift`

**Interfaces:**
- Consumes: `AgentState.cancelled` from Task 3.
- Produces: `AgentState.isTerminal: Bool` for shared terminal checks.
- Preserves: Completed 8 seconds and Error 12 seconds.

- [ ] **Step 1: Write failing coordinator and timer tests**

Add a coordinator test that accepts Cancelled, expires its exact sequence, and confirms the session is removed. Also confirm expiry cannot remove a newer Reading event for the same source/session.

Add this orchestrator test beside the Completed/Error hold tests:

```swift
func testCancelledPhysicalHoldLastsEightSeconds() async throws {
    let clock = ManualClock()
    let light = RecordingLightController(attemptClock: clock)
    let orchestrator = makeOrchestrator(light: light, clock: clock)
    try await orchestrator.start()
    await orchestrator.accept(makeEvent(state: .cancelled))
    await clock.waitForSleepCount(1)

    await clock.advance(by: .seconds(1))
    await orchestrator.waitForLastApplied(desired(.cancelled))
    await clock.waitForSleepCount(2)

    await clock.advance(by: .milliseconds(7_999))
    await drainScheduledTasks()
    await XCTAssertAsyncEqual(await light.restoreCount(), 0)
    await XCTAssertAsyncEqual((await orchestrator.currentSnapshot()).state, .cancelled)

    await clock.advance(by: .milliseconds(1))
    await XCTAssertAsyncTrue(await eventually { await light.restoreCount() == 1 })
    await XCTAssertAsyncEqual((await orchestrator.currentSnapshot()).state, .idle)
}
```

Add a recovery validation test using a stored Cancelled command with an eight-second deadline, mirroring the existing Completed recovery test.

- [ ] **Step 2: Run focused coordination tests and verify failure**

Run:

```bash
swift test --filter 'SessionCoordinatorTests|MonitoringOrchestratorTests.testCancelled'
```

Expected: FAIL because Cancelled is not terminal and has no hold.

- [ ] **Step 3: Centralize terminal identity**

Add to `AgentState.swift` if not already added in Task 3:

```swift
var isTerminal: Bool {
    switch self {
    case .completed, .cancelled, .error: true
    default: false
    }
}
```

Replace both Completed/Error boolean expressions in `SessionCoordinator` with `event.state.isTerminal`.

- [ ] **Step 4: Add Cancelled to timer and recovery helpers**

Update both hold switches:

```swift
case .completed, .cancelled: .seconds(8) // Duration switch
case .error: .seconds(12)
```

```swift
case .completed, .cancelled: 8 // TimeInterval switch
case .error: 12
```

Update `maximumTerminalHold(for:)` to compare the command against Completed, Cancelled, and Error colors. Use a fixed state array so no terminal state is omitted:

```swift
for state in [AgentState.completed, .cancelled, .error] {
    if let color = state.color,
       command == DesiredLightState(color: color) {
        return terminalHoldInterval(for: state)
    }
}
return nil
```

- [ ] **Step 5: Run all coordination tests**

Run:

```bash
swift test --filter 'SessionCoordinatorTests|MonitoringOrchestratorTests'
```

Expected: all selected tests PASS, including existing concurrency, recovery, Completed, and Error cases.

- [ ] **Step 6: Commit cancellation lifecycle support**

```bash
git add Sources/AgentLightCore/Domain/AgentState.swift Sources/AgentLightCore/Coordination/SessionCoordinator.swift Sources/AgentLightCore/Coordination/MonitoringOrchestrator.swift Tests/AgentLightCoreTests/SessionCoordinatorTests.swift Tests/AgentLightCoreTests/MonitoringOrchestratorTests.swift
git commit -m "feat: add cancelled terminal lifecycle"
```

---

### Task 5: Present the new states accessibly in the menu UI

**Files:**
- Create: `Sources/AgentLightUI/Views/AgentStatePresentation.swift`
- Modify: `Sources/AgentLightUI/Views/AmbientBulbView.swift`
- Modify: `Sources/AgentLightUI/Views/MenuBarContentView.swift`
- Modify: `Tests/AgentLightUITests/ViewRenderingTests.swift`

**Interfaces:**
- Consumes: all `AgentState` cases from Task 3.
- Produces: internal `AgentState.displayName`, `.symbolName`, and `.bulbSymbolName`.

- [ ] **Step 1: Write failing presentation tests**

Add to `ViewRenderingTests`:

```swift
func testActivityStatePresentationIsExplicitAndAccessible() {
    let cases: [(AgentState, String, String, String)] = [
        (.reading, "Reading", "book.closed.fill", "book.closed.fill"),
        (.editing, "Editing", "pencil", "pencil"),
        (.testing, "Testing", "checkmark.seal.fill", "checkmark.seal.fill"),
        (.cancelled, "Cancelled", "xmark.octagon.fill", "xmark.octagon.fill")
    ]

    for (state, label, symbol, bulbSymbol) in cases {
        XCTAssertEqual(state.displayName, label)
        XCTAssertEqual(state.symbolName, symbol)
        XCTAssertEqual(state.bulbSymbolName, bulbSymbol)

        let hosting = host(AmbientBulbView(state: state))
        XCTAssertTrue(descendants(of: hosting).contains {
            $0.accessibilityIdentifier() == "ambientBulb.status"
                && $0.accessibilityValue() as? String == label
        })
    }
}
```

- [ ] **Step 2: Run the UI test and verify failure**

Run:

```bash
swift test --filter ViewRenderingTests.testActivityStatePresentationIsExplicitAndAccessible
```

Expected: FAIL because the shared presentation properties and new switch cases do not exist.

- [ ] **Step 3: Create one exhaustive presentation mapping**

Create `AgentStatePresentation.swift`:

```swift
import AgentLightCore

extension AgentState {
    var displayName: String {
        switch self {
        case .thinking: "Thinking"
        case .reading: "Reading"
        case .editing: "Editing"
        case .testing: "Testing"
        case .working: "Working"
        case .needsYou: "Needs You"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .error: "Error"
        case .idle: "Idle"
        }
    }

    var symbolName: String {
        switch self {
        case .thinking: "brain.head.profile"
        case .reading: "book.closed.fill"
        case .editing: "pencil"
        case .testing: "checkmark.seal.fill"
        case .working: "hammer.fill"
        case .needsYou: "person.crop.circle.badge.exclamationmark"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.octagon.fill"
        case .error: "exclamationmark.triangle.fill"
        case .idle: "moon.zzz"
        }
    }

    var bulbSymbolName: String {
        switch self {
        case .reading: "book.closed.fill"
        case .editing: "pencil"
        case .testing: "checkmark.seal.fill"
        case .cancelled: "xmark.octagon.fill"
        case .completed: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .idle: "lightbulb.slash"
        case .thinking, .working, .needsYou: "lightbulb.led.fill"
        }
    }
}
```

Remove the duplicate `displayName` extension and private bulb switch from `AmbientBulbView`; use `state.bulbSymbolName`. Remove the existing `AgentState.symbolName` extension from `MenuBarContentView`.

- [ ] **Step 4: Run UI and view-model tests**

Run:

```bash
swift test --filter 'ViewRenderingTests|AppViewModelTests'
```

Expected: all selected tests PASS and every `AgentState` switch is exhaustive.

- [ ] **Step 5: Commit UI presentation support**

```bash
git add Sources/AgentLightUI/Views/AgentStatePresentation.swift Sources/AgentLightUI/Views/AmbientBulbView.swift Sources/AgentLightUI/Views/MenuBarContentView.swift Tests/AgentLightUITests/ViewRenderingTests.swift
git commit -m "feat: present activity colors in menu"
```

---

### Task 6: Prove production-pipeline behavior and document the feature

**Files:**
- Create: `Tests/AgentLightCoreTests/Fixtures/codex-read.json`
- Create: `Tests/AgentLightCoreTests/Fixtures/claude-edit.json`
- Create: `Tests/AgentLightCoreTests/Fixtures/cursor-test.json`
- Create: `Tests/AgentLightCoreTests/Fixtures/cursor-cancelled.json`
- Modify: `Tests/AgentLightCoreTests/EndToEndPipelineTests.swift`
- Modify: `Tests/AgentLightCoreTests/AgentAdapterTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: relay categories, adapters, coordination, and colors from Tasks 1–5.
- Produces: sanitized production-pipeline fixtures and user-facing documentation.

- [ ] **Step 1: Add failing end-to-end fixture tests**

Each fixture is a version-1 `RelayEnvelope`, not raw hook input. Use only sanitized categories:

```json
{"version":1,"integrationID":"com.bbatchas.agentlight.hook.v1","source":"codex","event":"PreToolUse","sessionID":"fixture-codex-read","workspace":"Fixture","status":null,"emittedAtMilliseconds":4,"activity":"reading"}
```

Create equivalent Claude Editing, Cursor Testing, and Cursor `stop`/`aborted` fixtures. Add tests following the existing production pipeline helper:

```swift
func testCodexReadFixtureReachesFakeLightAsReadingThroughSocket() async throws {
    let applied = try await runFixtureThroughProductionPipeline(named: "codex-read")
    XCTAssertEqual(applied, DesiredLightState(color: try XCTUnwrap(AgentState.reading.color)))
}

func testClaudeEditFixtureReachesFakeLightAsEditingThroughSocket() async throws {
    let applied = try await runFixtureThroughProductionPipeline(named: "claude-edit")
    XCTAssertEqual(applied, DesiredLightState(color: try XCTUnwrap(AgentState.editing.color)))
}

func testCursorTestFixtureReachesFakeLightAsTestingThroughSocket() async throws {
    let applied = try await runFixtureThroughProductionPipeline(named: "cursor-test")
    XCTAssertEqual(applied, DesiredLightState(color: try XCTUnwrap(AgentState.testing.color)))
}

func testCursorCancelledFixtureReachesFakeLightAsCancelledThroughSocket() async throws {
    let applied = try await runFixtureThroughProductionPipeline(named: "cursor-cancelled")
    XCTAssertEqual(applied, DesiredLightState(color: try XCTUnwrap(AgentState.cancelled.color)))
}
```

- [ ] **Step 2: Run end-to-end tests and confirm fixture failures before adding files**

Run:

```bash
swift test --filter EndToEndPipelineTests
```

Expected: FAIL because the four fixture resources are absent.

- [ ] **Step 3: Add sanitized fixtures and update adapter fixture coverage**

Create the four JSON fixtures with no raw tool name or command fields. Add them to `testSanitizedFixturesDecodeAndMap` with expected states Reading, Editing, Testing, and Cancelled.

- [ ] **Step 4: Update README behavior and privacy text**

Add the approved palette table, state that activity classification is local and ephemeral, document fallback to blue, note Cursor-only explicit cancellation support, and add manual acceptance checks for read/edit/test/generic/cancelled transitions. Keep the existing warning that rapid states inside the one-second throttle window may collapse to the newest state.

- [ ] **Step 5: Run end-to-end and integration ownership tests**

Run:

```bash
swift test --filter 'EndToEndPipelineTests|AgentAdapterTests|IntegrationInstallerTests'
```

Expected: all selected tests PASS; existing hook event sets and ownership fingerprints remain valid.

- [ ] **Step 6: Commit fixtures and documentation**

```bash
git add Tests/AgentLightCoreTests/Fixtures/codex-read.json Tests/AgentLightCoreTests/Fixtures/claude-edit.json Tests/AgentLightCoreTests/Fixtures/cursor-test.json Tests/AgentLightCoreTests/Fixtures/cursor-cancelled.json Tests/AgentLightCoreTests/EndToEndPipelineTests.swift Tests/AgentLightCoreTests/AgentAdapterTests.swift README.md
git commit -m "test: cover activity color pipeline"
```

---

### Task 7: Complete automated and live-bulb verification

**Files:**
- Modify only if verification exposes a defect: files owned by Tasks 1–6, with a failing regression test added first.

**Interfaces:**
- Verifies: complete package, signed app bundle, relay privacy, real Tuya transitions, and clean repository state.

- [ ] **Step 1: Run the complete automated suite**

Run:

```bash
swift test --parallel
```

Expected: all test targets PASS with zero failures.

- [ ] **Step 2: Run release and bundle verification**

Run:

```bash
swift build -c release
./scripts/build-app.sh release
codesign --verify --deep --strict "build/Agent Light.app"
plutil -lint "build/Agent Light.app/Contents/Info.plist"
git diff --check
```

Expected: every command exits 0, code signing reports no error, plist reports `OK`, and `git diff --check` is silent.

- [ ] **Step 3: Inspect the built relay for privacy canaries**

Send sanitized raw hook samples directly to the built relay while monitoring only the recovery record. Confirm recovery JSON contains RGB state and terminal metadata but none of the injected tool or command canary strings:

```bash
! rg -n 'CANARY_TOOL|CANARY_COMMAND|tool_name|tool_input|command' "$HOME/Library/Application Support/Agent Light/monitoring-recovery-v1.json"
```

Expected: no matches. Do not print or persist actual user commands during this check.

- [ ] **Step 4: Run live-bulb color checks one at a time**

With the rebuilt app running and monitoring connected, invoke the bundled relay with a unique test session for:

- Codex `PreToolUse` + `Read` -> cyan Reading.
- Claude Code `PreToolUse` + `Edit` -> teal Editing.
- Cursor `beforeShellExecution` + `swift test` -> pink Testing.
- Codex `PreToolUse` + unknown tool -> blue Working.
- Cursor `stop` + `status: aborted` -> orange Cancelled for eight seconds, then baseline restoration unless a newer session wins.

Wait for each committed recovery state before sending the next event so the existing one-second throttle does not coalesce the manual checks. Record relay-exit and committed-command latency without recording hook contents.

- [ ] **Step 5: Verify the worktree and review the final diff**

Run:

```bash
git status --short
git diff HEAD~6 --check
git diff HEAD~6 --stat
git log --oneline -7
```

Expected: clean worktree; no whitespace errors; changes limited to the planned protocol, core, UI, tests, fixtures, and README files; six focused implementation commits follow the plan commit.

- [ ] **Step 6: Prepare the review handoff**

Report automated command results, live-bulb observed colors, measured latency, any unsupported source payloads that fell back to Working, and the unchanged one-second coalescing limitation. Describe the result as ready for review/testing, not production ready.
