import Foundation
import XCTest
import AppKit
import SwiftUI
import AgentLightCore
import AgentLightUI
@testable import AgentLightApp

@MainActor
final class AppEnvironmentTests: XCTestCase {
    func testStartupLoadingAndFailureRenderAtIntrinsicMenuWidthAndInvokeButtons() throws {
        let loading = NSHostingView(rootView: StartupStatusView(status: .loading, retry: {}, quit: {}))
        loading.layoutSubtreeIfNeeded()
        XCTAssertEqual(loading.fittingSize.width, 380, accuracy: 1)
        XCTAssertGreaterThan(loading.fittingSize.height, 200)

        var retryCount = 0
        var quitCount = 0
        let failure = NSHostingView(rootView: StartupStatusView(
            status: .failed,
            retry: { retryCount += 1 },
            quit: { quitCount += 1 }
        ))
        failure.layoutSubtreeIfNeeded()
        try appButton("app.startup.retry", in: failure).performClick(nil)
        try appButton("app.startup.quit", in: failure).performClick(nil)
        XCTAssertEqual(retryCount, 1)
        XCTAssertEqual(quitCount, 1)

        let resetFailure = NSHostingView(rootView: StartupStatusView(
            status: .credentialResetFailed,
            retry: { retryCount += 1 },
            quit: {}
        ))
        resetFailure.layoutSubtreeIfNeeded()
        let reset = try appButton("app.startup.retry", in: resetFailure)
        XCTAssertEqual(reset.title, "Reset Stored Credentials & Retry")
        reset.performClick(nil)
        XCTAssertEqual(retryCount, 2)
    }

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
            [.prepare, .recover, .synchronize, .loadCredentials, .relayStart, .relayAccept]
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
            [.prepare, .recover, .synchronize, .loadCredentials, .connect, .approve, .relayStart]
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
        environment.requestStart()
        await monitor.waitForRecovery()

        let stopping = Task { await environment.stop() }
        await monitor.releaseRecovery()
        await stopping.value
        let relayStarts = await relay.count()

        XCTAssertEqual(relayStarts, 0)
        XCTAssertFalse(recorder.values.contains(.relayStart))
    }

    func testConcurrentRetryRequestsShareOneOwnedRecoveryAndRelayStart() async {
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

        environment.requestStart()
        environment.requestStart()
        await monitor.waitForRecovery()
        let recoveriesWhileBlocked = await monitor.recoveryCount()
        XCTAssertEqual(recoveriesWhileBlocked, 1)

        await monitor.releaseRecovery()
        await environment.start()
        let finalRecoveries = await monitor.recoveryCount()
        let finalRelayStarts = await relay.count()
        XCTAssertEqual(finalRecoveries, 1)
        XCTAssertEqual(finalRelayStarts, 1)
    }

    func testEnvironmentDeinitCancelsBlockedRecoveryWithoutLaterRelayStart() async {
        let recorder = EnvironmentRecorder()
        let monitor = EnvironmentMonitor(recorder: recorder)
        await monitor.blockRecovery()
        let relay = EnvironmentRelay(recorder: recorder)
        weak var weakEnvironment: AppEnvironment?
        var environment: AppEnvironment? = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: EnvironmentCredentials(recorder: recorder, stored: nil),
            monitor: monitor,
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )
        weakEnvironment = environment
        environment?.requestStart()
        await monitor.waitForRecovery()

        environment = nil
        XCTAssertNil(weakEnvironment)
        await monitor.releaseRecovery()
        await monitor.waitForRecoveryCancellation()
        let relayStarts = await relay.count()

        XCTAssertEqual(relayStarts, 0)
    }

    func testStartCanRetryAfterOneShotFailure() async {
        let recorder = EnvironmentRecorder()
        let monitor = EnvironmentMonitor(recorder: recorder)
        let relay = EnvironmentRelay(recorder: recorder)
        await relay.failNextStart()
        let environment = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: EnvironmentCredentials(recorder: recorder, stored: nil),
            monitor: monitor,
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )

        await environment.start()
        XCTAssertEqual(environment.status, .failed)
        await environment.start()

        let recoveryCount = await monitor.recoveryCount()
        let relayCount = await relay.count()
        XCTAssertEqual(environment.status, .ready)
        XCTAssertEqual(recoveryCount, 2)
        XCTAssertEqual(relayCount, 2)
    }

    func testStartRequestedDuringBlockedStartupStopQueuesAfterCleanup() async {
        let recorder = EnvironmentRecorder()
        let monitor = EnvironmentMonitor(recorder: recorder)
        await monitor.blockRecovery()
        let relay = EnvironmentRelay(recorder: recorder)
        await relay.blockStop()
        let environment = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: EnvironmentCredentials(recorder: recorder, stored: nil),
            monitor: monitor,
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )
        environment.requestStart()
        await monitor.waitForRecovery()

        let stopping = Task { await environment.stop() }
        await monitor.releaseRecovery()
        await relay.waitForStop()
        environment.requestStart()
        await spinMainActor()

        let blockedRecoveryCount = await monitor.recoveryCount()
        let blockedRelayCount = await relay.count()
        XCTAssertEqual(blockedRecoveryCount, 1)
        XCTAssertEqual(blockedRelayCount, 0)

        await relay.releaseStop()
        await stopping.value
        await spinMainActor(until: { environment.status == .ready })

        XCTAssertEqual(environment.status, .ready)
        let finalRecoveryCount = await monitor.recoveryCount()
        let finalRelayCount = await relay.count()
        XCTAssertEqual(finalRecoveryCount, 2)
        XCTAssertEqual(finalRelayCount, 1)
    }

    func testStartRequestedDuringReadyStopRunsOnceAfterCleanup() async {
        let recorder = EnvironmentRecorder()
        let relay = EnvironmentRelay(recorder: recorder)
        await relay.blockStop()
        let environment = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: EnvironmentCredentials(recorder: recorder, stored: nil),
            monitor: EnvironmentMonitor(recorder: recorder),
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )
        await environment.start()

        let stopping = Task { await environment.stop() }
        await relay.waitForStop()
        environment.requestStart()
        environment.requestStart()
        let blockedRelayCount = await relay.count()
        XCTAssertEqual(blockedRelayCount, 1)

        await relay.releaseStop()
        await stopping.value
        await spinMainActor(until: { environment.status == .ready })

        XCTAssertEqual(environment.status, .ready)
        let finalRelayCount = await relay.count()
        XCTAssertEqual(finalRelayCount, 2)
    }

    func testReadyEnvironmentDeinitRunsDependencyOwnedShutdownExactlyOnce() async throws {
        let recorder = EnvironmentRecorder()
        let relay = EnvironmentRelay(recorder: recorder)
        await relay.blockStop()
        let viewModel = EnvironmentViewModel(recorder: recorder)
        await viewModel.blockDisconnect()
        let stored = TuyaCredentials(
            endpoint: try XCTUnwrap(URL(string: "https://openapi.tuyain.com")),
            accessID: "CANARY_ACCESS_ID",
            accessSecret: "CANARY_ACCESS_SECRET",
            deviceID: "CANARY_DEVICE_ID"
        )
        weak var weakEnvironment: AppEnvironment?
        var environment: AppEnvironment? = AppEnvironment(
            viewModel: viewModel,
            credentials: EnvironmentCredentials(recorder: recorder, stored: stored),
            monitor: EnvironmentMonitor(recorder: recorder),
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )
        weakEnvironment = environment
        await environment?.start()

        environment = nil
        XCTAssertNil(weakEnvironment)
        await spinMainActor(until: { recorder.values.contains(.relayStop) })
        let relayStopCount = recorder.values.filter { $0 == .relayStop }.count
        XCTAssertEqual(relayStopCount, 1)
        XCTAssertFalse(recorder.values.contains(.disconnect))
        guard relayStopCount == 1 else { return }

        await relay.releaseStop()
        await spinMainActor(until: { recorder.values.contains(.disconnect) })
        let disconnectCount = recorder.values.filter { $0 == .disconnect }.count
        XCTAssertEqual(disconnectCount, 1)
        guard disconnectCount == 1 else { return }
        await viewModel.releaseDisconnect()
        await spinMainActor()
        XCTAssertEqual(recorder.values.filter { $0 == .relayStop }.count, 1)
        XCTAssertEqual(recorder.values.filter { $0 == .disconnect }.count, 1)
    }

    func testMalformedAndLegacyCredentialsAreDeletedBeforeRelayStarts() async {
        for fixture in ["legacy arbitrary endpoint JSON", "malformed bytes"] {
            let recorder = EnvironmentRecorder()
            let credentials = EnvironmentCredentials(
                recorder: recorder,
                stored: nil,
                malformed: true
            )
            let relay = EnvironmentRelay(recorder: recorder)
            let viewModel = EnvironmentViewModel(recorder: recorder)
            let environment = AppEnvironment(
                viewModel: viewModel,
                credentials: credentials,
                monitor: EnvironmentMonitor(recorder: recorder),
                relay: relay,
                coordinator: EnvironmentCoordinator(recorder: recorder),
                prepareStorage: {}
            )

            await environment.start()

            XCTAssertEqual(environment.status, .ready, fixture)
            XCTAssertEqual(viewModel.phase, .onboarding, fixture)
            XCTAssertEqual(recorder.values.filter { $0 == .deleteCredentials }.count, 1, fixture)
            let relayCount = await relay.count()
            XCTAssertEqual(relayCount, 1, fixture)
            XCTAssertFalse(recorder.values.contains(.connect), fixture)
        }
    }

    func testMalformedCredentialDeleteFailureShowsResetRetryThenRecovers() async {
        let recorder = EnvironmentRecorder()
        let credentials = EnvironmentCredentials(
            recorder: recorder,
            stored: nil,
            malformed: true,
            deleteFailures: 1
        )
        let relay = EnvironmentRelay(recorder: recorder)
        let environment = AppEnvironment(
            viewModel: EnvironmentViewModel(recorder: recorder),
            credentials: credentials,
            monitor: EnvironmentMonitor(recorder: recorder),
            relay: relay,
            coordinator: EnvironmentCoordinator(recorder: recorder),
            prepareStorage: {}
        )

        await environment.start()
        XCTAssertEqual(environment.status, .credentialResetFailed)
        let firstRelayCount = await relay.count()
        XCTAssertEqual(firstRelayCount, 0)

        await environment.start()
        XCTAssertEqual(environment.status, .ready)
        XCTAssertEqual(recorder.values.filter { $0 == .deleteCredentials }.count, 2)
        let finalRelayCount = await relay.count()
        XCTAssertEqual(finalRelayCount, 1)
    }
}

@MainActor
private func spinMainActor(
    until condition: (@MainActor () -> Bool)? = nil
) async {
    for _ in 0..<100 {
        if condition?() == true { return }
        await Task.yield()
    }
}

@MainActor
private func appButton(_ identifier: String, in view: NSView) throws -> NSButton {
    try XCTUnwrap(
        appDescendants(of: view)
            .compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == identifier }
    )
}

@MainActor
private func appDescendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + appDescendants(of: $0) }
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
    case prepare, recover, loadCredentials, deleteCredentials, synchronize, connect, approve
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
    private let lock = NSLock()
    private var stored: TuyaCredentials?
    private var malformed: Bool
    private var remainingDeleteFailures: Int
    init(
        recorder: EnvironmentRecorder,
        stored: TuyaCredentials?,
        malformed: Bool = false,
        deleteFailures: Int = 0
    ) {
        self.recorder = recorder
        self.stored = stored
        self.malformed = malformed
        remainingDeleteFailures = deleteFailures
    }
    func save(_ credentials: TuyaCredentials) throws {}
    func load() throws -> TuyaCredentials? {
        recorder.append(.loadCredentials)
        return try lock.withLock {
            if malformed { throw CredentialStoreError.malformedData }
            return stored
        }
    }
    func delete() throws {
        recorder.append(.deleteCredentials)
        try lock.withLock {
            if remainingDeleteFailures > 0 {
                remainingDeleteFailures -= 1
                throw CredentialStoreError.security(operation: .delete, status: -1)
            }
            malformed = false
            stored = nil
        }
    }
}

private actor EnvironmentMonitor: MonitoringOrchestrating {
    private let recorder: EnvironmentRecorder
    private var recoveryBlocked = false
    private var recoveryEntered = false
    private var recoveries = 0
    private var cancellationCount = 0
    private var recoveryRelease: CheckedContinuation<Void, Never>?
    private var recoveryWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    init(recorder: EnvironmentRecorder) { self.recorder = recorder }
    func blockRecovery() { recoveryBlocked = true }
    func waitForRecovery() async {
        if recoveryEntered { return }
        await withCheckedContinuation { recoveryWaiters.append($0) }
    }
    func releaseRecovery() { recoveryBlocked = false; recoveryRelease?.resume(); recoveryRelease = nil }
    func recoverIfNeeded() async throws {
        recorder.append(.recover)
        recoveries += 1
        recoveryEntered = true
        let waiters = recoveryWaiters
        recoveryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if recoveryBlocked {
            await withTaskCancellationHandler {
                await withCheckedContinuation { recoveryRelease = $0 }
            } onCancel: {
                Task { await self.recordRecoveryCancellation() }
            }
        }
        try Task.checkCancellation()
    }
    func recoveryCount() -> Int { recoveries }
    func waitForRecoveryCancellation() async {
        if cancellationCount > 0 { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }
    private func recordRecoveryCancellation() {
        cancellationCount += 1
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
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
    private var remainingStartFailures = 0
    private let stopGate = EnvironmentGate()
    init(recorder: EnvironmentRecorder) { self.recorder = recorder }
    func start(handler: @escaping @Sendable (Data) async -> Void) async throws {
        startCount += 1
        self.handler = handler
        recorder.append(.relayStart)
        if remainingStartFailures > 0 {
            remainingStartFailures -= 1
            throw EnvironmentRelayError.startFailed
        }
    }
    func stop() async {
        recorder.append(.relayStop)
        await stopGate.enter()
    }
    func deliver(_ data: Data) async { await handler?(data) }
    func count() -> Int { startCount }
    func failStart() { remainingStartFailures = .max }
    func failNextStart() { remainingStartFailures += 1 }
    func blockStop() async { await stopGate.block() }
    func waitForStop() async { await stopGate.waitForEntry() }
    func releaseStop() async { await stopGate.release() }
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
    private let disconnectGate = EnvironmentGate()
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
    func disconnect() async {
        recorder.append(.disconnect)
        await disconnectGate.enter()
    }
    func observeMonitoring() async {}
    func synchronizeOwnership() async { recorder.append(.synchronize) }
    func blockDisconnect() async { await disconnectGate.block() }
    func waitForDisconnect() async { await disconnectGate.waitForEntry() }
    func releaseDisconnect() async { await disconnectGate.release() }
}

private actor EnvironmentGate {
    private var isBlocked = false
    private var entryCount = 0
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func block() { isBlocked = true }

    func enter() async {
        entryCount += 1
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard isBlocked else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitForEntry() async {
        if entryCount > 0 { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        isBlocked = false
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
