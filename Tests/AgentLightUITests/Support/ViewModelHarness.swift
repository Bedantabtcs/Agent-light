import Foundation
import AgentLightCore
import AgentLightProtocol
@testable import AgentLightUI

enum HarnessCall: Equatable, Sendable {
    case verify, preview, install, repair, uninstall
    case loadCredentials, saveCredentials, deleteCredentials
    case enableLogin, disableLogin
    case startMonitoring, pauseMonitoring, resumeMonitoring, stopMonitoring
    case currentSnapshot, updates
}

enum HarnessFailurePoint: Sendable {
    case install, saveCredentials, enableLogin, startMonitoring
}

struct HarnessSensitiveError: Error, Sendable, CustomStringConvertible {
    let value: String
    init(_ value: String) { self.value = value }
    var description: String { value }
}

final class HarnessCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HarnessCall] = []

    var values: [HarnessCall] { lock.withLock { storage } }
    func append(_ call: HarnessCall) { lock.withLock { storage.append(call) } }
    func removeAll() { lock.withLock { storage.removeAll() } }
}

final class FakeCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let calls: HarnessCallRecorder
    private var stored: TuyaCredentials?
    private var saveError: (any Error & Sendable)?
    private var loadError: (any Error & Sendable)?
    private var deleteError: (any Error & Sendable)?
    private var saveErrors: [Int: any Error & Sendable] = [:]
    private var saves = 0
    private var deletes = 0

    init(calls: HarnessCallRecorder) { self.calls = calls }
    var saveCount: Int { lock.withLock { saves } }
    var deleteCount: Int { lock.withLock { deletes } }

    func save(_ credentials: TuyaCredentials) throws {
        calls.append(.saveCredentials)
        try lock.withLock {
            saves += 1
            if let error = saveErrors[saves] { throw error }
            if let saveError { throw saveError }
            stored = credentials
        }
    }

    func load() throws -> TuyaCredentials? {
        calls.append(.loadCredentials)
        return try lock.withLock {
            if let loadError { throw loadError }
            return stored
        }
    }

    func delete() throws {
        calls.append(.deleteCredentials)
        try lock.withLock {
            deletes += 1
            if let deleteError { throw deleteError }
            stored = nil
        }
    }

    func setSaveError(_ error: (any Error & Sendable)?) { lock.withLock { saveError = error } }
    func setSaveError(_ error: (any Error & Sendable)?, forCall call: Int) {
        lock.withLock { saveErrors[call] = error }
    }
    func setLoadError(_ error: (any Error & Sendable)?) { lock.withLock { loadError = error } }
    func setDeleteError(_ error: (any Error & Sendable)?) { lock.withLock { deleteError = error } }
    func seed(_ credentials: TuyaCredentials) { lock.withLock { stored = credentials } }
    func storedCredentials() -> TuyaCredentials? { lock.withLock { stored } }
}

actor FakeVerifier: TuyaConnectionVerifying {
    private let calls: HarnessCallRecorder
    private var errors: [Int: any Error & Sendable] = [:]
    private var blockedCalls: Set<Int> = []
    private var releases: [Int: CheckedContinuation<Void, Never>] = [:]
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var verifyCount = 0
    private(set) var lastCredentials: TuyaCredentials?

    init(calls: HarnessCallRecorder) { self.calls = calls }

    func verify(_ credentials: TuyaCredentials) async throws -> ResolvedLightCapabilities {
        calls.append(.verify)
        verifyCount += 1
        let call = verifyCount
        lastCredentials = credentials
        let ready = countWaiters.filter { verifyCount >= $0.0 }
        countWaiters.removeAll { verifyCount >= $0.0 }
        for waiter in ready { waiter.1.resume() }
        if blockedCalls.contains(call) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { releases[call] = $0 }
            } onCancel: {}
        }
        if let error = errors[call] { throw error }
        return Self.capabilities
    }

    func setError(_ error: any Error & Sendable, forCall call: Int) { errors[call] = error }
    func block(call: Int) { blockedCalls.insert(call) }
    func release(call: Int) { releases.removeValue(forKey: call)?.resume() }
    func waitForVerifyCount(_ expected: Int) async {
        if verifyCount >= expected { return }
        await withCheckedContinuation { countWaiters.append((expected, $0)) }
    }
    func capturedCredentials() -> TuyaCredentials? { lastCredentials }
    func count() -> Int { verifyCount }

    private static let capabilities: ResolvedLightCapabilities = {
        let specification = TuyaSpecification(
            category: "dj",
            functions: [
                TuyaDataPointSpecification(code: "switch_led", type: "Boolean", values: "{}"),
                TuyaDataPointSpecification(code: "colour_data_v2", type: "Json", values: "{}")
            ],
            status: []
        )
        do {
            return try TuyaCapabilityResolver.resolve(specification: specification)
        } catch {
            preconditionFailure("Static canary capability schema must resolve")
        }
    }()
}

actor FakeIntegrationInstaller: IntegrationInstalling {
    private let calls: HarnessCallRecorder
    private var installError: (any Error & Sendable)?
    private var previewError: (any Error & Sendable)?
    private var repairError: (any Error & Sendable)?
    private var uninstallError: (any Error & Sendable)?
    private var installBlocked = false
    private var blockedPreviewCalls: Set<Int> = []
    private var repairBlocked = false
    private var uninstallBlocked = false
    private var installRelease: CheckedContinuation<Void, Never>?
    private var previewReleases: [Int: CheckedContinuation<Void, Never>] = [:]
    private var repairRelease: CheckedContinuation<Void, Never>?
    private var uninstallRelease: CheckedContinuation<Void, Never>?
    private var installWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var previewWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var repairWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var uninstallWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var previewOwnership: [Bool] = [false, false, false]
    private var installOwnership: [IntegrationSourceOwnership] = [.fresh, .fresh, .fresh]
    private(set) var previewCount = 0
    private(set) var installCount = 0
    private(set) var repairCount = 0
    private(set) var uninstallCount = 0

    init(calls: HarnessCallRecorder) { self.calls = calls }

    func preview() async throws -> [IntegrationPreview] {
        calls.append(.preview)
        previewCount += 1
        let call = previewCount
        let ready = previewWaiters.filter { previewCount >= $0.0 }
        previewWaiters.removeAll { previewCount >= $0.0 }
        for waiter in ready { waiter.1.resume() }
        if blockedPreviewCalls.contains(call) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { previewReleases[call] = $0 }
            } onCancel: {}
        }
        if let previewError { throw previewError }
        return zip(AgentSource.allCases, previewOwnership).map { source, hadOwnedEntries in
            IntegrationPreview(
                source: source,
                path: "/CANARY/\(source.rawValue).json",
                before: "{}",
                after: "{}",
                hadOwnedEntries: hadOwnedEntries
            )
        }
    }

    func install() async throws {
        _ = try await performInstall()
    }

    func installWithReceipt() async throws -> IntegrationInstallReceipt {
        try await performInstall()
    }

    private func performInstall() async throws -> IntegrationInstallReceipt {
        calls.append(.install)
        installCount += 1
        let ready = installWaiters.filter { installCount >= $0.0 }
        installWaiters.removeAll { installCount >= $0.0 }
        for waiter in ready { waiter.1.resume() }
        if installBlocked { await withCheckedContinuation { installRelease = $0 } }
        if let installError { throw installError }
        return IntegrationInstallReceipt(
            sources: zip(AgentSource.allCases, installOwnership).map { source, ownership in
                IntegrationSourceReceipt(source: source, ownership: ownership)
            }
        )
    }

    func repair() async throws {
        calls.append(.repair)
        repairCount += 1
        let ready = repairWaiters.filter { repairCount >= $0.0 }
        repairWaiters.removeAll { repairCount >= $0.0 }
        for waiter in ready { waiter.1.resume() }
        if repairBlocked { await withCheckedContinuation { repairRelease = $0 } }
        if let repairError { throw repairError }
    }

    func uninstall() async throws {
        calls.append(.uninstall)
        uninstallCount += 1
        let ready = uninstallWaiters.filter { uninstallCount >= $0.0 }
        uninstallWaiters.removeAll { uninstallCount >= $0.0 }
        for waiter in ready { waiter.1.resume() }
        if uninstallBlocked { await withCheckedContinuation { uninstallRelease = $0 } }
        if let uninstallError { throw uninstallError }
    }

    func setInstallError(_ error: (any Error & Sendable)?) { installError = error }
    func setPreviewError(_ error: (any Error & Sendable)?) { previewError = error }
    func setRepairError(_ error: (any Error & Sendable)?) { repairError = error }
    func setUninstallError(_ error: (any Error & Sendable)?) { uninstallError = error }
    func setPreviewOwnership(_ ownership: [Bool]) {
        previewOwnership = ownership
        installOwnership = ownership.map { $0 ? .fullyPreexisting : .fresh }
    }
    func setInstallOwnership(_ ownership: [IntegrationSourceOwnership]) {
        installOwnership = ownership
    }
    func blockInstall() { installBlocked = true }
    func releaseInstall() { installBlocked = false; installRelease?.resume(); installRelease = nil }
    func waitForInstallCount(_ expected: Int) async {
        if installCount >= expected { return }
        await withCheckedContinuation { installWaiters.append((expected, $0)) }
    }
    func blockPreview(call: Int = 1) { blockedPreviewCalls.insert(call) }
    func releasePreview(call: Int = 1) {
        blockedPreviewCalls.remove(call)
        previewReleases.removeValue(forKey: call)?.resume()
    }
    func waitForPreviewCount(_ expected: Int) async {
        if previewCount >= expected { return }
        await withCheckedContinuation { previewWaiters.append((expected, $0)) }
    }
    func blockRepair() { repairBlocked = true }
    func releaseRepair() { repairBlocked = false; repairRelease?.resume(); repairRelease = nil }
    func waitForRepairCount(_ expected: Int) async {
        if repairCount >= expected { return }
        await withCheckedContinuation { repairWaiters.append((expected, $0)) }
    }
    func blockUninstall() { uninstallBlocked = true }
    func releaseUninstall() {
        uninstallBlocked = false
        uninstallRelease?.resume()
        uninstallRelease = nil
    }
    func waitForUninstallCount(_ expected: Int) async {
        if uninstallCount >= expected { return }
        await withCheckedContinuation { uninstallWaiters.append((expected, $0)) }
    }
    func counts() -> (preview: Int, install: Int, repair: Int, uninstall: Int) {
        (previewCount, installCount, repairCount, uninstallCount)
    }
}

actor FakeMonitor: MonitoringOrchestrating {
    private let calls: HarnessCallRecorder
    private var snapshot: MonitoringSnapshot
    private var startError: (any Error & Sendable)?
    private var resumeError: (any Error & Sendable)?
    private var pauseBlocked = false
    private var pauseRelease: CheckedContinuation<Void, Never>?
    private var pauseWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var resumeBlocked = false
    private var resumeRelease: CheckedContinuation<Void, Never>?
    private var resumeWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var stopBlocked = false
    private var stopRelease: CheckedContinuation<Void, Never>?
    private var stopWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var subscriptionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var terminationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var continuations: [UUID: AsyncStream<MonitoringSnapshot>.Continuation] = [:]
    private var historicalContinuations: [UUID: AsyncStream<MonitoringSnapshot>.Continuation] = [:]
    private(set) var startCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var stopCount = 0
    private(set) var updateSubscriptionCount = 0
    private(set) var terminationCount = 0
    private(set) var latestSubscriptionID: UUID?
    var activeSubscriptionCount: Int { continuations.count }

    init(calls: HarnessCallRecorder, initialSnapshot: MonitoringSnapshot) {
        self.calls = calls
        snapshot = initialSnapshot
    }

    func start() async throws {
        calls.append(.startMonitoring)
        startCount += 1
        if let startError { throw startError }
    }
    func accept(_ event: AgentEvent) async {}
    func pause() async {
        calls.append(.pauseMonitoring)
        pauseCount += 1
        let ready = pauseWaiters.filter { pauseCount >= $0.0 }
        pauseWaiters.removeAll { pauseCount >= $0.0 }
        for waiter in ready { waiter.1.resume() }
        if pauseBlocked { await withCheckedContinuation { pauseRelease = $0 } }
    }
    func resume() async throws {
        calls.append(.resumeMonitoring)
        resumeCount += 1
        let ready = resumeWaiters.filter { resumeCount >= $0.0 }
        resumeWaiters.removeAll { resumeCount >= $0.0 }
        for waiter in ready { waiter.1.resume() }
        if resumeBlocked { await withCheckedContinuation { resumeRelease = $0 } }
        if let resumeError { throw resumeError }
    }
    func stop() async {
        calls.append(.stopMonitoring)
        stopCount += 1
        let ready = stopWaiters.filter { stopCount >= $0.0 }
        stopWaiters.removeAll { stopCount >= $0.0 }
        for waiter in ready { waiter.1.resume() }
        if stopBlocked { await withCheckedContinuation { stopRelease = $0 } }
    }
    func reconnect() async {}
    func recoverIfNeeded() async throws {}
    func currentSnapshot() async -> MonitoringSnapshot { calls.append(.currentSnapshot); return snapshot }
    func updates() -> AsyncStream<MonitoringSnapshot> {
        calls.append(.updates)
        updateSubscriptionCount += 1
        let ready = subscriptionWaiters.filter { updateSubscriptionCount >= $0.0 }
        subscriptionWaiters.removeAll { updateSubscriptionCount >= $0.0 }
        for waiter in ready { waiter.1.resume() }
        let id = UUID()
        latestSubscriptionID = id
        return AsyncStream { continuation in
            continuations[id] = continuation
            historicalContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.terminate(id) }
            }
        }
    }

    func emit(_ value: MonitoringSnapshot) {
        snapshot = value
        for continuation in continuations.values { continuation.yield(value) }
    }
    func emit(_ value: MonitoringSnapshot, to id: UUID) { historicalContinuations[id]?.yield(value) }
    func finish(_ id: UUID) { historicalContinuations[id]?.finish() }
    func setStartError(_ error: (any Error & Sendable)?) { startError = error }
    func setResumeError(_ error: (any Error & Sendable)?) { resumeError = error }
    func blockPause() { pauseBlocked = true }
    func releasePause() { pauseBlocked = false; pauseRelease?.resume(); pauseRelease = nil }
    func waitForPauseCount(_ expected: Int) async {
        if pauseCount >= expected { return }
        await withCheckedContinuation { pauseWaiters.append((expected, $0)) }
    }
    func blockResume() { resumeBlocked = true }
    func releaseResume() { resumeBlocked = false; resumeRelease?.resume(); resumeRelease = nil }
    func waitForResumeCount(_ expected: Int) async {
        if resumeCount >= expected { return }
        await withCheckedContinuation { resumeWaiters.append((expected, $0)) }
    }
    func blockStop() { stopBlocked = true }
    func releaseStop() { stopBlocked = false; stopRelease?.resume(); stopRelease = nil }
    func waitForStopCount(_ expected: Int) async {
        if stopCount >= expected { return }
        await withCheckedContinuation { stopWaiters.append((expected, $0)) }
    }
    func waitForSubscriptionCount(_ expected: Int) async {
        if updateSubscriptionCount >= expected { return }
        await withCheckedContinuation { subscriptionWaiters.append((expected, $0)) }
    }
    func waitForTerminationCount(_ expected: Int) async {
        if terminationCount >= expected { return }
        await withCheckedContinuation { terminationWaiters.append((expected, $0)) }
    }
    func metrics() -> (
        start: Int,
        pause: Int,
        resume: Int,
        stop: Int,
        subscriptions: Int,
        terminations: Int,
        activeSubscriptions: Int,
        latestSubscriptionID: UUID?
    ) {
        (
            startCount,
            pauseCount,
            resumeCount,
            stopCount,
            updateSubscriptionCount,
            terminationCount,
            continuations.count,
            latestSubscriptionID
        )
    }
    private func terminate(_ id: UUID) {
        continuations[id] = nil
        terminationCount += 1
        let ready = terminationWaiters.filter { terminationCount >= $0.0 }
        terminationWaiters.removeAll { terminationCount >= $0.0 }
        for waiter in ready { waiter.1.resume() }
    }
}

@MainActor
final class WeakViewModelBox {
    weak var value: AppViewModel?
}

@MainActor
final class FakeLoginItem: LoginItemControlling {
    private let calls: HarnessCallRecorder
    var currentStatus: LoginItemStatus = .notRegistered
    var registerResult: LoginItemStatus = .enabled
    var disableResult: LoginItemStatus = .notRegistered
    var enableError: (any Error)?
    var disableError: (any Error)?
    private(set) var enableCount = 0
    private(set) var disableCount = 0

    init(calls: HarnessCallRecorder) { self.calls = calls }
    var enabled: Bool {
        get { currentStatus == .enabled }
        set { currentStatus = newValue ? .enabled : .notRegistered }
    }
    var approvalRequired: Bool {
        get { currentStatus == .requiresApproval }
        set { currentStatus = newValue ? .requiresApproval : .notRegistered }
    }
    func status() -> LoginItemStatus { currentStatus }
    func setEnabled(_ enabled: Bool) throws -> LoginItemTransition {
        let previous = status()
        calls.append(enabled ? .enableLogin : .disableLogin)
        if enabled { enableCount += 1 } else { disableCount += 1 }
        if enabled {
            if let enableError { throw enableError }
            let didRegister = previous == .notRegistered || previous == .notFound
            if didRegister { currentStatus = registerResult }
            return LoginItemTransition(
                previous: previous,
                current: currentStatus,
                didRegister: didRegister,
                didUnregister: false
            )
        }
        if let disableError { throw disableError }
        let didUnregister = previous == .enabled || previous == .requiresApproval
        if didUnregister { currentStatus = disableResult }
        return LoginItemTransition(
            previous: previous,
            current: status(),
            didRegister: false,
            didUnregister: didUnregister
        )
    }
}

@MainActor
final class ViewModelHarness {
    let calls: HarnessCallRecorder
    let credentials: FakeCredentialStore
    let integrations: FakeIntegrationInstaller
    let monitor: FakeMonitor
    let loginItem: FakeLoginItem
    let verifier: FakeVerifier
    let validDraft = ConnectionDraft(
        endpoint: "https://openapi.tuyaus.com",
        accessID: "CANARY_ACCESS_ID",
        accessSecret: "CANARY_ACCESS_SECRET",
        deviceID: "CANARY_DEVICE_ID"
    )
    let previousCredentials = TuyaCredentials(
        endpoint: canaryURL("https://openapi.tuyain.com"),
        accessID: "CANARY_PREVIOUS_ACCESS_ID",
        accessSecret: "CANARY_PREVIOUS_ACCESS_SECRET",
        deviceID: "CANARY_PREVIOUS_DEVICE_ID"
    )
    var freshInstallReceipt: IntegrationInstallReceipt {
        IntegrationInstallReceipt(
            sources: AgentSource.allCases.map {
                IntegrationSourceReceipt(source: $0, ownership: .fresh)
            }
        )
    }
    let viewModel: AppViewModel

    init(initialSnapshot: MonitoringSnapshot = MonitoringSnapshot(state: .idle, sessions: [], connection: .connected)) {
        let calls = HarnessCallRecorder()
        let credentials = FakeCredentialStore(calls: calls)
        let integrations = FakeIntegrationInstaller(calls: calls)
        let monitor = FakeMonitor(calls: calls, initialSnapshot: initialSnapshot)
        let loginItem = FakeLoginItem(calls: calls)
        let verifier = FakeVerifier(calls: calls)
        self.calls = calls
        self.credentials = credentials
        self.integrations = integrations
        self.monitor = monitor
        self.loginItem = loginItem
        self.verifier = verifier
        viewModel = AppViewModel(
            credentials: credentials,
            integrations: integrations,
            monitor: monitor,
            loginItem: loginItem,
            verifier: verifier
        )
    }

    func connectAndApprove() async {
        await viewModel.connect(using: validDraft)
        await viewModel.approveIntegrations()
    }

    func configureFailure(_ point: HarnessFailurePoint, error: any Error & Sendable) async {
        switch point {
        case .install: await integrations.setInstallError(error)
        case .saveCredentials: credentials.setSaveError(error)
        case .enableLogin: loginItem.enableError = error
        case .startMonitoring: await monitor.setStartError(error)
        }
    }
}

private func canaryURL(_ value: String) -> URL {
    guard let url = URL(string: value) else {
        preconditionFailure("Static canary URL must be valid")
    }
    return url
}

extension AgentEvent {
    static let canaryThinking = AgentEvent(
        source: .codex,
        sessionID: "CANARY_SESSION",
        workspace: "CANARY_WORKSPACE",
        state: .thinking,
        sequence: 1
    )
    static let canaryError = AgentEvent(
        source: .cursor,
        sessionID: "CANARY_ERROR_SESSION",
        workspace: nil,
        state: .error,
        sequence: 2
    )
}
