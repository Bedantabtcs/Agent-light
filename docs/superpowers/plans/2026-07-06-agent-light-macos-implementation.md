# Agent Light for macOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Build a native macOS menu-bar app that monitors local Codex, Claude Code, and Cursor lifecycle events and maps the newest agent state to a Tuya-connected Wipro bulb.

**Architecture:** A SwiftUI menu-bar executable depends on focused AgentLightUI, AgentLightCore, and AgentLightProtocol modules. Agent hooks invoke a separate fail-open relay executable, which sends sanitized datagrams to the app over a user-only Unix socket; the app normalizes events, arbitrates sessions, and sends deduplicated signed commands through a Tuya client.

**Tech Stack:** Swift 6.2, Swift Package Manager, SwiftUI, Observation, Foundation, Security, ServiceManagement, CryptoKit, Darwin sockets, XCTest.

## Global Constraints

- Target macOS 14 or later.
- Use the installed Xcode 26.1.1 and Swift 6.2.1 toolchain.
- Keep the application dependency-free; use Apple frameworks and Swift Package Manager only.
- Launch automatically at login after successful setup, with an in-app opt-out.
- Use strict Swift concurrency and explicit Sendable types.
- Store Tuya endpoint, Access ID, Access Secret, and Device ID in macOS Keychain.
- Never persist or transmit prompts, responses, reasoning, tool arguments, or source code.
- Never place credentials or tokens in command arguments, UserDefaults, project files, fixtures, or logs.
- Hooks must fail open and complete within the 200 ms delivery budget.
- Limit Tuya commands to one request per second; newest state wins.
- Preserve unrelated agent-hook configuration semantics.
- Do not add debug logging, dynamic evaluation, commented-out code, or force-casts.
- Use local commits after each task.
- Do not push, create a pull request, or perform any GitHub mutation until the user explicitly asks.

---

## File and Module Map

### Package and tooling

- Package.swift — products, targets, macOS floor, and strict-concurrency settings.
- Resources/AgentLight-Info.plist — app bundle identity and menu-bar-only configuration.
- scripts/build-app.sh — build and assemble Agent Light.app and its bundled relay.
- scripts/install-local.sh — copy the app to the user Applications directory without elevation.

### AgentLightProtocol

- Sources/AgentLightProtocol/AppIdentity.swift — stable bundle, integration, socket, and Keychain identifiers.
- Sources/AgentLightProtocol/AgentSource.swift — supported agent enum.
- Sources/AgentLightProtocol/RelayEnvelope.swift — sanitized, versioned relay message and validation.
- Sources/AgentLightProtocol/RelayInputSanitizer.swift — bounded hook input and allowlisted envelope creation.

### AgentLightCore

- Sources/AgentLightCore/Domain/AgentState.swift — shared states and approved palette.
- Sources/AgentLightCore/Domain/AgentEvent.swift — normalized event accepted by coordination.
- Sources/AgentLightCore/Domain/LightModels.swift — desired light state, baseline, capabilities, and errors.
- Sources/AgentLightCore/Coordination/SessionCoordinator.swift — newest-event arbitration and terminal holds.
- Sources/AgentLightCore/Coordination/MonitoringOrchestrator.swift — event-to-bulb pipeline and restoration.
- Sources/AgentLightCore/Relay/UnixDatagramServer.swift — user-only socket listener.
- Sources/AgentLightCore/Integrations/JSONValue.swift — typed JSON tree for safe config editing.
- Sources/AgentLightCore/Integrations/AgentEventAdapter.swift — adapter protocol.
- Sources/AgentLightCore/Integrations/CodexAdapter.swift — Codex payload mapping.
- Sources/AgentLightCore/Integrations/ClaudeCodeAdapter.swift — Claude Code payload mapping.
- Sources/AgentLightCore/Integrations/CursorAdapter.swift — Cursor payload mapping.
- Sources/AgentLightCore/Integrations/IntegrationInstaller.swift — preview, atomic merge, verify, repair, uninstall.
- Sources/AgentLightCore/Tuya/TuyaModels.swift — credentials, token, API envelopes, device DPs.
- Sources/AgentLightCore/Tuya/TuyaSigner.swift — canonical string and HMAC-SHA256 signing.
- Sources/AgentLightCore/Tuya/TuyaHTTPTransport.swift — URLSession abstraction.
- Sources/AgentLightCore/Tuya/TuyaClient.swift — token lifecycle, status, specification, and commands.
- Sources/AgentLightCore/Tuya/TuyaCapabilityResolver.swift — validated DP discovery.
- Sources/AgentLightCore/Tuya/LightColorMapper.swift — RGB-to-advertised-Tuya conversion.
- Sources/AgentLightCore/Persistence/CredentialStore.swift — Keychain-backed connection storage.
- Sources/AgentLightCore/Persistence/MonitoringRecoveryStore.swift — baseline and crash-recovery marker.
- Sources/AgentLightCore/Platform/LoginItemController.swift — SMAppService wrapper.
- Sources/AgentLightCore/Support/Clock.swift — deterministic time and sleep abstraction.

### AgentLightUI and executables

- Sources/AgentLightUI/AppViewModel.swift — onboarding, monitoring, integration, and error presentation state.
- Sources/AgentLightUI/Views/MenuBarContentView.swift — connected monitor.
- Sources/AgentLightUI/Views/OnboardingView.swift — Tuya and hook setup.
- Sources/AgentLightUI/Views/SettingsView.swift — Light, Integrations, and General sections.
- Sources/AgentLightUI/Views/AmbientBulbView.swift — approved Ambient Glass illustration and glow.
- Sources/AgentLightApp/AgentLightApp.swift — SwiftUI app entry and MenuBarExtra.
- Sources/AgentLightApp/AppEnvironment.swift — production dependency composition.
- Sources/AgentLightRelay/RelayMain.swift — hook executable entry.

### Tests and fixtures

- Tests/AgentLightProtocolTests/RelayEnvelopeTests.swift
- Tests/AgentLightCoreTests/SessionCoordinatorTests.swift
- Tests/AgentLightCoreTests/UnixDatagramTests.swift
- Tests/AgentLightCoreTests/AgentAdapterTests.swift
- Tests/AgentLightCoreTests/IntegrationInstallerTests.swift
- Tests/AgentLightCoreTests/TuyaSignerTests.swift
- Tests/AgentLightCoreTests/TuyaClientTests.swift
- Tests/AgentLightCoreTests/TuyaCapabilityResolverTests.swift
- Tests/AgentLightCoreTests/MonitoringOrchestratorTests.swift
- Tests/AgentLightCoreTests/CredentialStoreTests.swift
- Tests/AgentLightCoreTests/Support/TestDoubles.swift
- Tests/AgentLightUITests/AppViewModelTests.swift
- Tests/AgentLightUITests/Support/ViewModelHarness.swift
- Tests/AgentLightUITests/ViewRenderingTests.swift
- Tests/AgentLightCoreTests/Fixtures/*.json — sanitized lifecycle payloads only.

---

### Task 1: Swift package, application identity, and local bundle scaffolding

**Files:**
- Modify: .gitignore
- Create: Package.swift
- Create: Sources/AgentLightProtocol/AppIdentity.swift
- Create: Sources/AgentLightApp/AgentLightApp.swift
- Create: Sources/AgentLightRelay/RelayMain.swift
- Create: Tests/AgentLightProtocolTests/AppIdentityTests.swift

**Interfaces:**
- Produces: AppIdentity.bundleIdentifier, integrationIdentifier, socketPath, keychainService.
- Produces: buildable AgentLight and AgentLightRelay executable products.

- [ ] **Step 1: Create the package manifest and failing identity test**

Add SwiftPM and assembled app output to the existing ignore file:

~~~gitignore
.superpowers/
.build/
build/
~~~

~~~swift
// Package.swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentLight",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentLightProtocol", targets: ["AgentLightProtocol"]),
        .executable(name: "AgentLight", targets: ["AgentLightApp"]),
        .executable(name: "AgentLightRelay", targets: ["AgentLightRelay"])
    ],
    targets: [
        .target(name: "AgentLightProtocol"),
        .executableTarget(name: "AgentLightApp"),
        .executableTarget(name: "AgentLightRelay", dependencies: ["AgentLightProtocol"]),
        .testTarget(name: "AgentLightProtocolTests", dependencies: ["AgentLightProtocol"])
    ],
    swiftLanguageModes: [.v6]
)
~~~

~~~swift
// Tests/AgentLightProtocolTests/AppIdentityTests.swift
import XCTest
@testable import AgentLightProtocol

final class AppIdentityTests: XCTestCase {
    func testStableIdentifiers() {
        XCTAssertEqual(AppIdentity.bundleIdentifier, "com.bbatchas.agentlight")
        XCTAssertEqual(AppIdentity.integrationIdentifier, "com.bbatchas.agentlight.hook.v1")
        XCTAssertEqual(AppIdentity.keychainService, "com.bbatchas.agentlight.tuya")
        XCTAssertTrue(AppIdentity.socketPath.hasSuffix("/agent-light-v1.sock"))
    }
}
~~~

- [ ] **Step 2: Run the identity test and verify the red state**

Run: swift test --filter AppIdentityTests

Expected: compilation fails because AppIdentity is not defined.

- [ ] **Step 3: Add the minimal identity and executable entries**

~~~swift
// Sources/AgentLightProtocol/AppIdentity.swift
import Foundation

public enum AppIdentity {
    public static let bundleIdentifier = "com.bbatchas.agentlight"
    public static let integrationIdentifier = "com.bbatchas.agentlight.hook.v1"
    public static let keychainService = "com.bbatchas.agentlight.tuya"

    public static var applicationSupportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Agent Light", directoryHint: .isDirectory)
    }

    public static var socketPath: String {
        applicationSupportDirectory.appending(path: "agent-light-v1.sock").path
    }
}
~~~

~~~swift
// Sources/AgentLightApp/AgentLightApp.swift
import SwiftUI

@main
struct AgentLightApp: App {
    var body: some Scene {
        MenuBarExtra("Agent Light", systemImage: "lightbulb.led.fill") {
            Text("Agent Light")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
~~~

~~~swift
// Sources/AgentLightRelay/RelayMain.swift
import Foundation

@main
enum RelayMain {
    static func main() {
        exit(EXIT_SUCCESS)
    }
}
~~~

- [ ] **Step 4: Run package verification**

Run: swift test --filter AppIdentityTests && swift build

Expected: one passing identity test and successful debug builds for both executables.

- [ ] **Step 5: Commit locally**

~~~bash
git add .gitignore Package.swift Sources Tests
git commit -m "build: scaffold Agent Light Swift package"
~~~

### Task 2: Relay envelope, normalized states, and approved palette

**Files:**
- Modify: Package.swift
- Create: Sources/AgentLightProtocol/AgentSource.swift
- Create: Sources/AgentLightProtocol/RelayEnvelope.swift
- Create: Sources/AgentLightCore/Domain/AgentState.swift
- Create: Sources/AgentLightCore/Domain/AgentEvent.swift
- Create: Sources/AgentLightCore/Domain/LightModels.swift
- Create: Tests/AgentLightProtocolTests/RelayEnvelopeTests.swift
- Create: Tests/AgentLightCoreTests/AgentStateTests.swift

**Interfaces:**
- Produces: AgentSource, RelayEnvelope.validated(), AgentState, AgentEvent, RGBColor, DesiredLightState.
- Consumes: AppIdentity.integrationIdentifier.

- [ ] **Step 1: Write envelope validation and palette tests**

~~~swift
// Tests/AgentLightProtocolTests/RelayEnvelopeTests.swift
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
~~~

~~~swift
// Tests/AgentLightCoreTests/AgentStateTests.swift
import XCTest
@testable import AgentLightCore

final class AgentStateTests: XCTestCase {
    func testApprovedPaletteIsStable() {
        XCTAssertEqual(AgentState.thinking.color, RGBColor(hex: 0x8B5CF6))
        XCTAssertEqual(AgentState.working.color, RGBColor(hex: 0x3B82F6))
        XCTAssertEqual(AgentState.needsYou.color, RGBColor(hex: 0xF59E0B))
        XCTAssertEqual(AgentState.completed.color, RGBColor(hex: 0x22C55E))
        XCTAssertEqual(AgentState.error.color, RGBColor(hex: 0xEF4444))
    }
}
~~~

- [ ] **Step 2: Run the tests and verify failure**

Run: swift test --filter RelayEnvelopeTests

Expected: compilation fails because RelayEnvelope and AgentState are missing.

- [ ] **Step 3: Implement the protocol and domain types**

Add AgentLightCore as a library target and create its test target:

~~~swift
.library(name: "AgentLightCore", targets: ["AgentLightCore"])

.target(name: "AgentLightCore", dependencies: ["AgentLightProtocol"])
.testTarget(name: "AgentLightCoreTests", dependencies: ["AgentLightCore"])
~~~

~~~swift
// Sources/AgentLightProtocol/AgentSource.swift
public enum AgentSource: String, Codable, CaseIterable, Sendable {
    case codex
    case claudeCode
    case cursor
}
~~~

~~~swift
// Sources/AgentLightProtocol/RelayEnvelope.swift
import Foundation

public struct RelayEnvelope: Codable, Equatable, Sendable {
    public let version: Int
    public let integrationID: String
    public let source: AgentSource
    public let event: String
    public let sessionID: String
    public let workspace: String?
    public let status: String?
    public let emittedAtMilliseconds: Int64

    public init(
        version: Int,
        integrationID: String,
        source: AgentSource,
        event: String,
        sessionID: String,
        workspace: String?,
        status: String?,
        emittedAtMilliseconds: Int64
    ) {
        self.version = version
        self.integrationID = integrationID
        self.source = source
        self.event = event
        self.sessionID = sessionID
        self.workspace = workspace
        self.status = status
        self.emittedAtMilliseconds = emittedAtMilliseconds
    }

    public func validated() throws -> Self {
        guard version == 1 else { throw RelayValidationError.unsupportedVersion }
        guard integrationID == AppIdentity.integrationIdentifier else { throw RelayValidationError.invalidIntegration }
        guard !event.isEmpty, event.utf8.count <= 128 else { throw RelayValidationError.invalidEvent }
        guard !sessionID.isEmpty, sessionID.utf8.count <= 256 else { throw RelayValidationError.invalidSession }
        guard workspace?.utf8.count ?? 0 <= 512 else { throw RelayValidationError.invalidWorkspace }
        guard status?.utf8.count ?? 0 <= 64 else { throw RelayValidationError.invalidStatus }
        return self
    }
}

public enum RelayValidationError: Error, Equatable {
    case unsupportedVersion
    case invalidIntegration
    case invalidEvent
    case invalidSession
    case invalidWorkspace
    case invalidStatus
}
~~~

~~~swift
// Sources/AgentLightCore/Domain/AgentState.swift
public struct RGBColor: Codable, Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(hex: UInt32) {
        red = UInt8((hex >> 16) & 0xFF)
        green = UInt8((hex >> 8) & 0xFF)
        blue = UInt8(hex & 0xFF)
    }
}

public enum AgentState: String, Codable, Sendable {
    case thinking
    case working
    case needsYou
    case completed
    case error
    case idle

    public var color: RGBColor? {
        switch self {
        case .thinking: RGBColor(hex: 0x8B5CF6)
        case .working: RGBColor(hex: 0x3B82F6)
        case .needsYou: RGBColor(hex: 0xF59E0B)
        case .completed: RGBColor(hex: 0x22C55E)
        case .error: RGBColor(hex: 0xEF4444)
        case .idle: nil
        }
    }
}
~~~

~~~swift
// Sources/AgentLightCore/Domain/AgentEvent.swift
import AgentLightProtocol

public struct AgentEvent: Equatable, Sendable {
    public let source: AgentSource
    public let sessionID: String
    public let workspace: String?
    public let state: AgentState
    public let sequence: UInt64

    public init(source: AgentSource, sessionID: String, workspace: String?, state: AgentState, sequence: UInt64) {
        self.source = source
        self.sessionID = sessionID
        self.workspace = workspace
        self.state = state
        self.sequence = sequence
    }
}
~~~

~~~swift
// Sources/AgentLightCore/Domain/LightModels.swift
public struct DesiredLightState: Codable, Equatable, Sendable {
    public let color: RGBColor
    public let value: Double

    public init(color: RGBColor, value: Double = 0.8) {
        self.color = color
        self.value = min(max(value, 0), 1)
    }
}

public struct BulbBaseline: Codable, Equatable, Sendable {
    public let values: [String: String]
    public init(values: [String: String]) { self.values = values }
}
~~~

- [ ] **Step 4: Run protocol and domain tests**

Run: swift test --filter RelayEnvelopeTests && swift test --filter AgentStateTests

Expected: all RelayEnvelopeTests pass.

- [ ] **Step 5: Commit locally**

~~~bash
git add Package.swift Sources/AgentLightProtocol Sources/AgentLightCore/Domain Tests/AgentLightProtocolTests Tests/AgentLightCoreTests/AgentStateTests.swift
git commit -m "feat: add relay protocol and agent state model"
~~~

### Task 3: Deterministic multi-session coordination

**Files:**
- Create: Sources/AgentLightCore/Support/Clock.swift
- Create: Sources/AgentLightCore/Coordination/SessionCoordinator.swift
- Create: Tests/AgentLightCoreTests/SessionCoordinatorTests.swift

**Interfaces:**
- Consumes: AgentEvent and AgentState.
- Produces: SessionCoordinator.accept(_:), expireTerminalState(sessionID:sequence:), currentWinner(), snapshots().

- [ ] **Step 1: Write precedence and timer-cancellation tests**

~~~swift
import XCTest
import AgentLightProtocol
@testable import AgentLightCore

final class SessionCoordinatorTests: XCTestCase {
    func testNewestEventWinsAndOlderTerminalExpiryCannotOverrideIt() async {
        let coordinator = SessionCoordinator()
        await coordinator.accept(AgentEvent(source: .codex, sessionID: "a", workspace: "One", state: .completed, sequence: 1))
        await coordinator.accept(AgentEvent(source: .cursor, sessionID: "b", workspace: "Two", state: .working, sequence: 2))
        await coordinator.expireTerminalState(sessionID: "a", sequence: 1)
        let winner = await coordinator.currentWinner()
        XCTAssertEqual(winner?.sessionID, "b")
        XCTAssertEqual(winner?.state, .working)
    }

    func testTerminalExpiryFallsBackToNewestActiveSession() async {
        let coordinator = SessionCoordinator()
        await coordinator.accept(AgentEvent(source: .claudeCode, sessionID: "a", workspace: nil, state: .thinking, sequence: 1))
        await coordinator.accept(AgentEvent(source: .codex, sessionID: "b", workspace: nil, state: .completed, sequence: 2))
        await coordinator.expireTerminalState(sessionID: "b", sequence: 2)
        let winner = await coordinator.currentWinner()
        XCTAssertEqual(winner?.sessionID, "a")
    }
}
~~~

- [ ] **Step 2: Run the coordinator tests and verify failure**

Run: swift test --filter SessionCoordinatorTests

Expected: compilation fails because SessionCoordinator is missing.

- [ ] **Step 3: Implement the coordinator actor**

~~~swift
// Sources/AgentLightCore/Coordination/SessionCoordinator.swift
import AgentLightProtocol

public actor SessionCoordinator {
    private var sessions: [String: AgentEvent] = [:]

    public init() {}

    public func accept(_ event: AgentEvent) {
        guard event.sequence >= (sessions[event.sessionID]?.sequence ?? 0) else { return }
        if event.state == .idle {
            sessions.removeValue(forKey: event.sessionID)
        } else {
            sessions[event.sessionID] = event
        }
    }

    public func expireTerminalState(sessionID: String, sequence: UInt64) {
        guard let event = sessions[sessionID], event.sequence == sequence else { return }
        guard event.state == .completed || event.state == .error else { return }
        sessions.removeValue(forKey: sessionID)
    }

    public func currentWinner() -> AgentEvent? {
        sessions.values.max { left, right in left.sequence < right.sequence }
    }

    public func snapshots() -> [AgentEvent] {
        sessions.values.sorted { left, right in left.sequence > right.sequence }
    }

    public func reset() {
        sessions.removeAll()
    }
}
~~~

~~~swift
// Sources/AgentLightCore/Support/Clock.swift
public protocol AgentLightClock: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousAgentLightClock: AgentLightClock {
    private let clock = ContinuousClock()
    public init() {}
    public func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}
~~~

- [ ] **Step 4: Run the coordinator suite**

Run: swift test --filter SessionCoordinatorTests

Expected: both coordination tests pass.

- [ ] **Step 5: Commit locally**

~~~bash
git add Sources/AgentLightCore/Coordination Sources/AgentLightCore/Support Tests/AgentLightCoreTests/SessionCoordinatorTests.swift
git commit -m "feat: coordinate concurrent agent sessions"
~~~

### Task 4: Fail-open relay executable and Unix datagram transport

**Files:**
- Create: Sources/AgentLightCore/Relay/UnixDatagramServer.swift
- Modify: Sources/AgentLightRelay/RelayMain.swift
- Create: Sources/AgentLightProtocol/RelayInputSanitizer.swift
- Create: Tests/AgentLightCoreTests/UnixDatagramTests.swift
- Create: Tests/AgentLightProtocolTests/RelayEncodingTests.swift

**Interfaces:**
- Produces: UnixDatagramServer.start(handler:), stop(), UnixDatagramSender.send(_:to:).
- Produces: RelayInputSanitizer.makeEnvelope(arguments:input:nowMilliseconds:).
- Consumes: RelayEnvelope and AppIdentity.socketPath.

- [ ] **Step 1: Write datagram round-trip and sanitization tests**

~~~swift
import XCTest
@testable import AgentLightCore

final class UnixDatagramTests: XCTestCase {
    func testRoundTripReceivesOneDatagram() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString + ".sock").path
        let server = UnixDatagramServer(path: path)
        let received = expectation(description: "received")
        try await server.start { data in
            XCTAssertEqual(data, Data("event".utf8))
            received.fulfill()
        }
        try UnixDatagramSender.send(Data("event".utf8), to: path)
        await fulfillment(of: [received], timeout: 1)
        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
~~~

- [ ] **Step 2: Run relay tests and verify failure**

Run: swift test --filter UnixDatagramTests

Expected: compilation fails because UnixDatagramServer and UnixDatagramSender are missing.

- [ ] **Step 3: Implement bounded POSIX datagram transport and relay behavior**

Implementation requirements:

~~~swift
public actor UnixDatagramServer {
    public typealias Handler = @Sendable (Data) async -> Void
    public init(path: String)
    public func start(handler: @escaping Handler) throws
    public func stop()
}

public enum UnixDatagramSender {
    public static func send(_ data: Data, to path: String) throws
}
~~~

Use Darwin socket(AF_UNIX, SOCK_DGRAM, 0), unlink only the configured socket path, bind with mode 0600, read datagrams into a 2048-byte buffer, and close the descriptor on every exit path. Reject paths that do not fit sockaddr_un.sun_path. The server read loop must run in one owned Task and invoke the Sendable handler for each received datagram.

~~~swift
// Sources/AgentLightRelay/RelayInputSanitizer.swift
import AgentLightProtocol
import Foundation

public enum RelayInputSanitizer {
    public static let maximumInputBytes = 1_048_576

    public static func makeEnvelope(arguments: [String], input: Data, nowMilliseconds: Int64) throws -> RelayEnvelope {
        guard input.count <= maximumInputBytes else { throw RelayInputError.inputTooLarge }
        let options = try RelayArguments(arguments: arguments)
        let object = try JSONSerialization.jsonObject(with: input) as? [String: Any]
        let session = string(in: object, keys: ["session_id", "conversation_id", "thread_id"]) ?? options.sessionID
        guard let session else { throw RelayInputError.missingSession }
        let workspace = string(in: object, keys: ["cwd", "workspace_root", "workspace"])
            .map { URL(fileURLWithPath: $0).lastPathComponent }
        let status = string(in: object, keys: ["status", "reason", "notification_type"])
        return try RelayEnvelope(
            version: 1,
            integrationID: AppIdentity.integrationIdentifier,
            source: options.source,
            event: options.event,
            sessionID: session,
            workspace: workspace,
            status: status,
            emittedAtMilliseconds: nowMilliseconds
        ).validated()
    }

    private static func string(in object: [String: Any]?, keys: [String]) -> String? {
        for key in keys {
            if let value = object?[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}

struct RelayArguments {
    let source: AgentSource
    let event: String
    let sessionID: String?

    init(arguments: [String]) throws {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard value(after: "--integration-id") == AppIdentity.integrationIdentifier,
              let rawSource = value(after: "--source"),
              let source = AgentSource(rawValue: rawSource),
              let event = value(after: "--event"),
              !event.isEmpty else {
            throw RelayInputError.invalidArguments
        }
        self.source = source
        self.event = event
        sessionID = value(after: "--session-id")
    }
}

enum RelayInputError: Error { case inputTooLarge, missingSession, invalidArguments }
~~~

RelayMain must read at most 1 MiB plus one byte, encode only RelayEnvelope, reject encoded envelopes above 2048 bytes, attempt one local send, and exit EXIT_SUCCESS for success and every error. It must never print hook input or errors.

- [ ] **Step 4: Verify transport and relay builds**

Run: swift test --filter UnixDatagramTests && swift test --filter RelayEncodingTests && swift build --product AgentLightRelay

Expected: all relay tests pass and AgentLightRelay builds.

- [ ] **Step 5: Commit locally**

~~~bash
git add Sources/AgentLightCore/Relay Sources/AgentLightProtocol/RelayInputSanitizer.swift Sources/AgentLightRelay Tests/AgentLightCoreTests/UnixDatagramTests.swift Tests/AgentLightProtocolTests/RelayEncodingTests.swift
git commit -m "feat: add fail-open local event relay"
~~~

### Task 5: Agent adapters and atomic integration installer

**Files:**
- Modify: Package.swift
- Create: Sources/AgentLightCore/Integrations/JSONValue.swift
- Create: Sources/AgentLightCore/Integrations/AgentEventAdapter.swift
- Create: Sources/AgentLightCore/Integrations/CodexAdapter.swift
- Create: Sources/AgentLightCore/Integrations/ClaudeCodeAdapter.swift
- Create: Sources/AgentLightCore/Integrations/CursorAdapter.swift
- Create: Sources/AgentLightCore/Integrations/IntegrationInstaller.swift
- Create: Tests/AgentLightCoreTests/AgentAdapterTests.swift
- Create: Tests/AgentLightCoreTests/IntegrationInstallerTests.swift
- Create: Tests/AgentLightCoreTests/Fixtures/codex-user-prompt.json
- Create: Tests/AgentLightCoreTests/Fixtures/claude-permission.json
- Create: Tests/AgentLightCoreTests/Fixtures/cursor-stop-error.json

**Interfaces:**
- Produces: AgentEventAdapter.map(_:sequence:), IntegrationInstaller.preview(), install(), repair(), uninstall().
- Consumes: RelayEnvelope, AgentEvent, AppIdentity.integrationIdentifier.

- [ ] **Step 1: Add mapping and idempotent-merge tests**

~~~swift
import XCTest
import AgentLightProtocol
@testable import AgentLightCore

final class AgentAdapterTests: XCTestCase {
    func testApprovedMappings() throws {
        XCTAssertEqual(try CodexAdapter().map(envelope(source: .codex, event: "UserPromptSubmit"), sequence: 1).state, .thinking)
        XCTAssertEqual(try ClaudeCodeAdapter().map(envelope(source: .claudeCode, event: "PermissionRequest"), sequence: 2).state, .needsYou)
        XCTAssertEqual(try CursorAdapter().map(envelope(source: .cursor, event: "stop", status: "error"), sequence: 3).state, .error)
    }

    private func envelope(source: AgentSource, event: String, status: String? = nil) -> RelayEnvelope {
        RelayEnvelope(
            version: 1,
            integrationID: AppIdentity.integrationIdentifier,
            source: source,
            event: event,
            sessionID: "session",
            workspace: "Workspace",
            status: status,
            emittedAtMilliseconds: 1
        )
    }
}
~~~

~~~swift
final class IntegrationInstallerTests: XCTestCase {
    func testInstallIsIdempotentAndPreservesUnrelatedHooks() throws {
        let original = Data(#"{"hooks":{"Custom":[{"hooks":[{"type":"command","command":"custom"}]}]}}"#.utf8)
        let editor = IntegrationConfigEditor(source: .codex, relayPath: "/tmp/AgentLightRelay")
        let once = try editor.install(into: original)
        let twice = try editor.install(into: once)
        XCTAssertEqual(once, twice)
        XCTAssertTrue(String(decoding: twice, as: UTF8.self).contains("custom"))
        XCTAssertEqual(
            try JSONValue.decode(editor.uninstall(from: twice)),
            try JSONValue.decode(original)
        )
    }
}
~~~

- [ ] **Step 2: Run adapter and installer tests and verify failure**

Run: swift test --filter AgentAdapterTests && swift test --filter IntegrationInstallerTests

Expected: compilation fails because adapters and installer types are missing.

- [ ] **Step 3: Implement explicit mappings and source-specific hook manifests**

Update AgentLightCoreTests to process the sanitized fixture directory:

~~~swift
.testTarget(
    name: "AgentLightCoreTests",
    dependencies: ["AgentLightCore"],
    resources: [.process("Fixtures")]
)
~~~

~~~swift
public protocol AgentEventAdapter: Sendable {
    func map(_ envelope: RelayEnvelope, sequence: UInt64) throws -> AgentEvent
}

public enum AdapterError: Error, Equatable {
    case wrongSource
    case unsupportedEvent(String)
}

public struct IntegrationPreview: Equatable, Sendable {
    public let source: AgentSource
    public let path: String
    public let before: String
    public let after: String
}

public protocol IntegrationInstalling: Sendable {
    func preview() async throws -> [IntegrationPreview]
    func install() async throws
    func repair() async throws
    func uninstall() async throws
}
~~~

Mapping tables:

~~~swift
// CodexAdapter
let states: [String: AgentState] = [
    "UserPromptSubmit": .thinking,
    "PreToolUse": .working,
    "PostToolUse": .thinking,
    "PermissionRequest": .needsYou,
    "Stop": .completed
]

// ClaudeCodeAdapter
let states: [String: AgentState] = [
    "UserPromptSubmit": .thinking,
    "PreToolUse": .working,
    "PostToolUse": .thinking,
    "PermissionRequest": .needsYou,
    "Stop": .completed,
    "StopFailure": .error,
    "SessionEnd": .idle
]

// CursorAdapter
let states: [String: AgentState] = [
    "beforeSubmitPrompt": .thinking,
    "preToolUse": .working,
    "beforeShellExecution": .working,
    "postToolUse": .thinking,
    "afterShellExecution": .thinking,
    "sessionEnd": .idle
]
~~~

Cursor stop must map status completed to Completed and status aborted or error to Error. Claude Notification must map agent_needs_input to Needs You and agent_completed to Completed. Unknown events must throw AdapterError.unsupportedEvent without mutating session state.

Implement JSONValue as a Codable enum covering object, array, string, number, bool, and null. IntegrationConfigEditor must:

1. Decode an empty file as an empty object.
2. Preserve every unrelated JSON node.
3. Identify owned commands only by the exact integration argument --integration-id com.bbatchas.agentlight.hook.v1.
4. Add the documented event lists for each source.
5. Use source-appropriate nested hook schema.
6. Produce deterministic pretty-printed, sorted-key JSON.
7. Remove only owned commands and empty containers created by Agent Light.

IntegrationInstaller must write a mode-0600 sibling temporary file, fsync it, decode and verify it, atomically replace the destination, and delete rollback material. Preview returns before and after text without writing.

Use these complete sanitized fixtures:

~~~json
{"version":1,"integrationID":"com.bbatchas.agentlight.hook.v1","source":"codex","event":"UserPromptSubmit","sessionID":"fixture-codex","workspace":"Secure Access","status":null,"emittedAtMilliseconds":1}
~~~

~~~json
{"version":1,"integrationID":"com.bbatchas.agentlight.hook.v1","source":"claudeCode","event":"PermissionRequest","sessionID":"fixture-claude","workspace":"Secure Access","status":null,"emittedAtMilliseconds":2}
~~~

~~~json
{"version":1,"integrationID":"com.bbatchas.agentlight.hook.v1","source":"cursor","event":"stop","sessionID":"fixture-cursor","workspace":"Secure Access","status":"error","emittedAtMilliseconds":3}
~~~

- [ ] **Step 4: Verify mappings, merge behavior, and fixtures**

Run: swift test --filter AgentAdapterTests && swift test --filter IntegrationInstallerTests

Expected: all adapter and installer tests pass, including install-twice and uninstall restoration.

- [ ] **Step 5: Commit locally**

~~~bash
git add Package.swift Sources/AgentLightCore/Integrations Tests/AgentLightCoreTests
git commit -m "feat: install and map agent lifecycle hooks"
~~~

### Task 6: Tuya request signing, token lifecycle, and HTTP boundary

**Files:**
- Create: Sources/AgentLightCore/Tuya/TuyaModels.swift
- Create: Sources/AgentLightCore/Tuya/TuyaSigner.swift
- Create: Sources/AgentLightCore/Tuya/TuyaHTTPTransport.swift
- Create: Sources/AgentLightCore/Tuya/TuyaClient.swift
- Create: Tests/AgentLightCoreTests/TuyaSignerTests.swift
- Create: Tests/AgentLightCoreTests/TuyaClientTests.swift

**Interfaces:**
- Produces: TuyaCredentials, TuyaSigner.headers(for:credentials:token:timestamp:nonce:), TuyaClient.verify(), status(), send(commands:).
- Consumes: Foundation URLRequest and CryptoKit.

- [ ] **Step 1: Write canonical-signature and refresh-once tests**

~~~swift
import XCTest
@testable import AgentLightCore

final class TuyaSignerTests: XCTestCase {
    func testCanonicalStringAndUppercaseHMAC() throws {
        let request = TuyaSignedRequest(method: "GET", pathAndQuery: "/v1.0/token?grant_type=1", body: Data())
        let canonical = TuyaSigner.canonicalString(for: request)
        XCTAssertEqual(canonical, "GET\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n\n/v1.0/token?grant_type=1")
        let signature = TuyaSigner.signature(
            clientID: "client",
            secret: "secret",
            token: nil,
            timestamp: "1700000000000",
            nonce: "nonce",
            canonicalString: canonical
        )
        XCTAssertEqual(signature, signature.uppercased())
        XCTAssertEqual(signature.count, 64)
    }
}
~~~

TuyaClientTests must use a scripted HTTPTransport actor that returns: token success, business 401, refreshed token success, then command success. Assert exactly two token calls and two command calls; a second 401 must be surfaced without another refresh.

- [ ] **Step 2: Run Tuya tests and verify failure**

Run: swift test --filter TuyaSignerTests && swift test --filter TuyaClientTests

Expected: compilation fails because Tuya signing and client types are missing.

- [ ] **Step 3: Implement typed Tuya boundary**

~~~swift
public struct TuyaCredentials: Codable, Equatable, Sendable {
    public let endpoint: URL
    public let accessID: String
    public let accessSecret: String
    public let deviceID: String

    public init(endpoint: URL, accessID: String, accessSecret: String, deviceID: String) {
        self.endpoint = endpoint
        self.accessID = accessID
        self.accessSecret = accessSecret
        self.deviceID = deviceID
    }
}

public struct TuyaSignedRequest: Sendable {
    public let method: String
    public let pathAndQuery: String
    public let body: Data

    public init(method: String, pathAndQuery: String, body: Data) {
        self.method = method
        self.pathAndQuery = pathAndQuery
        self.body = body
    }
}

public protocol TuyaHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
~~~

~~~swift
import CryptoKit
import Foundation

public enum TuyaSigner {
    public static func canonicalString(for request: TuyaSignedRequest) -> String {
        let bodyHash = SHA256.hash(data: request.body).map { String(format: "%02x", $0) }.joined()
        return [request.method, bodyHash, "", request.pathAndQuery].joined(separator: "\n")
    }

    public static func signature(
        clientID: String,
        secret: String,
        token: String?,
        timestamp: String,
        nonce: String,
        canonicalString: String
    ) -> String {
        let payload = clientID + (token ?? "") + timestamp + nonce + canonicalString
        let authentication = HMAC<SHA256>.authenticationCode(
            for: Data(payload.utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        )
        return authentication.map { String(format: "%02X", $0) }.joined()
    }
}
~~~

TuyaClient must be an actor. It must cache the token until 60 seconds before expiry, acquire with GET /v1.0/token?grant_type=1, sign every request, refresh once on Tuya authentication failure, validate HTTP and Tuya success fields, and never include secret values in errors.

- [ ] **Step 4: Run Tuya signing and lifecycle tests**

Run: swift test --filter TuyaSignerTests && swift test --filter TuyaClientTests

Expected: canonical signing, cached token, one refresh, and bounded failure tests pass.

- [ ] **Step 5: Commit locally**

~~~bash
git add Sources/AgentLightCore/Tuya Tests/AgentLightCoreTests/TuyaSignerTests.swift Tests/AgentLightCoreTests/TuyaClientTests.swift
git commit -m "feat: add signed Tuya cloud client"
~~~

### Task 7: Capability discovery, color conversion, and restorable bulb state

**Files:**
- Modify: Sources/AgentLightCore/Domain/LightModels.swift
- Modify: Sources/AgentLightCore/Tuya/TuyaModels.swift
- Create: Sources/AgentLightCore/Tuya/TuyaCapabilityResolver.swift
- Create: Sources/AgentLightCore/Tuya/LightColorMapper.swift
- Create: Tests/AgentLightCoreTests/TuyaCapabilityResolverTests.swift

**Interfaces:**
- Produces: ResolvedLightCapabilities, TuyaCapabilityResolver.resolve(specification:status:), LightColorMapper.commands(for:capabilities:), baseline(from:).
- Consumes: DesiredLightState and Tuya DP models.

- [ ] **Step 1: Write v1/v2 color-schema and unsupported-device tests**

~~~swift
import XCTest
@testable import AgentLightCore

final class TuyaCapabilityResolverTests: XCTestCase {
    func testResolvesStandardColorV2AndBuildsHSVCommand() throws {
        let specification = fixtureSpecification(
            codes: ["switch_led", "work_mode", "colour_data_v2", "bright_value_v2"]
        )
        let capabilities = try TuyaCapabilityResolver.resolve(specification: specification)
        let commands = try LightColorMapper.commands(
            for: DesiredLightState(color: RGBColor(hex: 0x8B5CF6), value: 0.8),
            capabilities: capabilities
        )
        XCTAssertTrue(commands.contains { $0.code == "switch_led" && $0.value == .bool(true) })
        XCTAssertTrue(commands.contains { $0.code == "work_mode" && $0.value == .string("colour") })
        XCTAssertTrue(commands.contains { $0.code == "colour_data_v2" })
    }

    func testRejectsDeviceWithoutPowerOrColor() {
        XCTAssertThrowsError(try TuyaCapabilityResolver.resolve(specification: fixtureSpecification(codes: ["temp_value"])))
    }
}
~~~

- [ ] **Step 2: Run capability tests and verify failure**

Run: swift test --filter TuyaCapabilityResolverTests

Expected: compilation fails because resolver and mapper are missing.

- [ ] **Step 3: Implement schema-driven capability resolution**

~~~swift
public struct ResolvedLightCapabilities: Equatable, Sendable {
    public enum ColorEncoding: Equatable, Sendable {
        case hsvV2(code: String, hue: ClosedRange<Int>, saturation: ClosedRange<Int>, value: ClosedRange<Int>)
        case hsvLegacy(code: String)
    }

    public let powerCode: String
    public let modeCode: String?
    public let brightnessCode: String?
    public let temperatureCode: String?
    public let color: ColorEncoding
}

public enum CapabilityError: Error, Equatable {
    case missingPower
    case missingColor
    case invalidSchema(String)
}
~~~

The resolver must prefer colour_data_v2, then colour_data, validate ranges parsed from the specification, and reject unknown encodings. The mapper must convert approved RGB colors to HSV, scale saturation and value into advertised ranges, use 80% value, and emit one command array containing power, optional colour mode, color data, and optional brightness only when required by the schema.

Baseline capture must store the exact status JSON values for every resolved restorable code. Restore commands must reproduce those typed values without converting them through RGB.

- [ ] **Step 4: Run capability and color tests**

Run: swift test --filter TuyaCapabilityResolverTests

Expected: v2, legacy, range scaling, baseline round-trip, and unsupported-device tests pass.

- [ ] **Step 5: Commit locally**

~~~bash
git add Sources/AgentLightCore/Domain/LightModels.swift Sources/AgentLightCore/Tuya Tests/AgentLightCoreTests/TuyaCapabilityResolverTests.swift
git commit -m "feat: resolve and control Tuya light capabilities"
~~~

### Task 8: Monitoring orchestration, throttling, retries, and restoration

**Files:**
- Create: Sources/AgentLightCore/Coordination/MonitoringOrchestrator.swift
- Create: Sources/AgentLightCore/Persistence/MonitoringRecoveryStore.swift
- Create: Tests/AgentLightCoreTests/MonitoringOrchestratorTests.swift
- Create: Tests/AgentLightCoreTests/Support/TestDoubles.swift

**Interfaces:**
- Produces: MonitoringOrchestrator.start(), accept(_:), pause(), stop(), recoverIfNeeded().
- Consumes: SessionCoordinator, AgentLightClock, TuyaLightControlling, MonitoringRecoveryStoring.

- [ ] **Step 1: Write newest-wins, throttle, terminal-hold, and restore tests**

~~~swift
import XCTest
import AgentLightProtocol
@testable import AgentLightCore

final class MonitoringOrchestratorTests: XCTestCase {
    func testCoalescesRapidEventsAndSendsNewestState() async throws {
        let light = RecordingLightController()
        let clock = ManualClock()
        let orchestrator = MonitoringOrchestrator(light: light, recoveryStore: MemoryRecoveryStore(), clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(event(source: .codex, session: "a", state: .thinking, sequence: 1))
        await orchestrator.accept(event(source: .cursor, session: "b", state: .working, sequence: 2))
        await clock.advance(by: .seconds(1))
        XCTAssertEqual(await light.applied.last?.color, AgentState.working.color)
    }

    func testPauseRestoresCapturedBaselineOnce() async throws {
        let light = RecordingLightController()
        let orchestrator = MonitoringOrchestrator(light: light, recoveryStore: MemoryRecoveryStore(), clock: ImmediateClock())
        try await orchestrator.start()
        await orchestrator.pause()
        XCTAssertEqual(await light.restoreCount, 1)
    }
}
~~~

- [ ] **Step 2: Run orchestration tests and verify failure**

Run: swift test --filter MonitoringOrchestratorTests

Expected: compilation fails because MonitoringOrchestrator is missing.

- [ ] **Step 3: Implement the orchestration actor and recovery contract**

~~~swift
public protocol TuyaLightControlling: Sendable {
    func captureBaseline() async throws -> BulbBaseline
    func apply(_ state: DesiredLightState) async throws
    func currentStateMatchesLastCommand() async throws -> Bool
    func restore(_ baseline: BulbBaseline) async throws
}

public protocol MonitoringRecoveryStoring: Sendable {
    func load() async throws -> MonitoringRecoveryRecord?
    func save(_ record: MonitoringRecoveryRecord) async throws
    func clear() async throws
}

public struct MonitoringRecoveryRecord: Codable, Equatable, Sendable {
    public let baseline: BulbBaseline
    public let lastCommand: DesiredLightState?
}

public enum LightConnectionStatus: Equatable, Sendable {
    case connected
    case disconnected
}

public struct MonitoringSnapshot: Equatable, Sendable {
    public let state: AgentState
    public let sessions: [AgentEvent]
    public let connection: LightConnectionStatus
}

public protocol MonitoringOrchestrating: Sendable {
    func start() async throws
    func accept(_ event: AgentEvent) async
    func pause() async
    func resume() async throws
    func stop() async
    func recoverIfNeeded() async throws
    func updates() async -> AsyncStream<MonitoringSnapshot>
}
~~~

MonitoringOrchestrator must:

1. Capture and persist baseline before the first monitoring command.
2. Assign an increasing sequence to accepted normalized events.
3. Coalesce during a one-second command window and apply only the current winner.
4. Schedule Completed expiry at 8 seconds and Error expiry at 12 seconds.
5. Cancel an obsolete terminal task when a newer sequence reaches the same session.
6. Restore once when the coordinator has no winner, monitoring pauses, or the app stops.
7. Retry transient Tuya failures at 500 ms and 1 second with jitter, then surface a typed disconnected state.
8. On recovery, restore the persisted baseline only if the bulb still matches the last Agent Light command; otherwise capture the externally changed state as the new baseline.

- [ ] **Step 4: Run the orchestration suite**

Run: swift test --filter MonitoringOrchestratorTests

Expected: newest-wins, one-command-per-second, terminal timing, retry bounds, pause, and crash-recovery tests pass.

- [ ] **Step 5: Commit locally**

~~~bash
git add Sources/AgentLightCore/Coordination Sources/AgentLightCore/Persistence/MonitoringRecoveryStore.swift Tests/AgentLightCoreTests/MonitoringOrchestratorTests.swift Tests/AgentLightCoreTests/Support/TestDoubles.swift
git commit -m "feat: orchestrate monitored light state"
~~~

### Task 9: Keychain credentials and login-item control

**Files:**
- Create: Sources/AgentLightCore/Persistence/CredentialStore.swift
- Create: Sources/AgentLightCore/Platform/LoginItemController.swift
- Create: Tests/AgentLightCoreTests/CredentialStoreTests.swift

**Interfaces:**
- Produces: CredentialStoring.save/load/delete and LoginItemControlling.setEnabled/isEnabled.
- Consumes: TuyaCredentials and AppIdentity identifiers.

- [ ] **Step 1: Write Keychain round-trip and redaction tests**

~~~swift
import XCTest
import AgentLightProtocol
@testable import AgentLightCore

final class CredentialStoreTests: XCTestCase {
    func testRoundTripAndDelete() throws {
        let account = "test-" + UUID().uuidString
        let store = KeychainCredentialStore(service: AppIdentity.keychainService + ".tests", account: account)
        let credentials = TuyaCredentials(
            endpoint: URL(string: "https://openapi.tuyaus.com")!,
            accessID: "access-id",
            accessSecret: "access-secret",
            deviceID: "device-id"
        )
        try store.save(credentials)
        XCTAssertEqual(try store.load(), credentials)
        try store.delete()
        XCTAssertNil(try store.load())
    }
}
~~~

- [ ] **Step 2: Run credential tests and verify failure**

Run: swift test --filter CredentialStoreTests

Expected: compilation fails because KeychainCredentialStore is missing.

- [ ] **Step 3: Implement Security and ServiceManagement wrappers**

~~~swift
public protocol CredentialStoring: Sendable {
    func save(_ credentials: TuyaCredentials) throws
    func load() throws -> TuyaCredentials?
    func delete() throws
}

@MainActor
public protocol LoginItemControlling {
    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool) throws
}
~~~

KeychainCredentialStore must encode TuyaCredentials with JSONEncoder and store one generic-password item using kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly. Update must use SecItemUpdate; load must request one data result; delete treats errSecItemNotFound as success. Errors expose only OSStatus and operation, never input values.

LoginItemController must wrap SMAppService.mainApp, map enabled to status enabled, call register or unregister only on a state transition, and expose a fakeable protocol to UI tests.

- [ ] **Step 4: Run credential and package tests**

Run: swift test --filter CredentialStoreTests && swift test

Expected: Keychain tests pass and the full package remains green.

- [ ] **Step 5: Commit locally**

~~~bash
git add Sources/AgentLightCore/Persistence/CredentialStore.swift Sources/AgentLightCore/Platform Tests/AgentLightCoreTests/CredentialStoreTests.swift
git commit -m "feat: secure Tuya credentials and login launch"
~~~

### Task 10: Onboarding and monitoring view model

**Files:**
- Modify: Package.swift
- Create: Sources/AgentLightUI/AppViewModel.swift
- Create: Tests/AgentLightUITests/AppViewModelTests.swift
- Create: Tests/AgentLightUITests/Support/ViewModelHarness.swift

**Interfaces:**
- Produces: AppViewModel.phase, connectionStatus, sessions, currentState, connect(), approveIntegrations(), pause(), resume(), repairIntegrations().
- Consumes: CredentialStoring, IntegrationInstalling, MonitoringOrchestrating, LoginItemControlling.

- [ ] **Step 1: Write onboarding transition and failure tests**

~~~swift
import XCTest
@testable import AgentLightUI

@MainActor
final class AppViewModelTests: XCTestCase {
    func testSuccessfulConnectMovesToIntegrationReviewWithoutSavingEarly() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        XCTAssertEqual(harness.viewModel.phase, .integrationReview)
        XCTAssertEqual(harness.credentials.saveCount, 0)
    }

    func testApprovedIntegrationsPersistCredentialsEnableLoginAndMonitor() async {
        let harness = ViewModelHarness()
        await harness.viewModel.connect(using: harness.validDraft)
        await harness.viewModel.approveIntegrations()
        XCTAssertEqual(harness.viewModel.phase, .monitoring)
        XCTAssertEqual(harness.credentials.saveCount, 1)
        XCTAssertTrue(harness.loginItem.enabled)
        XCTAssertEqual(harness.monitor.startCount, 1)
    }
}
~~~

- [ ] **Step 2: Run view-model tests and verify failure**

Run: swift test --filter AppViewModelTests

Expected: compilation fails because AppViewModel is missing.

- [ ] **Step 3: Implement the main-actor state machine**

Add AgentLightUI as a library and test target, then make AgentLightApp depend on AgentLightCore and AgentLightUI:

~~~swift
.library(name: "AgentLightUI", targets: ["AgentLightUI"])

.target(name: "AgentLightUI", dependencies: ["AgentLightCore"])
.testTarget(name: "AgentLightUITests", dependencies: ["AgentLightUI", "AgentLightCore"])
.executableTarget(name: "AgentLightApp", dependencies: ["AgentLightCore", "AgentLightUI"])
~~~

~~~swift
import AgentLightCore
import Observation

public protocol TuyaConnectionVerifying: Sendable {
    func verify(_ credentials: TuyaCredentials) async throws -> ResolvedLightCapabilities
}

@MainActor
public protocol AppViewModeling: AnyObject {
    var phase: AppPhase { get }
    var currentState: AgentState { get }
    var sessions: [AgentEvent] { get }
    var presentedError: PresentationError? { get }
    func connect(using draft: ConnectionDraft) async
    func approveIntegrations() async
    func pause() async
    func resume() async
    func repairIntegrations() async
    func disconnect() async
    func observeMonitoring() async
}

public enum AppPhase: Equatable {
    case onboarding
    case verifying
    case integrationReview
    case monitoring
    case paused
}

public struct ConnectionDraft: Equatable {
    public var endpoint: String
    public var accessID: String
    public var accessSecret: String
    public var deviceID: String
}

public enum PresentationError: Error, Equatable {
    case invalidCredential
    case invalidEndpoint
    case unsupportedBulb
    case integrationConflict
    case bulbOffline
    case rateLimited
}
~~~

Create @MainActor @Observable final class AppViewModel conforming to AppViewModeling. Its initializer takes CredentialStoring, IntegrationInstalling, MonitoringOrchestrating, LoginItemControlling, and TuyaConnectionVerifying. Initialize phase to onboarding, currentState to idle, sessions to an empty array, and presentedError to nil.

connect must validate non-empty endpoint, Access ID, Access Secret, and Device ID, create temporary credentials, verify Tuya token and color capability, then obtain an integration preview. It must not save until approveIntegrations succeeds. approveIntegrations must install and verify hooks, save credentials, enable login, and start monitoring. observeMonitoring must consume monitor.updates() and assign state and sessions on the main actor. Every failure maps to invalidCredential, invalidEndpoint, unsupportedBulb, integrationConflict, bulbOffline, or rateLimited with a concrete recovery action in the view.

ViewModelHarness must provide deterministic in-memory implementations of CredentialStoring, IntegrationInstalling, MonitoringOrchestrating, LoginItemControlling, and the Tuya verification protocol. Each fake records call counts and exposes configured success or typed failure; it must never contain a real credential.

- [ ] **Step 4: Run the view-model suite**

Run: swift test --filter AppViewModelTests

Expected: onboarding, save-after-approval, pause, resume, repair, and typed-error tests pass.

- [ ] **Step 5: Commit locally**

~~~bash
git add Package.swift Sources/AgentLightUI/AppViewModel.swift Tests/AgentLightUITests/AppViewModelTests.swift Tests/AgentLightUITests/Support/ViewModelHarness.swift
git commit -m "feat: add Agent Light application state"
~~~

### Task 11: Ambient Glass menu-bar UI and settings

**Files:**
- Create: Sources/AgentLightUI/Views/AmbientBulbView.swift
- Create: Sources/AgentLightUI/Views/MenuBarContentView.swift
- Create: Sources/AgentLightUI/Views/OnboardingView.swift
- Create: Sources/AgentLightUI/Views/SettingsView.swift
- Modify: Sources/AgentLightApp/AgentLightApp.swift
- Create: Sources/AgentLightApp/AppEnvironment.swift
- Create: Tests/AgentLightUITests/ViewRenderingTests.swift

**Interfaces:**
- Consumes: AppViewModel.
- Produces: complete menu-bar, onboarding, monitor, and settings views with accessibility identifiers.

- [ ] **Step 1: Write rendering smoke tests for approved states**

~~~swift
import AppKit
import SwiftUI
import XCTest
@testable import AgentLightUI

@MainActor
final class ViewRenderingTests: XCTestCase {
    func testMonitoringViewRendersAtCompactSize() {
        let viewModel = PreviewViewModel.monitoring(state: .thinking)
        let hosting = NSHostingView(rootView: MenuBarContentView(viewModel: viewModel))
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 540)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.fittingSize.width, 380, accuracy: 1)
        XCTAssertGreaterThan(hosting.fittingSize.height, 400)
    }

    func testOnboardingViewRendersAtCompactSize() {
        let viewModel = PreviewViewModel.onboarding()
        let hosting = NSHostingView(rootView: OnboardingView(viewModel: viewModel))
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 540)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.fittingSize.width, 380, accuracy: 1)
        XCTAssertGreaterThan(hosting.fittingSize.height, 400)
    }
}
~~~

- [ ] **Step 2: Run rendering tests and verify failure**

Run: swift test --filter ViewRenderingTests

Expected: compilation fails because the SwiftUI views are missing.

- [ ] **Step 3: Implement the approved visual system**

~~~swift
import AgentLightCore
import SwiftUI

public struct AmbientBulbView: View {
    let state: AgentState

    public init(state: AgentState) {
        self.state = state
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(swiftUIColor.opacity(0.28))
                .frame(width: 122, height: 122)
                .blur(radius: 14)
            Image(systemName: "lightbulb.led.fill")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: swiftUIColor.opacity(0.9), radius: 18)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Light state")
        .accessibilityValue(state.rawValue)
    }

    private var swiftUIColor: Color {
        guard let rgb = state.color else { return Color.secondary }
        return Color(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }
}
~~~

MenuBarContentView must be 380 points wide, use deep navy-black material, show connection state, AmbientBulbView, current agent and workspace, a divider-separated session list, Pause or Resume, and Settings. OnboardingView must use SecureField for Access Secret, validate inline, show Keychain copy, and provide Verify & Connect. Integration review must show each config path and before/after summary before approval. SettingsView must contain Light, Integrations, and General sections without custom color or timing controls.

Every interactive control requires a stable accessibilityIdentifier. UI animation may pulse the glow slowly; it must not trigger bulb commands.

AppEnvironment must construct production Keychain, Tuya, installer, socket, orchestrator, and login-item dependencies. AgentLightApp must keep one State-owned AppViewModel and render MenuBarExtra with menuBarExtraStyle window.

Extend Tests/AgentLightUITests/Support/ViewModelHarness.swift with PreviewViewModel.monitoring(state:) and PreviewViewModel.onboarding(). Both factories must use in-memory fakes, never start networking, and return a fully initialized AppViewModel in the requested phase.

- [ ] **Step 4: Verify UI and full package**

Run: swift test --filter ViewRenderingTests && swift test && swift build

Expected: rendering smoke tests, full test suite, and both executables succeed.

- [ ] **Step 5: Commit locally**

~~~bash
git add Sources/AgentLightUI Sources/AgentLightApp Tests/AgentLightUITests
git commit -m "feat: build Ambient Glass menu-bar interface"
~~~

### Task 12: App bundle packaging, fixtures, and end-to-end acceptance

**Files:**
- Create: Resources/AgentLight-Info.plist
- Create: scripts/build-app.sh
- Create: scripts/install-local.sh
- Create: Tests/AgentLightCoreTests/EndToEndPipelineTests.swift
- Create: README.md

**Interfaces:**
- Produces: build/Agent Light.app with AgentLight and AgentLightRelay.
- Verifies: fixture to socket to adapter to coordinator to fake Tuya command.

- [ ] **Step 1: Write the end-to-end pipeline test**

~~~swift
import XCTest
import AgentLightProtocol
@testable import AgentLightCore

final class EndToEndPipelineTests: XCTestCase {
    func testCodexFixtureReachesFakeLightAsThinking() async throws {
        let fixture = try fixtureData(named: "codex-user-prompt")
        let envelope = try JSONDecoder().decode(RelayEnvelope.self, from: fixture).validated()
        let event = try CodexAdapter().map(envelope, sequence: 1)
        let light = RecordingLightController()
        let orchestrator = MonitoringOrchestrator(light: light, recoveryStore: MemoryRecoveryStore(), clock: ImmediateClock())
        try await orchestrator.start()
        await orchestrator.accept(event)
        XCTAssertEqual(await light.applied.last?.color, AgentState.thinking.color)
    }
}
~~~

- [ ] **Step 2: Run end-to-end test and verify the red state**

Run: swift test --filter EndToEndPipelineTests

Expected: test fails until sanitized fixtures and the final production composition satisfy the pipeline.

- [ ] **Step 3: Add deterministic packaging and local installation**

AgentLight-Info.plist must set:

~~~xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AgentLight</string>
    <key>CFBundleIdentifier</key><string>com.bbatchas.agentlight</string>
    <key>CFBundleName</key><string>Agent Light</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
~~~

~~~bash
#!/bin/bash
set -euo pipefail

CONFIGURATION="$1"
case "$CONFIGURATION" in
  debug|release) ;;
  *) echo "usage: $0 debug|release" >&2; exit 64 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$(cd "$ROOT" && swift build -c "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/build/Agent Light.app"
MACOS="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"
cp "$BIN_DIR/AgentLight" "$MACOS/AgentLight"
cp "$BIN_DIR/AgentLightRelay" "$MACOS/AgentLightRelay"
cp "$ROOT/Resources/AgentLight-Info.plist" "$APP/Contents/Info.plist"
chmod 0755 "$MACOS/AgentLight" "$MACOS/AgentLightRelay"
codesign --force --deep --sign - "$APP"
echo "$APP"
~~~

~~~bash
#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-app.sh" release
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Agent Light.app"
ditto "$ROOT/build/Agent Light.app" "$HOME/Applications/Agent Light.app"
open "$HOME/Applications/Agent Light.app"
~~~

Set both scripts to mode 0755. The build script must not read credentials. The install script must not register login launch itself; the approved in-app flow owns that state change.

README.md must document prerequisites, swift test, build-app.sh debug, install-local.sh, the three global hook paths, privacy boundaries, manual Tuya setup, recovery actions, and an explicit statement that no GitHub push occurs automatically.

- [ ] **Step 4: Run complete verification and manual checks**

Run:

~~~bash
swift test --parallel
swift build -c release
./scripts/build-app.sh release
codesign --verify --deep --strict "build/Agent Light.app"
plutil -lint "build/Agent Light.app/Contents/Info.plist"
git diff --check
~~~

Expected: all tests pass, release products build, codesign verification succeeds, plist reports OK, and git diff check is silent.

Manual checks:

1. Open build/Agent Light.app and confirm it appears only in the menu bar.
2. Enter deliberately invalid Tuya credentials and confirm nothing is saved.
3. Verify valid credentials, review hook changes, and approve installation.
4. Start local Codex, Claude Code, and Cursor sessions and confirm newest-event arbitration.
5. Trigger supported permission waits, completion, error, pause, quit, and reconnect behavior.
6. Confirm Completed holds 8 seconds, Error holds 12 seconds, and the original bulb state returns.
7. Close the app and invoke every installed hook; each hook must exit successfully within 200 ms.
8. Inspect the three config files and confirm unrelated hooks remain semantically unchanged.

Expected failure modes:

- Unsupported bulb schema stops setup before any light command.
- Cursor versions without an explicit wait signal do not show Needs You; they continue to report Thinking or Working.
- Offline Tuya service leaves the bulb untouched, retains only the newest desired state, and displays reconnect guidance.
- Missing app socket never blocks the source agent.

- [ ] **Step 5: Commit locally without pushing**

~~~bash
git add Resources scripts Tests README.md
git commit -m "test: verify Agent Light end-to-end workflow"
git status --short --branch
~~~

Expected: the branch is clean and remains local. Do not run git push or create a pull request.

---

## Final Readiness Gate

Before describing the implementation as ready for testing:

1. Run every command in Task 12 Step 4 from a clean checkout.
2. Record the real Wipro device's discovered power, mode, and color DP codes without recording credentials.
3. Confirm real-bulb restore behavior from both powered-on and powered-off baselines.
4. Confirm the relay timeout with the app closed for all three installed integrations.
5. Review git log and verify every commit is local.
6. Report unresolved limitations explicitly. Do not call the app production ready without a separate formal readiness assessment.
