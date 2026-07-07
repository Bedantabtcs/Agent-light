import Foundation
import XCTest
import AgentLightCore
import AgentLightUI
@testable import AgentLightApp

@MainActor
final class AppEnvironmentTests: XCTestCase {
    func testProductionVerifierResolvesCapabilityWithoutSendingCommands() async throws {
        let service = VerifierService()
        let verifier = ProductionTuyaConnectionVerifier { credentials in
            XCTAssertEqual(credentials.accessID, "CANARY_ACCESS_ID")
            return service
        }
        let credentials = TuyaCredentials(
            endpoint: try XCTUnwrap(URL(string: "https://openapi.tuyaus.com")),
            accessID: "CANARY_ACCESS_ID",
            accessSecret: "CANARY_ACCESS_SECRET",
            deviceID: "CANARY_DEVICE_ID"
        )

        let capabilities = try await verifier.verify(credentials)
        let sendCount = await service.sendCount()

        XCTAssertEqual(capabilities.powerCode, "switch_led")
        XCTAssertEqual(sendCount, 0)
    }

    func testProductionCompositionStartsLoadingWithoutExternalMutation() {
        let composition = ProductionAppComposition.make()

        XCTAssertEqual(composition.environment.status, .loading)
        XCTAssertEqual(composition.viewModel.phase, .onboarding)
    }

    func testRecoveryFinishesBeforeCredentialsLoadAndRelayAcceptance() async {
        let recorder = EnvironmentRecorder()
        let monitor = EnvironmentMonitor(recorder: recorder)
        await monitor.blockRecovery()
        let relay = EnvironmentRelay(recorder: recorder)
        let coordinator = EnvironmentCoordinator(recorder: recorder)
        let credentials = EnvironmentCredentials(recorder: recorder, stored: nil)
        let viewModel = EnvironmentViewModel(recorder: recorder)
        let environment = AppEnvironment(
            viewModel: viewModel,
            credentials: credentials,
            monitor: monitor,
            relay: relay,
            coordinator: coordinator,
            prepareStorage: { recorder.append(.prepare) }
        )

        let startup = Task { await environment.start() }
        await monitor.waitForRecovery()
        let relayStartsBeforeRecovery = await relay.count()
        let acceptedBeforeRecovery = await coordinator.count()
        XCTAssertEqual(relayStartsBeforeRecovery, 0)
        XCTAssertEqual(acceptedBeforeRecovery, 0)

        await monitor.releaseRecovery()
        await startup.value
        await relay.deliver(Data("CANARY_RELAY".utf8))

        XCTAssertEqual(
            recorder.values,
            [.prepare, .recover, .loadCredentials, .synchronize, .relayStart, .relayAccept]
        )
    }

    func testStoredCredentialsHydrateThroughApprovedViewModelFlowBeforeRelayStarts() async throws {
        let recorder = EnvironmentRecorder()
        let stored = TuyaCredentials(
            endpoint: try XCTUnwrap(URL(string: "https://openapi.tuyaus.com")),
            accessID: "CANARY_ACCESS_ID",
            accessSecret: "CANARY_ACCESS_SECRET",
            deviceID: "CANARY_DEVICE_ID"
        )
        let viewModel = EnvironmentViewModel(recorder: recorder)
        let environment = AppEnvironment(
            viewModel: viewModel,
            credentials: EnvironmentCredentials(recorder: recorder, stored: stored),
            monitor: EnvironmentMonitor(recorder: recorder),
            relay: EnvironmentRelay(recorder: recorder),
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: { recorder.append(.prepare) }
        )

        await environment.start()

        XCTAssertEqual(
            recorder.values,
            [.prepare, .recover, .loadCredentials, .synchronize, .connect, .approve, .relayStart]
        )
        XCTAssertEqual(viewModel.lastDraft?.accessSecret, "CANARY_ACCESS_SECRET")
    }

    func testStopClosesRelayBeforeDisconnectCleanup() async {
        let recorder = EnvironmentRecorder()
        let environment = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: EnvironmentCredentials(recorder: recorder, stored: nil),
            monitor: EnvironmentMonitor(recorder: recorder),
            relay: EnvironmentRelay(recorder: recorder),
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )

        await environment.stop()

        XCTAssertEqual(recorder.values, [.relayStop, .disconnect])
    }

    func testRelayStartupFailureCleansHydratedMonitoringOwnership() async throws {
        let recorder = EnvironmentRecorder()
        let stored = TuyaCredentials(
            endpoint: try XCTUnwrap(URL(string: "https://openapi.tuyaus.com")),
            accessID: "CANARY_ACCESS_ID",
            accessSecret: "CANARY_ACCESS_SECRET",
            deviceID: "CANARY_DEVICE_ID"
        )
        let relay = EnvironmentRelay(recorder: recorder)
        await relay.failStart()
        let environment = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: EnvironmentCredentials(recorder: recorder, stored: stored),
            monitor: EnvironmentMonitor(recorder: recorder),
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )

        await environment.start()

        XCTAssertEqual(environment.status, .failed)
        XCTAssertEqual(Array(recorder.values.suffix(2)), [.relayStop, .disconnect])
    }

    func testStopCancelsOwnedStartupBeforeRelayCanAcceptEvents() async {
        let recorder = EnvironmentRecorder()
        let monitor = EnvironmentMonitor(recorder: recorder)
        await monitor.blockRecovery()
        let relay = EnvironmentRelay(recorder: recorder)
        let environment = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: EnvironmentCredentials(recorder: recorder, stored: nil),
            monitor: monitor,
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )
        environment.launch()
        await monitor.waitForRecovery()

        let stopping = Task { await environment.stop() }
        await monitor.releaseRecovery()
        await stopping.value
        let relayStarts = await relay.count()

        XCTAssertEqual(relayStarts, 0)
        XCTAssertFalse(recorder.values.contains(.relayStart))
    }
}

private actor VerifierService: TuyaDeviceServicing {
    private var sends = 0
    func status() async throws -> [TuyaStatus] {
        [
            TuyaStatus(code: "switch_led", value: .bool(true)),
            TuyaStatus(code: "colour_data_v2", value: .string("{\"h\":0,\"s\":0,\"v\":500}"))
        ]
    }
    func specification() async throws -> TuyaSpecification {
        TuyaSpecification(
            category: "dj",
            functions: [
                TuyaDataPointSpecification(code: "switch_led", type: "Boolean", values: "{}"),
                TuyaDataPointSpecification(
                    code: "colour_data_v2",
                    type: "Json",
                    values: "{\"h\":{\"min\":0,\"max\":360,\"scale\":0,\"step\":1},\"s\":{\"min\":0,\"max\":1000,\"scale\":0,\"step\":1},\"v\":{\"min\":0,\"max\":1000,\"scale\":0,\"step\":1}}"
                )
            ],
            status: []
        )
    }
    func send(commands: [TuyaCommand]) async throws { sends += 1 }
    func sendCount() -> Int { sends }
}

private enum EnvironmentCall: Equatable, Sendable {
    case prepare, recover, loadCredentials, synchronize, connect, approve
    case relayStart, relayAccept, relayStop, disconnect
}

private final class EnvironmentRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [EnvironmentCall] = []
    var values: [EnvironmentCall] { lock.withLock { storage } }
    func append(_ value: EnvironmentCall) { lock.withLock { storage.append(value) } }
}

private final class EnvironmentCredentials: CredentialStoring, @unchecked Sendable {
    private let recorder: EnvironmentRecorder
    private let stored: TuyaCredentials?
    init(recorder: EnvironmentRecorder, stored: TuyaCredentials?) {
        self.recorder = recorder
        self.stored = stored
    }
    func save(_ credentials: TuyaCredentials) throws {}
    func load() throws -> TuyaCredentials? {
        recorder.append(.loadCredentials)
        return stored
    }
    func delete() throws {}
}

private actor EnvironmentMonitor: MonitoringOrchestrating {
    private let recorder: EnvironmentRecorder
    private var recoveryBlocked = false
    private var recoveryEntered = false
    private var recoveryRelease: CheckedContinuation<Void, Never>?
    private var recoveryWaiters: [CheckedContinuation<Void, Never>] = []
    init(recorder: EnvironmentRecorder) { self.recorder = recorder }
    func blockRecovery() { recoveryBlocked = true }
    func waitForRecovery() async {
        if recoveryEntered { return }
        await withCheckedContinuation { recoveryWaiters.append($0) }
    }
    func releaseRecovery() { recoveryBlocked = false; recoveryRelease?.resume(); recoveryRelease = nil }
    func recoverIfNeeded() async throws {
        recorder.append(.recover)
        recoveryEntered = true
        let waiters = recoveryWaiters
        recoveryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if recoveryBlocked { await withCheckedContinuation { recoveryRelease = $0 } }
    }
    func start() async throws {}
    func accept(_ event: AgentEvent) async {}
    func pause() async {}
    func resume() async throws {}
    func stop() async {}
    func reconnect() async {}
    func updates() async -> AsyncStream<MonitoringSnapshot> { AsyncStream { $0.finish() } }
    func currentSnapshot() async -> MonitoringSnapshot {
        MonitoringSnapshot(state: .idle, sessions: [], connection: .connected)
    }
}

private actor EnvironmentRelay: RelayServing {
    private let recorder: EnvironmentRecorder
    private var handler: (@Sendable (Data) async -> Void)?
    private(set) var startCount = 0
    private var shouldFailStart = false
    init(recorder: EnvironmentRecorder) { self.recorder = recorder }
    func start(handler: @escaping @Sendable (Data) async -> Void) async throws {
        startCount += 1
        self.handler = handler
        recorder.append(.relayStart)
        if shouldFailStart { throw EnvironmentRelayError.startFailed }
    }
    func stop() async { recorder.append(.relayStop) }
    func deliver(_ data: Data) async { await handler?(data) }
    func count() -> Int { startCount }
    func failStart() { shouldFailStart = true }
}

private enum EnvironmentRelayError: Error { case startFailed }

private actor EnvironmentCoordinator: RelayEventCoordinating {
    private let recorder: EnvironmentRecorder
    private(set) var acceptCount = 0
    init(recorder: EnvironmentRecorder) { self.recorder = recorder }
    func accept(_ data: Data) async {
        acceptCount += 1
        recorder.append(.relayAccept)
    }
    func count() -> Int { acceptCount }
}

@MainActor
private final class EnvironmentViewModel: AppViewModeling {
    private let recorder: EnvironmentRecorder
    var phase: AppPhase = .onboarding
    var connectionStatus: LightConnectionStatus = .disconnected
    var currentState: AgentState = .idle
    var sessions: [AgentEvent] = []
    var integrationPreviews: [IntegrationPreview] = []
    var presentedError: PresentationError?
    var outstandingObligations: Set<OutstandingObligation> = []
    private(set) var lastDraft: ConnectionDraft?
    init(recorder: EnvironmentRecorder) { self.recorder = recorder }
    func connect(using draft: ConnectionDraft) async {
        lastDraft = draft
        recorder.append(.connect)
        phase = .integrationReview
    }
    func approveIntegrations() async { recorder.append(.approve); phase = .monitoring }
    func pause() async {}
    func resume() async {}
    func repairIntegrations() async {}
    func disconnect() async { recorder.append(.disconnect) }
    func observeMonitoring() async {}
    func synchronizeOwnership() async { recorder.append(.synchronize) }
}
