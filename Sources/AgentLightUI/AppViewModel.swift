import Foundation
import Observation
import AgentLightCore

public protocol TuyaConnectionVerifying: Sendable {
    func verify(_ credentials: TuyaCredentials) async throws -> ResolvedLightCapabilities
}

@MainActor
public protocol AppViewModeling: AnyObject, Sendable {
    var phase: AppPhase { get }
    var connectionStatus: LightConnectionStatus { get }
    var currentState: AgentState { get }
    var sessions: [AgentEvent] { get }
    var integrationPreviews: [IntegrationPreview] { get }
    var presentedError: PresentationError? { get }
    var outstandingObligations: Set<OutstandingObligation> { get }
    var loginItemStatus: LoginItemStatus { get }
    var maskedAccessID: String? { get }
    var maskedDeviceID: String? { get }
    var repairPreviews: [IntegrationPreview] { get }
    var integrationInstalled: Bool { get }
    var integrationStatus: IntegrationInstallationStatus { get }
    var codexTrustStatus: IntegrationTrustStatus { get }
    var monitoringActive: Bool { get }
    func connect(using draft: ConnectionDraft) async
    func approveIntegrations() async
    func pause() async
    func resume() async
    func repairIntegrations() async
    func shutdownMonitoring() async
    func disconnect() async
    func observeMonitoring() async
    func synchronizeOwnership() async
    func requestLaunchAtLogin() async
    func confirmCodexTrust()
    func reconnect() async
    func previewIntegrationRepair() async
    func uninstallIntegrations() async
    func replaceDevice() async
    func setMonitoringEnabled(_ enabled: Bool) async
    func resetOwnershipReceipt() async
}

public extension AppViewModeling {
    func synchronizeOwnership() async {}
    var loginItemStatus: LoginItemStatus { .unknown }
    func requestLaunchAtLogin() async {}
    func confirmCodexTrust() {}
    var maskedAccessID: String? { nil }
    var maskedDeviceID: String? { nil }
    var repairPreviews: [IntegrationPreview] { [] }
    var integrationInstalled: Bool { false }
    var integrationStatus: IntegrationInstallationStatus { .notInstalled }
    var codexTrustStatus: IntegrationTrustStatus { .notRequired }
    var monitoringActive: Bool { false }
    func reconnect() async {}
    func previewIntegrationRepair() async {}
    func uninstallIntegrations() async {}
    func replaceDevice() async {}
    func setMonitoringEnabled(_ enabled: Bool) async {}
    func resetOwnershipReceipt() async {}
}

public enum AppPhase: Equatable, Sendable {
    case onboarding
    case verifying
    case integrationReview
    case approving
    case monitoring
    case paused
    case repairRequired
}

public enum IntegrationInstallationStatus: Equatable, Sendable {
    case notInstalled
    case installed
    case needsRepair

    public var displayName: String {
        switch self {
        case .notInstalled: "Not Installed"
        case .installed: "Installed"
        case .needsRepair: "Needs Repair"
        }
    }
}

public struct ConnectionDraft: Equatable, Sendable {
    public var endpoint: String
    public var accessID: String
    public var accessSecret: String
    public var deviceID: String

    public init(endpoint: String, accessID: String, accessSecret: String, deviceID: String) {
        self.endpoint = endpoint
        self.accessID = accessID
        self.accessSecret = accessSecret
        self.deviceID = deviceID
    }
}

public enum PresentationError: Error, Equatable, Sendable {
    case invalidCredential
    case invalidEndpoint
    case unsupportedBulb
    case integrationConflict
    case bulbOffline
    case rateLimited
    case loginApprovalRequired
    case operationFailed
}

public enum OutstandingObligation: String, Codable, Hashable, Sendable {
    case integrationUninstallRetry
    case integrationRollbackRepair
    case integrationMixedAdoption
    case integrationArtifactCleanup
    case integrationPersistenceRetry
    case credentialRestore
    case credentialDelete
    case credentialBackupCleanup
    case loginRegistrationCleanup
    case ownershipReceiptRepair
}

@MainActor
@Observable
public final class AppViewModel: AppViewModeling {
    public private(set) var phase: AppPhase = .onboarding
    public private(set) var connectionStatus: LightConnectionStatus = .disconnected
    public private(set) var currentState: AgentState = .idle
    public private(set) var sessions: [AgentEvent] = []
    public private(set) var integrationPreviews: [IntegrationPreview] = []
    public private(set) var presentedError: PresentationError?
    public private(set) var outstandingObligations: Set<OutstandingObligation> = []
    public private(set) var loginItemStatus: LoginItemStatus
    public private(set) var maskedAccessID: String?
    public private(set) var maskedDeviceID: String?
    public private(set) var repairPreviews: [IntegrationPreview] = []
    public private(set) var integrationInstalled = false
    public private(set) var integrationStatus: IntegrationInstallationStatus = .notInstalled
    public private(set) var codexTrustStatus: IntegrationTrustStatus = .notRequired
    public private(set) var monitoringActive = false
    public private(set) var canResetOwnershipReceipt = false

    @ObservationIgnored private let credentials: any CredentialStoring
    @ObservationIgnored private let integrations: any IntegrationInstalling
    @ObservationIgnored private let monitor: any MonitoringOrchestrating
    @ObservationIgnored private let loginItem: any LoginItemControlling
    @ObservationIgnored private let verifier: any TuyaConnectionVerifying
    @ObservationIgnored private let ownershipLedger: AppOwnershipLedger
    @ObservationIgnored private let presentationHandle: AppPresentationHandle

    @ObservationIgnored private var pendingCredentials: TuyaCredentials?
    @ObservationIgnored private var connectGeneration: UInt64 = 0
    @ObservationIgnored private var monitorEpoch: UInt64 = 0
    @ObservationIgnored private var monitoringLifecycleGeneration: UInt64 = 0
    @ObservationIgnored private var monitoringLifecycleShutdown = false
    @ObservationIgnored private var connectTask: SharedOperation?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var observationID: UUID?
    @ObservationIgnored private var approvalTask: SharedOperation?
    @ObservationIgnored private var approvalID: UUID?
    @ObservationIgnored private var pauseTask: SharedOperation?
    @ObservationIgnored private var resumeTask: SharedOperation?
    @ObservationIgnored private var repairTask: SharedOperation?
    @ObservationIgnored private var shutdownTask: SharedOperation?
    @ObservationIgnored private var disconnectTask: SharedOperation?
    @ObservationIgnored private var integrationOwnership: PersistentIntegrationOwnership = .none
    @ObservationIgnored private var credentialOwnership: PersistentCredentialOwnership = .none
    @ObservationIgnored private var loginRegistrationOwned = false
    @ObservationIgnored private var ownsMonitoring = false
#if DEBUG
    @ObservationIgnored private var actionEntryCounts: [OperationKind: Int] = [:]
    @ObservationIgnored private var actionEntryBarriers: [(OperationKind, Int, CheckedContinuation<Void, Never>)] = []
    @ObservationIgnored private var shouldBlockNextOwnershipHydrationReturn = false
    @ObservationIgnored private var ownershipHydrationReturnBlocked = false
    @ObservationIgnored private var ownershipHydrationReturnContinuation: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var ownershipHydrationReturnWaiters: [CheckedContinuation<Void, Never>] = []
#endif

    public init(
        credentials: any CredentialStoring,
        integrations: any IntegrationInstalling,
        monitor: any MonitoringOrchestrating,
        loginItem: any LoginItemControlling,
        verifier: any TuyaConnectionVerifying,
        ownershipLedger: AppOwnershipLedger
    ) {
        self.credentials = credentials
        self.integrations = integrations
        self.monitor = monitor
        self.loginItem = loginItem
        self.verifier = verifier
        self.ownershipLedger = ownershipLedger
        loginItemStatus = loginItem.status()
        let presentationHandle = AppPresentationHandle()
        self.presentationHandle = presentationHandle
        presentationHandle.attach(self)
    }

    public convenience init(
        credentials: any CredentialStoring,
        integrations: any IntegrationInstalling,
        monitor: any MonitoringOrchestrating,
        loginItem: any LoginItemControlling,
        verifier: any TuyaConnectionVerifying
    ) {
        self.init(
            credentials: credentials,
            integrations: integrations,
            monitor: monitor,
            loginItem: loginItem,
            verifier: verifier,
            ownershipLedger: AppOwnershipLedger()
        )
    }

    deinit {
        observationTask?.cancel()
        connectTask?.cancel()
        approvalTask?.cancel()
        pauseTask?.cancel()
        resumeTask?.cancel()
        repairTask?.cancel()
        disconnectTask?.cancel()
    }

    public func connect(using draft: ConnectionDraft) async {
#if DEBUG
        recordActionEntry(.connect)
#endif
        guard connectTask == nil,
              approvalTask == nil,
              phase == .onboarding || phase == .integrationReview else { return }
        _ = activateMonitoringLifecycle()
        guard await hydrateOwnership() else { return }
        guard (phase == .onboarding || phase == .integrationReview),
              outstandingObligations.isEmpty,
              approvalTask == nil else { return }
        connectGeneration &+= 1
        let generation = connectGeneration
        connectTask?.cancel()
        cancelObservation(resetState: true)
        phase = .verifying
        connectionStatus = .disconnected
        presentedError = nil
        integrationPreviews = []
        pendingCredentials = nil

        let verifier = verifier
        let integrations = integrations
        let task = Task { [weak self] in
            let result = await Self.connectResult(
                using: draft,
                verifier: verifier,
                integrations: integrations
            )
            guard !Task.isCancelled else { return }
            self?.applyConnect(result, generation: generation)
        }
        let operation = SharedOperation(task: task)
        connectTask = operation
        operation.onFinish { [weak self, weak operation] in
            guard let self, self.connectTask === operation else { return }
            self.connectTask = nil
        }
        await operation.wait()
    }

    public func approveIntegrations() async {
#if DEBUG
        recordActionEntry(.approval)
#endif
        guard let lifecycleGeneration = claimMonitoringLifecycleEntry() else { return }
        if let approvalTask {
            await approvalTask.wait()
            return
        }
        guard phase == .integrationReview,
              outstandingObligations.isEmpty,
              let pendingCredentials else {
            return
        }
        phase = .approving
        presentedError = nil
        let id = UUID()
        approvalID = id
        let integrations = integrations
        let credentials = credentials
        let loginItem = loginItem
        let monitor = monitor
        let ledger = ownershipLedger
        let presentationHandle = presentationHandle
        let task = Task { [weak self, integrations, credentials, monitor, ledger, presentationHandle] in
            guard let lease = await ledger.acquireLeaseForCaller() else {
                self?.cancelApproval(id: id)
                return
            }
            guard !Task.isCancelled else {
                self?.cancelApproval(id: id)
                await ledger.releaseLease(lease)
                return
            }
            guard self?.monitoringLifecycleAllows(lifecycleGeneration) == true else {
                self?.cancelApproval(id: id)
                await ledger.releaseLease(lease)
                return
            }
            let existing = await ledger.snapshot()
            guard !Task.isCancelled,
                  self?.monitoringLifecycleAllows(lifecycleGeneration) == true else {
                self?.cancelApproval(id: id)
                await ledger.releaseLease(lease)
                return
            }
            await ledger.registerPresentationHandle(presentationHandle)
            guard !Task.isCancelled,
                  self?.monitoringLifecycleAllows(lifecycleGeneration) == true else {
                self?.cancelApproval(id: id)
                await ledger.releaseLease(lease)
                return
            }
            let result: ApprovalResult
            if existing.hasOwnedState {
                if existing.monitoringOwned, existing.obligations.isEmpty {
                    let observation = await Self.preparedObservation(from: monitor)
                    result = .success(observation, existing)
                } else {
                    result = .failure(Self.presentationError(for: existing), existing)
                }
            } else {
                result = await Self.runApproval(
                    pendingCredentials: pendingCredentials,
                    integrations: integrations,
                    credentials: credentials,
                    loginItem: loginItem,
                    monitor: monitor,
                    ledger: ledger
                )
            }
            self?.applyApproval(result, id: id)
            await ledger.releaseLease(lease)
        }
        let operation = SharedOperation(task: task)
        approvalTask = operation
        operation.onFinish { [weak self, weak operation] in
            guard let self, self.approvalTask === operation else { return }
            self.approvalTask = nil
            self.approvalID = nil
        }
        await operation.wait()
    }

    private func cancelApproval(id: UUID) {
        guard approvalID == id else { return }
        phase = .integrationReview
    }

    public func pause() async {
#if DEBUG
        recordActionEntry(.pause)
#endif
        guard let lifecycleGeneration = claimMonitoringLifecycleEntry() else { return }
        guard await hydrateOwnership() else { return }
        guard monitoringLifecycleAllows(lifecycleGeneration) else { return }
        if let disconnectTask {
            await disconnectTask.wait()
            return
        }
        if let resumeTask {
            await resumeTask.wait()
            guard monitoringLifecycleAllows(lifecycleGeneration) else { return }
        }
        if let pauseTask {
            await pauseTask.wait()
            return
        }
        guard monitoringLifecycleAllows(lifecycleGeneration) else { return }
        guard phase == .monitoring else { return }
        let monitor = monitor
        let task = Task { [weak self, monitor] in
            guard self?.monitoringLifecycleAllows(lifecycleGeneration) == true else { return }
            await monitor.pause()
            guard let self else { return }
            if Task.isCancelled {
                do {
                    try await monitor.resume()
                    self.applyPause(.cancelledAndRestored)
                } catch {
                    self.applyPause(.pausedWithFailure(Self.presentationError(for: error)))
                }
                return
            }
            self.applyPause(.paused)
        }
        let operation = SharedOperation(task: task)
        pauseTask = operation
        operation.onFinish { [weak self, weak operation] in
            guard let self, self.pauseTask === operation else { return }
            self.pauseTask = nil
        }
        await operation.wait()
    }

    private func applyPause(_ result: PauseResult) {
        guard phase == .monitoring else { return }
        switch result {
        case .cancelledAndRestored:
            monitoringActive = true
            break
        case .paused:
            cancelObservation(resetState: true)
            monitoringActive = false
            phase = .paused
            presentedError = nil
        case let .pausedWithFailure(error):
            cancelObservation(resetState: true)
            monitoringActive = false
            phase = .paused
            presentedError = error
        }
    }

    public func resume() async {
#if DEBUG
        recordActionEntry(.resume)
#endif
        guard let lifecycleGeneration = claimMonitoringLifecycleEntry() else { return }
        guard await hydrateOwnership() else { return }
        guard monitoringLifecycleAllows(lifecycleGeneration) else { return }
        if let disconnectTask {
            await disconnectTask.wait()
            return
        }
        if let pauseTask {
            await pauseTask.wait()
            guard monitoringLifecycleAllows(lifecycleGeneration) else { return }
        }
        if let resumeTask {
            await resumeTask.wait()
            return
        }
        guard monitoringLifecycleAllows(lifecycleGeneration) else { return }
        guard phase == .paused else { return }
        let monitor = monitor
        let task = Task { [weak self, monitor] in
            do {
                guard self?.monitoringLifecycleAllows(lifecycleGeneration) == true else { return }
                try await monitor.resume()
                if Task.isCancelled {
                    await monitor.pause()
                    return
                }
                let observation = await Self.preparedObservation(from: monitor)
                if Task.isCancelled {
                    await monitor.pause()
                    return
                }
                guard let self else {
                    await monitor.pause()
                    return
                }
                guard self.phase == .paused else { return }
                self.ownsMonitoring = true
                self.monitoringActive = true
                self.installObservation(observation)
                guard !Task.isCancelled,
                      self.phase == .paused else { return }
                self.phase = .monitoring
                self.presentedError = nil
            } catch {
                guard let self else { return }
                guard !Task.isCancelled, self.phase == .paused else { return }
                self.presentedError = Self.presentationError(for: error)
            }
        }
        let operation = SharedOperation(task: task)
        resumeTask = operation
        operation.onFinish { [weak self, weak operation] in
            guard let self, self.resumeTask === operation else { return }
            self.resumeTask = nil
        }
        await operation.wait()
    }

    public func repairIntegrations() async {
#if DEBUG
        recordActionEntry(.repair)
#endif
        if let shutdownTask {
            await shutdownTask.wait()
            return
        }
        if let disconnectTask {
            await disconnectTask.wait()
            return
        }
        if let repairTask {
            await repairTask.wait()
            return
        }
        if let pauseTask { await pauseTask.wait() }
        if let resumeTask { await resumeTask.wait() }
        let originalPhase = phase
        guard originalPhase == .monitoring || originalPhase == .paused || originalPhase == .repairRequired else {
            return
        }
        let requestedPlan = Self.repairPlan(
            for: outstandingObligations,
            phase: originalPhase,
            resetEligible: canResetOwnershipReceipt
        )
        let integrations = integrations
        let ledger = ownershipLedger
        let presentationHandle = presentationHandle
        let task = Task { [weak self, integrations, ledger, presentationHandle] in
            guard let lease = await ledger.acquireLeaseForCaller() else { return }
            let current = await ledger.snapshot()
            guard !Task.isCancelled else {
                await ledger.releaseLease(lease)
                return
            }
            await ledger.registerPresentationHandle(presentationHandle)
            guard !Task.isCancelled else {
                await ledger.releaseLease(lease)
                return
            }
            guard let plan = requestedPlan,
                  Self.repairPlan(plan, isValidFor: current) else {
                self?.applyRepair(
                    .reconciled,
                    recording: .recorded(current),
                    plan: requestedPlan ?? .health,
                    originalPhase: originalPhase
                )
                await ledger.releaseLease(lease)
                return
            }
            let result = await Self.performRepair(plan, snapshot: current, using: integrations)
            let recording = await Self.recordRepair(
                result,
                plan: plan,
                priorSnapshot: current,
                ledger: ledger
            )
            self?.applyRepair(result, recording: recording, plan: plan, originalPhase: originalPhase)
            await ledger.releaseLease(lease)
        }
        let operation = SharedOperation(task: task)
        repairTask = operation
        operation.onFinish { [weak self, weak operation] in
            guard let self, self.repairTask === operation else { return }
            self.repairTask = nil
        }
        await operation.wait()
        repairPreviews = []
    }

    public func resetOwnershipReceipt() async {
        guard phase == .repairRequired,
              canResetOwnershipReceipt,
              let lease = await ownershipLedger.acquireLeaseForCaller() else { return }
        do {
            try await ownershipLedger.resetInvalidReceipt()
            let snapshot = await ownershipLedger.snapshot()
            syncOwnership(snapshot)
            pendingCredentials = nil
            integrationPreviews = []
            repairPreviews = []
            phase = .onboarding
            presentedError = nil
        } catch {
            syncOwnership(await ownershipLedger.snapshot())
            phase = .repairRequired
            presentedError = .operationFailed
        }
        await ownershipLedger.releaseLease(lease)
    }

    public func disconnect() async {
#if DEBUG
        recordActionEntry(.disconnect)
#endif
        invalidateMonitoringLifecycle()
        if let disconnectTask {
            await disconnectTask.wait()
            return
        }
        if let shutdownTask { await shutdownTask.wait() }
        if let disconnectTask {
            await disconnectTask.wait()
            return
        }
        connectGeneration &+= 1
        connectTask?.cancel()
        let pendingApproval = approvalTask
        pendingApproval?.cancel()
        let pendingPause = pauseTask
        let pendingResume = resumeTask
        let pendingRepair = repairTask
        pendingPause?.cancel()
        pendingResume?.cancel()
        pendingRepair?.cancel()
        cancelObservation(resetState: true)
        let monitor = monitor
        let integrations = integrations
        let credentials = credentials
        let loginItem = loginItem
        let ledger = ownershipLedger
        let presentationHandle = presentationHandle
        let cleanupTask = Task { [monitor, integrations, credentials, ledger, presentationHandle] in
            await pendingApproval?.wait()
            await pendingPause?.wait()
            await pendingResume?.wait()
            await pendingRepair?.wait()
            do {
                try await ledger.hydrate()
            } catch {
                presentationHandle.commitSharedCleanup(await ledger.snapshot())
                return
            }
            let lease = await ledger.acquireLease()
            await ledger.registerPresentationHandle(presentationHandle)
            let snapshot = await Self.cleanupOwnedState(
                integrations: integrations,
                credentials: credentials,
                loginItem: loginItem,
                monitor: monitor,
                ledger: ledger
            )
            let handles = await ledger.presentationHandles()
            for handle in handles {
                handle.commitSharedCleanup(snapshot)
            }
            await ledger.releaseLease(lease)
        }
        let task = Task { await cleanupTask.value }
        let operation = SharedOperation(task: task)
        disconnectTask = operation
        operation.onFinish { [weak self, weak operation] in
            guard let self, self.disconnectTask === operation else { return }
            self.disconnectTask = nil
        }
        await operation.wait()
    }

    public func shutdownMonitoring() async {
#if DEBUG
        recordActionEntry(.shutdown)
#endif
        invalidateMonitoringLifecycle()
        if let disconnectTask {
            await disconnectTask.waitForDriverCompletion()
            return
        }
        if let shutdownTask {
            await shutdownTask.waitForDriverCompletion()
            return
        }
        let pendingApproval = approvalTask
        let pendingPause = pauseTask
        let pendingResume = resumeTask
        let pendingRepair = repairTask
        let monitor = monitor
        let ledger = ownershipLedger
        let task = Task { [weak self, monitor, ledger] in
            await pendingApproval?.waitForDriverCompletion()
            await pendingPause?.waitForDriverCompletion()
            await pendingResume?.waitForDriverCompletion()
            await pendingRepair?.waitForDriverCompletion()
            do {
                try await ledger.hydrate()
            } catch {
                self?.finishMonitoringShutdown(await ledger.snapshot())
                return
            }
            let lease = await ledger.acquireLease()
            let snapshot = await ledger.snapshot()
            if snapshot.monitoringOwned {
                await monitor.stop()
                await ledger.setMonitoringOwned(false)
            }
            let finalSnapshot = await ledger.snapshot()
            await ledger.releaseLease(lease)
            self?.finishMonitoringShutdown(finalSnapshot)
        }
        let operation = SharedOperation(task: task)
        shutdownTask = operation
        operation.onFinish { [weak self, weak operation] in
            guard let self, self.shutdownTask === operation else { return }
            self.shutdownTask = nil
        }
        await operation.wait()
    }

    public func requestLaunchAtLogin() async {
        guard phase == .monitoring || phase == .paused || phase == .repairRequired,
              let lease = await ownershipLedger.acquireLeaseForCaller() else { return }
        let snapshot = await ownershipLedger.snapshot()
        if snapshot.login == .pendingApproval {
            loginItemStatus = loginItem.status()
            if loginItemStatus == .enabled {
                do {
                    try await ownershipLedger.update(.login(.registered))
                    syncOwnership(await ownershipLedger.snapshot())
                    presentedError = nil
                } catch {
                    syncOwnership(await ownershipLedger.snapshot())
                    phase = .repairRequired
                    presentedError = .operationFailed
                }
            } else if loginItemStatus == .requiresApproval {
                presentedError = .loginApprovalRequired
            } else {
                presentedError = .operationFailed
            }
            await ownershipLedger.releaseLease(lease)
            return
        }
        do {
            let transition = try loginItem.setEnabled(true)
            loginItemStatus = transition.current
            if transition.didRegister {
                do {
                    try await ownershipLedger.update(.login(
                        transition.current == .requiresApproval ? .pendingApproval : .registered
                    ))
                    loginRegistrationOwned = true
                } catch {
                    do {
                        _ = try loginItem.setEnabled(false)
                    } catch {
                        _ = await Self.persist([
                            .login(transition.current == .requiresApproval ? .pendingApproval : .registered),
                            .insertObligation(.loginRegistrationCleanup)
                        ], to: ownershipLedger)
                    }
                    loginItemStatus = loginItem.status()
                    syncOwnership(await ownershipLedger.snapshot())
                    phase = .repairRequired
                    presentedError = .operationFailed
                    await ownershipLedger.releaseLease(lease)
                    return
                }
            }
            presentedError = transition.current == .requiresApproval ? .loginApprovalRequired : nil
        } catch {
            loginItemStatus = loginItem.status()
            presentedError = .operationFailed
        }
        await ownershipLedger.releaseLease(lease)
    }

    public func confirmCodexTrust() {
        guard codexTrustStatus == .required else { return }
        codexTrustStatus = .userConfirmed
    }

    public func reconnect() async {
        guard await hydrateOwnership(), phase == .monitoring, ownsMonitoring else { return }
        await monitor.reconnect()
        let observation = await Self.preparedObservation(from: monitor)
        guard phase == .monitoring else { return }
        apply(observation.snapshot)
        if observationTask == nil {
            installObservation(observation)
        }
        presentedError = connectionStatus == .connected ? nil : .bulbOffline
    }

    public func previewIntegrationRepair() async {
        guard phase == .monitoring || phase == .paused || phase == .repairRequired,
              let lease = await ownershipLedger.acquireLeaseForCaller() else { return }
        do {
            repairPreviews = try await integrations.preview()
            presentedError = nil
        } catch {
            repairPreviews = []
            presentedError = Self.presentationError(for: error)
        }
        await ownershipLedger.releaseLease(lease)
    }

    public func uninstallIntegrations() async {
        guard phase == .monitoring || phase == .paused || phase == .repairRequired,
              let lease = await ownershipLedger.acquireLeaseForCaller() else { return }
        let snapshot = await ownershipLedger.snapshot()
        switch snapshot.integration {
        case let .uninstallable(receipt):
            do {
                try await integrations.uninstall(using: receipt)
                let persisted = await Self.persistCommittedIntegrationState(
                    receipt: receipt,
                    priorSnapshot: snapshot,
                    integration: .none,
                    removing: [.integrationUninstallRetry],
                    inserting: [],
                    ledger: ownershipLedger
                )
                phase = persisted ? phase : .repairRequired
                presentedError = persisted ? nil : .operationFailed
            } catch let error as IntegrationError where Self.isCommittedCleanup(error) {
                let committedReceipt = Self.committedReceipt(from: error) ?? receipt
                _ = await Self.persistCommittedIntegrationState(
                    receipt: committedReceipt,
                    priorSnapshot: snapshot,
                    integration: .none,
                    removing: [.integrationUninstallRetry],
                    inserting: [.integrationArtifactCleanup],
                    ledger: ownershipLedger
                )
                phase = .repairRequired
                presentedError = .operationFailed
            } catch IntegrationError.ownershipVerificationFailed,
                    IntegrationError.destinationChanged {
                _ = await Self.persist([
                    .integration(.uncertain(receipt)),
                    .insertObligation(.integrationRollbackRepair)
                ], to: ownershipLedger)
                phase = .repairRequired
                presentedError = .integrationConflict
            } catch {
                _ = await Self.persist([
                    .insertObligation(.integrationUninstallRetry)
                ], to: ownershipLedger)
                phase = .repairRequired
                presentedError = Self.presentationError(for: error)
            }
        case let .preexisting(receipt), let .mixed(receipt):
            _ = await Self.persist([
                .integration(.mixed(receipt)),
                .insertObligation(.integrationMixedAdoption)
            ], to: ownershipLedger)
            phase = .repairRequired
            presentedError = .integrationConflict
        case .uncertain:
            _ = await Self.persist([
                .insertObligation(.integrationRollbackRepair)
            ], to: ownershipLedger)
            phase = .repairRequired
            presentedError = .integrationConflict
        case .none:
            presentedError = .integrationConflict
        }
        let final = await ownershipLedger.snapshot()
        syncOwnership(final)
        repairPreviews = []
        await ownershipLedger.releaseLease(lease)
    }

    public func replaceDevice() async {
        await disconnect()
    }

    public func setMonitoringEnabled(_ enabled: Bool) async {
        let originalPhase = phase
        let preservedError = presentedError
        guard await hydrateOwnership(), ownsMonitoring else { return }
        if originalPhase == .repairRequired, phase == .repairRequired {
            presentedError = preservedError
        }
        if phase == .monitoring, !enabled {
            await pause()
            return
        }
        if phase == .paused, enabled {
            await resume()
            return
        }
        guard phase == .repairRequired, enabled != monitoringActive else { return }
        if enabled {
            if let pauseTask { await pauseTask.wait() }
            if let resumeTask {
                await resumeTask.wait()
                return
            }
            let monitor = monitor
            let task = Task { [weak self, monitor] in
                do {
                    try await monitor.resume()
                    if Task.isCancelled {
                        await monitor.pause()
                        return
                    }
                    let observation = await Self.preparedObservation(from: monitor)
                    guard !Task.isCancelled, let self, self.phase == .repairRequired else {
                        await monitor.pause()
                        return
                    }
                    self.monitoringActive = true
                    self.installObservation(observation)
                    self.presentedError = preservedError
                } catch {
                    guard let self, !Task.isCancelled, self.phase == .repairRequired else { return }
                    self.monitoringActive = false
                    self.presentedError = preservedError
                }
            }
            let operation = SharedOperation(task: task)
            resumeTask = operation
            operation.onFinish { [weak self, weak operation] in
                guard let self, self.resumeTask === operation else { return }
                self.resumeTask = nil
            }
            await operation.wait()
        } else {
            if let resumeTask { await resumeTask.wait() }
            if let pauseTask {
                await pauseTask.wait()
                return
            }
            let monitor = monitor
            let task = Task { [weak self, monitor] in
                await monitor.pause()
                if Task.isCancelled {
                    do {
                        try await monitor.resume()
                    } catch {
                        self?.monitoringActive = false
                    }
                    return
                }
                guard let self, self.phase == .repairRequired else { return }
                self.cancelObservation(resetState: true)
                self.monitoringActive = false
                self.presentedError = preservedError
            }
            let operation = SharedOperation(task: task)
            pauseTask = operation
            operation.onFinish { [weak self, weak operation] in
                guard let self, self.pauseTask === operation else { return }
                self.pauseTask = nil
            }
            await operation.wait()
        }
    }

    public func observeMonitoring() async {
        guard await hydrateOwnership() else { return }
        guard ownsMonitoring, phase == .monitoring || phase == .approving else { return }
        guard observationTask == nil else { return }
        await beginObservation()
    }

    public func synchronizeOwnership() async {
        if let shutdownTask { await shutdownTask.waitForDriverCompletion() }
        let lifecycleGeneration = activateMonitoringLifecycle()
        connectGeneration &+= 1
        let pendingConnect = connectTask
        pendingConnect?.cancel()
        await pendingConnect?.wait()
        guard monitoringLifecycleAllows(lifecycleGeneration) else { return }
        do {
            try await ownershipLedger.hydrate()
        } catch {
            // The ledger has already replaced corrupt/unsupported state with a sanitized repair obligation.
        }
        guard monitoringLifecycleAllows(lifecycleGeneration) else { return }
        guard let lease = await ownershipLedger.acquireLeaseForCaller() else { return }
        guard monitoringLifecycleAllows(lifecycleGeneration) else {
            await ownershipLedger.releaseLease(lease)
            return
        }
        await ownershipLedger.registerPresentationHandle(presentationHandle)
        guard monitoringLifecycleAllows(lifecycleGeneration) else {
            await ownershipLedger.releaseLease(lease)
            return
        }
        let snapshot = await ownershipLedger.snapshot()
        guard monitoringLifecycleAllows(lifecycleGeneration) else {
            await ownershipLedger.releaseLease(lease)
            return
        }
        syncOwnership(snapshot)
        ownsMonitoring = snapshot.monitoringOwned
        if snapshot.canResumeMonitoringAfterRelaunch {
            do {
                guard monitoringLifecycleAllows(lifecycleGeneration) else {
                    await ownershipLedger.releaseLease(lease)
                    return
                }
                try await monitor.start()
                if Task.isCancelled || !monitoringLifecycleAllows(lifecycleGeneration) {
                    await monitor.stop()
                    await ownershipLedger.setMonitoringOwned(false)
                    await ownershipLedger.releaseLease(lease)
                    return
                }
                await ownershipLedger.setMonitoringOwned(true)
                let observation = await Self.preparedObservation(from: monitor)
                if Task.isCancelled || !monitoringLifecycleAllows(lifecycleGeneration) {
                    await monitor.stop()
                    await ownershipLedger.setMonitoringOwned(false)
                    await ownershipLedger.releaseLease(lease)
                    return
                }
                let resumed = await ownershipLedger.snapshot()
                syncOwnership(resumed)
                ownsMonitoring = true
                monitoringActive = true
                installObservation(observation)
                phase = .monitoring
                presentedError = nil
            } catch {
                ownsMonitoring = false
                monitoringActive = false
                cancelObservation(resetState: true)
                phase = .paused
                presentedError = Self.presentationError(for: error)
            }
            await ownershipLedger.releaseLease(lease)
            return
        }
        if snapshot.obligations.isEmpty {
            if pendingConnect != nil, phase == .verifying {
                pendingCredentials = nil
                integrationPreviews = []
                phase = .onboarding
                presentedError = nil
            } else {
                reconcileEmptyLedgerPresentation(snapshot)
            }
        } else {
            phase = .repairRequired
            presentedError = Self.presentationError(for: snapshot)
        }
        await ownershipLedger.releaseLease(lease)
    }

    private func hydrateOwnership() async -> Bool {
        do {
            try await ownershipLedger.hydrate()
        } catch {
            // The sanitized fail-closed snapshot remains available for repair presentation.
        }
        guard let lease = await ownershipLedger.acquireLeaseForCaller() else { return false }
        await ownershipLedger.registerPresentationHandle(presentationHandle)
        let snapshot = await ownershipLedger.snapshot()
        syncOwnership(snapshot)
        ownsMonitoring = snapshot.monitoringOwned
        guard !snapshot.obligations.isEmpty else {
            reconcileEmptyLedgerPresentation(snapshot)
            await ownershipLedger.releaseLease(lease)
            await blockOwnershipHydrationReturnIfNeeded()
            return true
        }
        connectGeneration &+= 1
        connectTask?.cancel()
        phase = .repairRequired
        presentedError = Self.presentationError(for: snapshot)
        await ownershipLedger.releaseLease(lease)
        await blockOwnershipHydrationReturnIfNeeded()
        return true
    }

    private func reconcileEmptyLedgerPresentation(_ snapshot: OwnershipSnapshot) {
        guard !snapshot.hasOwnedState, phase == .repairRequired else { return }
        pendingCredentials = nil
        integrationPreviews = []
        phase = .onboarding
        presentedError = nil
    }

    private func claimMonitoringLifecycleEntry() -> UInt64? {
        guard !monitoringLifecycleShutdown else { return nil }
        return monitoringLifecycleGeneration
    }

    private func monitoringLifecycleAllows(_ generation: UInt64) -> Bool {
        !monitoringLifecycleShutdown && monitoringLifecycleGeneration == generation
    }

    @discardableResult
    private func activateMonitoringLifecycle() -> UInt64 {
        monitoringLifecycleGeneration &+= 1
        monitoringLifecycleShutdown = false
        return monitoringLifecycleGeneration
    }

    private func invalidateMonitoringLifecycle() {
        monitoringLifecycleGeneration &+= 1
        monitoringLifecycleShutdown = true
    }

#if DEBUG
    func blockNextOwnershipHydrationReturnForTesting() {
        shouldBlockNextOwnershipHydrationReturn = true
    }

    func waitForBlockedOwnershipHydrationReturnForTesting() async {
        if ownershipHydrationReturnBlocked { return }
        await withCheckedContinuation { ownershipHydrationReturnWaiters.append($0) }
    }

    func resumeBlockedOwnershipHydrationReturnForTesting() {
        ownershipHydrationReturnContinuation?.resume()
        ownershipHydrationReturnContinuation = nil
    }

    private func blockOwnershipHydrationReturnIfNeeded() async {
        guard shouldBlockNextOwnershipHydrationReturn else { return }
        shouldBlockNextOwnershipHydrationReturn = false
        ownershipHydrationReturnBlocked = true
        let waiters = ownershipHydrationReturnWaiters
        ownershipHydrationReturnWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { ownershipHydrationReturnContinuation = $0 }
        ownershipHydrationReturnBlocked = false
    }

    func waitForActionEntry(_ kind: OperationKind, count: Int) async {
        if actionEntryCounts[kind, default: 0] >= count { return }
        await withCheckedContinuation { actionEntryBarriers.append((kind, count, $0)) }
    }

    private func recordActionEntry(_ kind: OperationKind) {
        actionEntryCounts[kind, default: 0] += 1
        let ready = actionEntryBarriers.filter {
            $0.0 == kind && actionEntryCounts[kind, default: 0] >= $0.1
        }
        actionEntryBarriers.removeAll {
            $0.0 == kind && actionEntryCounts[kind, default: 0] >= $0.1
        }
        for barrier in ready { barrier.2.resume() }
    }

    func waitForOperationWaiterCount(_ kind: OperationKind, count: Int) async {
        let operation: SharedOperation?
        switch kind {
        case .approval: operation = approvalTask
        case .pause: operation = pauseTask
        case .resume: operation = resumeTask
        case .repair: operation = repairTask
        case .shutdown: operation = shutdownTask
        case .disconnect: operation = disconnectTask
        case .connect: operation = connectTask
        }
        await operation?.waitForWaiterCount(count)
    }
#endif

#if !DEBUG
    private func blockOwnershipHydrationReturnIfNeeded() async {}
#endif

    private static func connectResult(
        using draft: ConnectionDraft,
        verifier: any TuyaConnectionVerifying,
        integrations: any IntegrationInstalling
    ) async -> ConnectResult {
        let temporary: TuyaCredentials
        do {
            temporary = try Self.validatedCredentials(from: draft)
        } catch {
            return .failure(Self.presentationError(for: error))
        }

        do {
            _ = try await verifier.verify(temporary)
            try Task.checkCancellation()
            let previews = try await integrations.preview()
            try Task.checkCancellation()
            return .success(temporary, previews)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(Self.presentationError(for: error))
        }
    }

    private func applyConnect(_ result: ConnectResult, generation: UInt64) {
        guard generation == connectGeneration else { return }
        switch result {
        case let .success(temporary, previews):
            pendingCredentials = temporary
            maskedAccessID = Self.maskedIdentifier(temporary.accessID)
            maskedDeviceID = Self.maskedIdentifier(temporary.deviceID)
            integrationPreviews = previews
            presentedError = nil
            phase = .integrationReview
        case let .failure(error):
            pendingCredentials = nil
            maskedAccessID = nil
            maskedDeviceID = nil
            integrationPreviews = []
            phase = .onboarding
            presentedError = error
        case .cancelled:
            break
        }
    }

    private static func runApproval(
        pendingCredentials: TuyaCredentials,
        integrations: any IntegrationInstalling,
        credentials: any CredentialStoring,
        loginItem: any LoginItemControlling,
        monitor: any MonitoringOrchestrating,
        ledger: AppOwnershipLedger
    ) async -> ApprovalResult {
        do {
            try Task.checkCancellation()
            do {
                let receipt = try await integrations.installWithReceipt()
                guard receipt.isValid, receipt.hasVerifiableFingerprints else {
                    guard await persist([
                        .integration(.uncertain(nil)),
                        .insertObligation(.integrationMixedAdoption)
                    ], to: ledger) else {
                        return .failure(.operationFailed, await ledger.snapshot())
                    }
                    return .failure(.integrationConflict, await ledger.snapshot())
                }
                do {
                    try await ledger.update(.integration(Self.integrationOwnership(for: receipt)))
                } catch {
                    let snapshot = await compensateUnpersistedIntegration(
                        receipt,
                        integrations: integrations,
                        ledger: ledger
                    )
                    return .failure(.operationFailed, snapshot)
                }
            } catch let error as IntegrationError {
                switch error {
                case let .committedWithReceiptCleanupFailure(receipt, _):
                    if receipt.isValid, receipt.hasVerifiableFingerprints {
                        guard await persist([
                            .integration(Self.integrationOwnership(for: receipt))
                        ], to: ledger) else {
                            return .failure(.operationFailed, await ledger.snapshot())
                        }
                    } else {
                        guard await persist([
                            .integration(.uncertain(nil)),
                            .insertObligation(.integrationMixedAdoption)
                        ], to: ledger) else {
                            return .failure(.operationFailed, await ledger.snapshot())
                        }
                    }
                    guard await persist([
                        .insertObligation(.integrationArtifactCleanup)
                    ], to: ledger) else {
                        return .failure(.operationFailed, await ledger.snapshot())
                    }
                    return await compensatedApprovalResult(
                        error: .integrationConflict,
                        integrations: integrations,
                        credentials: credentials,
                        loginItem: loginItem,
                        monitor: monitor,
                        ledger: ledger
                    )
                case .committedWithCleanupFailure:
                    _ = await persist([
                        .integration(.uncertain(nil)),
                        .insertObligation(.integrationMixedAdoption),
                        .insertObligation(.integrationArtifactCleanup)
                    ], to: ledger)
                    return .failure(.integrationConflict, await ledger.snapshot())
                case .rollbackFailed:
                    _ = await persist([
                        .integration(.uncertain(nil)),
                        .insertObligation(.integrationRollbackRepair)
                    ], to: ledger)
                    return .failure(.integrationConflict, await ledger.snapshot())
                default:
                    throw error
                }
            }

            try Task.checkCancellation()
            let previous = try credentials.load()
            let previousStore = credentials as? any PreviousCredentialStoring
            if let previous {
                guard let previousStore else { throw InternalError.previousCredentialStoreUnavailable }
                try previousStore.savePrevious(previous)
            }
            do {
                try await ledger.update(.credentials(previous == nil ? .created : .replacedWithBackup))
            } catch {
                if previous != nil {
                    do {
                        try previousStore?.deletePrevious()
                    } catch {
                        _ = await persist([.insertObligation(.credentialBackupCleanup)], to: ledger)
                    }
                }
                throw error
            }
            try credentials.save(pendingCredentials)

            try Task.checkCancellation()
            let transition = try loginItem.setEnabled(true)
            if transition.didRegister {
                do {
                    try await ledger.update(.login(
                        transition.current == .requiresApproval ? .pendingApproval : .registered
                    ))
                } catch {
                    do {
                        _ = try loginItem.setEnabled(false)
                    } catch {
                        _ = await persist([
                            .login(transition.current == .requiresApproval ? .pendingApproval : .registered),
                            .insertObligation(.loginRegistrationCleanup)
                        ], to: ledger)
                    }
                    throw error
                }
            }
            guard transition.current == .enabled
                    || (transition.didRegister && transition.current == .requiresApproval)
            else { throw InternalError.loginApprovalRequired }

            try Task.checkCancellation()
            try await monitor.start()
            await ledger.setMonitoringOwned(true)
            try Task.checkCancellation()
            let observation = await preparedObservation(from: monitor)
            try Task.checkCancellation()
            return .success(observation, await ledger.snapshot())
        } catch is CancellationError {
            return await compensatedApprovalResult(
                error: nil,
                integrations: integrations,
                credentials: credentials,
                loginItem: loginItem,
                monitor: monitor,
                ledger: ledger
            )
        } catch {
            return await compensatedApprovalResult(
                error: Self.presentationError(for: error),
                integrations: integrations,
                credentials: credentials,
                loginItem: loginItem,
                monitor: monitor,
                ledger: ledger
            )
        }
    }

    private static func compensatedApprovalResult(
        error: PresentationError?,
        integrations: any IntegrationInstalling,
        credentials: any CredentialStoring,
        loginItem: any LoginItemControlling,
        monitor: any MonitoringOrchestrating,
        ledger: AppOwnershipLedger
    ) async -> ApprovalResult {
        let cleanup = Task {
            await cleanupOwnedState(
                integrations: integrations,
                credentials: credentials,
                loginItem: loginItem,
                monitor: monitor,
                ledger: ledger
            )
        }
        return .failure(error, await cleanup.value)
    }

    private static func compensateUnpersistedIntegration(
        _ receipt: IntegrationInstallReceipt,
        integrations: any IntegrationInstalling,
        ledger: AppOwnershipLedger
    ) async -> OwnershipSnapshot {
        do {
            try await integrations.uninstall(using: receipt)
        } catch {
            let recorded = await persist([
                .integration(Self.integrationOwnership(for: receipt)),
                .insertObligation(.integrationUninstallRetry)
            ], to: ledger)
            if !recorded {
                await ledger.setEmergencyIntegrationRecovery(
                    EmergencyIntegrationRecovery(receipt: receipt, action: .uninstall)
                )
            }
        }
        return await ledger.snapshot()
    }

    private static func persist(
        _ mutations: [OwnershipMutation],
        to ledger: AppOwnershipLedger
    ) async -> Bool {
        guard !mutations.isEmpty else { return true }
        do {
            try await ledger.update(mutations)
            return true
        } catch {
            return false
        }
    }

    private static func persistCommittedIntegrationState(
        receipt: IntegrationInstallReceipt,
        priorSnapshot: OwnershipSnapshot,
        integration: PersistentIntegrationOwnership,
        removing removedObligations: Set<OutstandingObligation>,
        inserting insertedObligations: Set<OutstandingObligation>,
        ledger: AppOwnershipLedger
    ) async -> Bool {
        let target = emergencyPersistenceTarget(
            priorSnapshot: priorSnapshot,
            integration: integration,
            removing: removedObligations,
            inserting: insertedObligations
        )
        let persisted = await persist([
            .integration(target.integration),
            .obligations(target.obligations)
        ], to: ledger)
        if !persisted {
            await ledger.setEmergencyIntegrationRecovery(
                EmergencyIntegrationRecovery(receipt: receipt, action: .persist(target))
            )
        }
        return persisted
    }

    private static func cleanupOwnedState(
        integrations: any IntegrationInstalling,
        credentials: any CredentialStoring,
        loginItem: any LoginItemControlling,
        monitor: any MonitoringOrchestrating,
        ledger: AppOwnershipLedger
    ) async -> OwnershipSnapshot {
        var snapshot = await ledger.snapshot()
        if snapshot.monitoringOwned {
            await monitor.stop()
            await ledger.setMonitoringOwned(false)
        }
        if snapshot.loginRegistrationOwned {
            do {
                let transition = try loginItem.setEnabled(false)
                if transition.current == .notRegistered || transition.current == .notFound {
                    guard await persist([
                        .login(.none),
                        .removeObligation(.loginRegistrationCleanup)
                    ], to: ledger) else { return await ledger.snapshot() }
                } else {
                    _ = await persist([.insertObligation(.loginRegistrationCleanup)], to: ledger)
                    return await ledger.snapshot()
                }
            } catch {
                _ = await persist([.insertObligation(.loginRegistrationCleanup)], to: ledger)
                return await ledger.snapshot()
            }
        }
        if snapshot.credentials != .none {
            do {
                switch snapshot.credentials {
                case .none: break
                case .created:
                    try credentials.delete()
                    guard await persist([
                        .removeObligation(.credentialDelete),
                        .credentials(.none)
                    ], to: ledger) else { return await ledger.snapshot() }
                case .replacedWithBackup:
                    guard let previousStore = credentials as? any PreviousCredentialStoring,
                          let previous = try previousStore.loadPrevious() else {
                        _ = await persist([.insertObligation(.credentialRestore)], to: ledger)
                        return await ledger.snapshot()
                    }
                    try credentials.save(previous)
                    guard await persist([
                        .removeObligation(.credentialRestore),
                        .insertObligation(.credentialBackupCleanup),
                        .credentials(.none)
                    ], to: ledger) else { return await ledger.snapshot() }
                    do {
                        try previousStore.deletePrevious()
                        guard await persist([
                            .removeObligation(.credentialBackupCleanup)
                        ], to: ledger) else { return await ledger.snapshot() }
                    } catch {
                        _ = await persist([.insertObligation(.credentialBackupCleanup)], to: ledger)
                        return await ledger.snapshot()
                    }
                }
            } catch {
                _ = await persist([
                    .insertObligation(snapshot.credentials == .created ? .credentialDelete : .credentialRestore)
                ], to: ledger)
                return await ledger.snapshot()
            }
        }
        if snapshot.credentials == .none,
           snapshot.obligations.contains(.credentialBackupCleanup),
           let previousStore = credentials as? any PreviousCredentialStoring {
            do {
                try previousStore.deletePrevious()
                guard await persist([
                    .removeObligation(.credentialBackupCleanup)
                ], to: ledger) else { return await ledger.snapshot() }
            } catch {
                _ = await persist([.insertObligation(.credentialBackupCleanup)], to: ledger)
                return await ledger.snapshot()
            }
        }
        snapshot = await ledger.snapshot()
        switch snapshot.integration {
        case .none:
            break
        case .preexisting:
            _ = await persist([.integration(.none)], to: ledger)
        case let .uninstallable(receipt):
            do {
                try await integrations.uninstall(using: receipt)
                _ = await persistCommittedIntegrationState(
                    receipt: receipt,
                    priorSnapshot: snapshot,
                    integration: .none,
                    removing: [.integrationUninstallRetry],
                    inserting: [],
                    ledger: ledger
                )
            } catch let error as IntegrationError where Self.isCommittedCleanup(error) {
                _ = await persistCommittedIntegrationState(
                    receipt: committedReceipt(from: error) ?? receipt,
                    priorSnapshot: snapshot,
                    integration: .none,
                    removing: [.integrationUninstallRetry],
                    inserting: [.integrationArtifactCleanup],
                    ledger: ledger
                )
            } catch IntegrationError.ownershipVerificationFailed,
                    IntegrationError.destinationChanged {
                _ = await persist([
                    .integration(.uncertain(receipt)),
                    .removeObligation(.integrationUninstallRetry),
                    .insertObligation(.integrationRollbackRepair)
                ], to: ledger)
            } catch {
                _ = await persist([.insertObligation(.integrationUninstallRetry)], to: ledger)
            }
        case .mixed:
            _ = await persist([.insertObligation(.integrationMixedAdoption)], to: ledger)
        case .uncertain:
            _ = await persist([.insertObligation(.integrationRollbackRepair)], to: ledger)
        }
        return await ledger.snapshot()
    }

    private func applyApproval(_ result: ApprovalResult, id: UUID) {
        guard approvalID == id else { return }
        switch result {
        case let .success(observation, snapshot):
            syncOwnership(snapshot)
            loginItemStatus = loginItem.status()
            ownsMonitoring = snapshot.monitoringOwned
            monitoringActive = snapshot.monitoringOwned
            installObservation(observation)
            phase = .monitoring
            presentedError = snapshot.login == .pendingApproval ? .loginApprovalRequired : nil
        case let .failure(error, snapshot):
            syncOwnership(snapshot)
            loginItemStatus = loginItem.status()
            ownsMonitoring = snapshot.monitoringOwned
            cancelObservation(resetState: true)
            phase = snapshot.obligations.isEmpty ? .integrationReview : .repairRequired
            if let error {
                presentedError = error
            } else if !snapshot.obligations.isEmpty {
                presentedError = hasIntegrationObligation ? .integrationConflict : .operationFailed
            }
        }
    }

    private func syncOwnership(_ snapshot: OwnershipSnapshot) {
        integrationOwnership = snapshot.integration
        integrationInstalled = snapshot.integration != .none
        integrationStatus = Self.installationStatus(for: snapshot)
        let recordedCodexTrust = snapshot.integration.receipt?.sources
            .first(where: { $0.source == .codex })?.trust ?? .notRequired
        if recordedCodexTrust == .notRequired || codexTrustStatus != .userConfirmed {
            codexTrustStatus = recordedCodexTrust
        }
        credentialOwnership = snapshot.credentials
        loginRegistrationOwned = snapshot.loginRegistrationOwned
        outstandingObligations = snapshot.obligations
        canResetOwnershipReceipt = snapshot.ownershipReceiptResetEligible
    }

    private func finishDisconnect(_ snapshot: OwnershipSnapshot) {
        syncOwnership(snapshot)
        ownsMonitoring = snapshot.monitoringOwned
        monitoringActive = false

        pendingCredentials = nil
        maskedAccessID = nil
        maskedDeviceID = nil
        repairPreviews = []
        integrationPreviews = []
        currentState = .idle
        sessions = []
        connectionStatus = .disconnected
        loginItemStatus = loginItem.status()
        phase = outstandingObligations.isEmpty ? .onboarding : .repairRequired
        if outstandingObligations.isEmpty {
            presentedError = nil
        } else if presentedError == nil {
            presentedError = hasIntegrationObligation
                ? .integrationConflict
                : .operationFailed
        }
    }

    private func finishMonitoringShutdown(_ snapshot: OwnershipSnapshot) {
        syncOwnership(snapshot)
        ownsMonitoring = snapshot.monitoringOwned
        monitoringActive = false
        cancelObservation(resetState: true)
        connectionStatus = .disconnected
    }

    fileprivate func commitSharedCleanup(_ snapshot: OwnershipSnapshot) {
        connectGeneration &+= 1
        connectTask?.cancel()
        approvalTask?.cancel()
        pauseTask?.cancel()
        resumeTask?.cancel()
        repairTask?.cancel()
        cancelObservation(resetState: true)
        finishDisconnect(snapshot)
    }

    private static func installationStatus(
        for snapshot: OwnershipSnapshot
    ) -> IntegrationInstallationStatus {
        let repairObligations: Set<OutstandingObligation> = [
            .integrationUninstallRetry,
            .integrationRollbackRepair,
            .integrationMixedAdoption,
            .integrationArtifactCleanup,
            .integrationPersistenceRetry
        ]
        if !snapshot.obligations.isDisjoint(with: repairObligations) {
            return .needsRepair
        }
        switch snapshot.integration {
        case .none:
            return .notInstalled
        case .uninstallable, .preexisting:
            return .installed
        case .mixed, .uncertain:
            return .needsRepair
        }
    }

    private static func repairPlan(
        for obligations: Set<OutstandingObligation>,
        phase: AppPhase,
        resetEligible: Bool
    ) -> RepairPlan? {
        if obligations.contains(.integrationPersistenceRetry) { return .persistEmergency }
        if obligations.contains(.integrationUninstallRetry) { return .uninstall }
        if obligations.contains(.integrationRollbackRepair) { return .rollback }
        if obligations.contains(.integrationArtifactCleanup) { return .artifactOnly }
        if obligations.contains(.integrationMixedAdoption) { return .adoptMixed }
        if obligations.contains(.ownershipReceiptRepair) {
            return resetEligible ? .ownershipReceiptReset : nil
        }
        return phase == .monitoring || phase == .paused ? .health : nil
    }

    private static func repairPlan(
        _ plan: RepairPlan,
        isValidFor snapshot: OwnershipSnapshot
    ) -> Bool {
        switch plan {
        case .ownershipReceiptReset:
            snapshot.ownershipReceiptResetEligible
                && snapshot.obligations.contains(.ownershipReceiptRepair)
        case .persistEmergency:
            snapshot.emergencyIntegrationRecovery != nil
                && snapshot.obligations.contains(.integrationPersistenceRetry)
        case .uninstall: snapshot.obligations.contains(.integrationUninstallRetry)
        case .rollback: snapshot.obligations.contains(.integrationRollbackRepair)
        case .adoptMixed: snapshot.obligations.contains(.integrationMixedAdoption)
        case .artifactOnly: snapshot.obligations.contains(.integrationArtifactCleanup)
        case .health:
            snapshot.monitoringOwned
                && snapshot.obligations.isDisjoint(with: [
                    .integrationUninstallRetry,
                    .integrationRollbackRepair,
                    .integrationMixedAdoption,
                    .integrationArtifactCleanup
                ])
        }
    }

    private static func performRepair(
        _ plan: RepairPlan,
        snapshot: OwnershipSnapshot,
        using integrations: any IntegrationInstalling
    ) async -> RepairResult {
        do {
            try Task.checkCancellation()
            switch plan {
            case .ownershipReceiptReset:
                return .invalidAdoptionReceipt
            case .persistEmergency:
                guard let recovery = snapshot.emergencyIntegrationRecovery else {
                    return .invalidAdoptionReceipt
                }
                return .emergencyPersistence(recovery)
            case .uninstall:
                let receipt: IntegrationInstallReceipt
                if let emergency = snapshot.emergencyIntegrationRecovery,
                   emergency.action == .uninstall {
                    receipt = emergency.receipt
                } else {
                    guard case let .uninstallable(ownedReceipt) = snapshot.integration else {
                        return .invalidAdoptionReceipt
                    }
                    receipt = ownedReceipt
                }
                try await integrations.uninstall(using: receipt)
            case .rollback, .health, .adoptMixed:
                guard let receipt = snapshot.integration.receipt else {
                    return .invalidAdoptionReceipt
                }
                let updated = try await integrations.repair(using: receipt)
                guard updated.isValid, updated.hasVerifiableFingerprints else {
                    return .invalidAdoptionReceipt
                }
                return .success(updatedReceipt: updated)
            case .artifactOnly:
                return try await integrations.verifyArtifactCleanup()
                    ? .artifactVerifiedClean
                    : .artifactRetained
            }
            return .success(updatedReceipt: nil)
        } catch IntegrationError.artifactCleanupFailure {
            return .artifactCleanupRequired(updatedReceipt: nil)
        } catch let IntegrationError.committedWithReceiptCleanupFailure(receipt, _) {
            return receipt.isValid && receipt.hasVerifiableFingerprints
                ? .artifactCleanupRequired(updatedReceipt: receipt)
                : .legacyArtifactCleanupRequired
        } catch IntegrationError.committedWithCleanupFailure {
            return plan == .adoptMixed
                ? .legacyArtifactCleanupRequired
                : .artifactCleanupRequired(updatedReceipt: nil)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(Self.presentationError(for: error))
        }
    }

    private static func recordRepair(
        _ result: RepairResult,
        plan: RepairPlan,
        priorSnapshot: OwnershipSnapshot,
        ledger: AppOwnershipLedger
    ) async -> RepairRecordingResult {
        var mutations: [OwnershipMutation]
        switch result {
        case let .success(updatedReceipt):
            switch plan {
            case .ownershipReceiptReset:
                mutations = []
            case .persistEmergency:
                mutations = []
            case .uninstall:
                mutations = [
                    .integration(.none),
                    .removeObligation(.integrationUninstallRetry)
                ]
            case .rollback:
                mutations = [
                    .integration(.none),
                    .removeObligation(.integrationRollbackRepair)
                ]
            case .adoptMixed:
                mutations = [
                    .integration(.none),
                    .removeObligation(.integrationMixedAdoption)
                ]
            case .health:
                mutations = updatedReceipt.map {
                    [.integration(Self.replacingReceipt(in: priorSnapshot.integration, with: $0))]
                } ?? []
            case .artifactOnly: mutations = []
            }
        case let .emergencyPersistence(recovery):
            guard case let .persist(target) = recovery.action else {
                return .persistenceFailed(await ledger.snapshot())
            }
            mutations = [
                .integration(target.integration),
                .obligations(target.obligations)
            ]
        case let .artifactCleanupRequired(updatedReceipt):
            var artifactMutations: [OwnershipMutation] = []
            switch plan {
            case .ownershipReceiptReset, .persistEmergency: break
            case .uninstall, .rollback, .adoptMixed:
                artifactMutations.append(.integration(.none))
            case .health, .artifactOnly:
                let ownership = updatedReceipt.map {
                    replacingReceipt(in: priorSnapshot.integration, with: $0)
                } ?? priorSnapshot.integration
                artifactMutations.append(.integration(ownership))
            }
            switch plan {
            case .ownershipReceiptReset, .persistEmergency: break
            case .uninstall: artifactMutations.append(.removeObligation(.integrationUninstallRetry))
            case .rollback: artifactMutations.append(.removeObligation(.integrationRollbackRepair))
            case .adoptMixed: artifactMutations.append(.removeObligation(.integrationMixedAdoption))
            case .health, .artifactOnly: break
            }
            artifactMutations.append(.insertObligation(.integrationArtifactCleanup))
            mutations = artifactMutations
        case .legacyArtifactCleanupRequired:
            mutations = [.insertObligation(.integrationArtifactCleanup)]
        case .artifactVerifiedClean:
            mutations = [.removeObligation(.integrationArtifactCleanup)]
        case .artifactRetained, .invalidAdoptionReceipt, .cancelled:
            mutations = []
        case .reconciled:
            mutations = []
        case .failure:
            mutations = plan == .health
                ? [.insertObligation(.integrationRollbackRepair)]
                : []
        }
        let resolvesEmergency: Bool
        switch result {
        case .success, .emergencyPersistence, .artifactCleanupRequired:
            resolvesEmergency = true
        default:
            resolvesEmergency = false
        }
        if priorSnapshot.emergencyIntegrationRecovery != nil, resolvesEmergency {
            mutations.append(contentsOf: [
                .removeObligation(.ownershipReceiptRepair),
                .removeObligation(.integrationPersistenceRetry)
            ])
        }
        guard await persist(mutations, to: ledger) else {
            if let recovery = emergencyRecovery(
                after: result,
                plan: plan,
                priorSnapshot: priorSnapshot
            ) {
                await ledger.setEmergencyIntegrationRecovery(recovery)
            }
            return .persistenceFailed(await ledger.snapshot())
        }
        if (priorSnapshot.emergencyIntegrationRecovery != nil && resolvesEmergency)
            || plan == .persistEmergency {
            await ledger.clearEmergencyIntegrationRecovery()
        }
        return .recorded(await ledger.snapshot())
    }

    private static func emergencyRecovery(
        after result: RepairResult,
        plan: RepairPlan,
        priorSnapshot: OwnershipSnapshot
    ) -> EmergencyIntegrationRecovery? {
        if case let .emergencyPersistence(recovery) = result { return recovery }
        let updatedReceipt: IntegrationInstallReceipt?
        let insertsArtifactCleanup: Bool
        switch result {
        case let .success(receipt):
            updatedReceipt = receipt
            insertsArtifactCleanup = false
        case let .artifactCleanupRequired(receipt):
            updatedReceipt = receipt
            insertsArtifactCleanup = true
        case .legacyArtifactCleanupRequired:
            updatedReceipt = nil
            insertsArtifactCleanup = true
        default:
            return nil
        }
        let receipt = updatedReceipt
            ?? priorSnapshot.emergencyIntegrationRecovery?.receipt
            ?? priorSnapshot.integration.receipt
        guard let receipt else { return nil }
        let integration: PersistentIntegrationOwnership
        var removedObligations: Set<OutstandingObligation> = []
        switch plan {
        case .health:
            integration = updatedReceipt.map {
                replacingReceipt(in: priorSnapshot.integration, with: $0)
            } ?? priorSnapshot.integration
        case .uninstall:
            integration = .none
            removedObligations.insert(.integrationUninstallRetry)
        case .rollback:
            integration = .none
            removedObligations.insert(.integrationRollbackRepair)
        case .adoptMixed:
            integration = .none
            removedObligations.insert(.integrationMixedAdoption)
        case .ownershipReceiptReset, .persistEmergency, .artifactOnly:
            integration = priorSnapshot.integration
        }
        let target = emergencyPersistenceTarget(
            priorSnapshot: priorSnapshot,
            integration: integration,
            removing: removedObligations,
            inserting: insertsArtifactCleanup ? [.integrationArtifactCleanup] : []
        )
        return EmergencyIntegrationRecovery(receipt: receipt, action: .persist(target))
    }

    private static func emergencyPersistenceTarget(
        priorSnapshot: OwnershipSnapshot,
        integration: PersistentIntegrationOwnership,
        removing removedObligations: Set<OutstandingObligation>,
        inserting insertedObligations: Set<OutstandingObligation>
    ) -> EmergencyPersistenceTarget {
        var obligations = priorSnapshot.obligations
        obligations.remove(.ownershipReceiptRepair)
        obligations.remove(.integrationPersistenceRetry)
        if let emergency = priorSnapshot.emergencyIntegrationRecovery {
            obligations.remove(emergency.obligation)
        }
        obligations.subtract(removedObligations)
        obligations.formUnion(insertedObligations)
        return EmergencyPersistenceTarget(integration: integration, obligations: obligations)
    }

    private func applyRepair(
        _ result: RepairResult,
        recording: RepairRecordingResult,
        plan: RepairPlan,
        originalPhase: AppPhase
    ) {
        let snapshot = recording.snapshot
        syncOwnership(snapshot)
        guard recording.wasPersisted else {
            phase = .repairRequired
            presentedError = .operationFailed
            return
        }
        switch result {
        case .success:
            if originalPhase == .repairRequired, outstandingObligations.isEmpty {
                presentedError = nil
                phase = pendingCredentials == nil ? .onboarding : .integrationReview
            }
        case .emergencyPersistence:
            if !outstandingObligations.isEmpty {
                phase = .repairRequired
                presentedError = Self.presentationError(for: snapshot)
            } else if snapshot.monitoringOwned {
                phase = .monitoring
                presentedError = nil
            } else if outstandingObligations.isEmpty {
                phase = pendingCredentials == nil ? .onboarding : .integrationReview
                presentedError = nil
            }
        case .artifactCleanupRequired:
            phase = .repairRequired
        case .legacyArtifactCleanupRequired:
            phase = .repairRequired
        case .artifactVerifiedClean:
            if originalPhase == .repairRequired, outstandingObligations.isEmpty {
                presentedError = nil
                phase = pendingCredentials == nil ? .onboarding : .integrationReview
            }
        case .artifactRetained:
            phase = .repairRequired
        case .invalidAdoptionReceipt:
            phase = .repairRequired
            presentedError = .integrationConflict
        case let .failure(error):
            phase = .repairRequired
            presentedError = error
        case .cancelled:
            break
        case .reconciled:
            ownsMonitoring = snapshot.monitoringOwned
            if snapshot.obligations.isEmpty {
                reconcileEmptyLedgerPresentation(snapshot)
            } else {
                phase = .repairRequired
                presentedError = Self.presentationError(for: snapshot)
            }
        }
    }

    private var hasActionableIntegrationObligation: Bool {
        outstandingObligations.contains(.integrationUninstallRetry)
            || outstandingObligations.contains(.integrationRollbackRepair)
            || outstandingObligations.contains(.integrationMixedAdoption)
    }

    private var hasIntegrationObligation: Bool {
        hasActionableIntegrationObligation
            || outstandingObligations.contains(.integrationArtifactCleanup)
            || outstandingObligations.contains(.integrationPersistenceRetry)
    }

    private static func presentationError(for snapshot: OwnershipSnapshot) -> PresentationError {
        let integrationObligations: Set<OutstandingObligation> = [
            .integrationUninstallRetry,
            .integrationRollbackRepair,
            .integrationMixedAdoption,
            .integrationArtifactCleanup,
            .integrationPersistenceRetry
        ]
        return snapshot.obligations.isDisjoint(with: integrationObligations)
            ? .operationFailed
            : .integrationConflict
    }

    private func beginObservation() async {
        let observation = await Self.preparedObservation(from: monitor)
        guard !Task.isCancelled else { return }
        installObservation(observation)
    }

    private static func preparedObservation(
        from monitor: any MonitoringOrchestrating
    ) async -> PreparedObservation {
        let snapshot = await monitor.currentSnapshot()
        let stream = await monitor.updates()
        return PreparedObservation(snapshot: snapshot, stream: stream)
    }

    private func installObservation(_ observation: PreparedObservation) {
        monitorEpoch &+= 1
        let epoch = monitorEpoch
        observationTask?.cancel()
        observationTask = nil
        apply(observation.snapshot)
        let id = UUID()
        observationID = id
        observationTask = Task { [weak self] in
            var iterator = observation.stream.makeAsyncIterator()
            while let update = await iterator.next() {
                guard !Task.isCancelled else { return }
                do {
                    guard let owner = self,
                          owner.observationID == id,
                          epoch == owner.monitorEpoch else { return }
                    owner.apply(update)
                }
            }
            guard !Task.isCancelled else { return }
            self?.observationEnded(id: id, epoch: epoch)
        }
    }

    private func cancelObservation(resetState: Bool) {
        monitorEpoch &+= 1
        observationID = nil
        observationTask?.cancel()
        observationTask = nil
        if resetState {
            currentState = .idle
            sessions = []
        }
    }

    private func observationEnded(id: UUID, epoch: UInt64) {
        guard observationID == id, monitorEpoch == epoch else { return }
        observationID = nil
        observationTask = nil
        connectionStatus = .disconnected
        currentState = .idle
        sessions = []
    }

    private func apply(_ snapshot: MonitoringSnapshot) {
        currentState = snapshot.state
        sessions = snapshot.sessions
        connectionStatus = snapshot.connection
    }

    private static func validatedCredentials(from draft: ConnectionDraft) throws -> TuyaCredentials {
        let endpointText = draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let accessID = draft.accessID.trimmingCharacters(in: .whitespacesAndNewlines)
        let accessSecret = draft.accessSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceID = draft.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !accessID.isEmpty, !accessSecret.isEmpty, !deviceID.isEmpty else {
            throw ValidationError.invalidCredential
        }
        guard let endpoint = URL(string: endpointText),
              let dataCenter = TuyaDataCenter(endpoint: endpoint) else {
            throw ValidationError.invalidEndpoint
        }
        return TuyaCredentials(
            endpoint: dataCenter.endpoint,
            accessID: accessID,
            accessSecret: accessSecret,
            deviceID: deviceID
        )
    }

    private static func maskedIdentifier(_ value: String) -> String {
        "••••" + value.suffix(4)
    }

    private static func integrationOwnership(
        for receipt: IntegrationInstallReceipt
    ) -> PersistentIntegrationOwnership {
        switch receipt.overallOwnership {
        case .fresh: .uninstallable(receipt)
        case .fullyPreexisting: .preexisting(receipt)
        case .mixed: .mixed(receipt)
        }
    }

    private static func replacingReceipt(
        in ownership: PersistentIntegrationOwnership,
        with receipt: IntegrationInstallReceipt
    ) -> PersistentIntegrationOwnership {
        switch ownership {
        case .none: .none
        case .uninstallable: .uninstallable(receipt)
        case .preexisting: .preexisting(receipt)
        case .mixed: .mixed(receipt)
        case .uncertain: .uncertain(receipt)
        }
    }

    private static func isCommittedCleanup(_ error: IntegrationError) -> Bool {
        switch error {
        case .artifactCleanupFailure, .committedWithCleanupFailure,
             .committedWithReceiptCleanupFailure:
            true
        default:
            false
        }
    }

    private static func committedReceipt(from error: IntegrationError) -> IntegrationInstallReceipt? {
        guard case let .committedWithReceiptCleanupFailure(receipt, _) = error,
              receipt.isValid,
              receipt.hasVerifiableFingerprints else { return nil }
        return receipt
    }

    private static func presentationError(for error: any Error) -> PresentationError {
        if let validation = error as? ValidationError {
            switch validation {
            case .invalidCredential: return .invalidCredential
            case .invalidEndpoint: return .invalidEndpoint
            }
        }
        if let internalError = error as? InternalError, internalError == .loginApprovalRequired {
            return .loginApprovalRequired
        }
        if let tuya = error as? TuyaClientError {
            switch tuya {
            case .invalidEndpoint: return .invalidEndpoint
            case .authenticationFailure: return .invalidCredential
            case .transport: return .bulbOffline
            case .httpStatus(429): return .rateLimited
            case .httpStatus(401), .httpStatus(403): return .invalidCredential
            case .httpStatus(408), .httpStatus(500...599): return .bulbOffline
            case .httpStatus, .malformedResponse, .apiFailure: return .operationFailed
            }
        }
        if error is CapabilityError { return .unsupportedBulb }
        if error is IntegrationError { return .integrationConflict }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed:
                return .bulbOffline
            default:
                return .operationFailed
            }
        }
        return .operationFailed
    }
}

@MainActor
fileprivate final class AppPresentationHandle: @unchecked Sendable {
    nonisolated let id = UUID()
    private weak var owner: AppViewModel?

    func attach(_ owner: AppViewModel) {
        self.owner = owner
    }

    var isAlive: Bool { owner != nil }

    func commitSharedCleanup(_ snapshot: OwnershipSnapshot) {
        owner?.commitSharedCleanup(snapshot)
    }
}

private enum ValidationError: Error {
    case invalidCredential
    case invalidEndpoint
}

private enum InternalError: Error {
    case loginApprovalRequired
    case previousCredentialStoreUnavailable
}

public struct OwnershipSnapshot: Equatable, Sendable {
    public var integration: PersistentIntegrationOwnership
    public var credentials: PersistentCredentialOwnership
    public var login: PersistentLoginOwnership
    public var monitoringOwned: Bool
    public var obligations: Set<OutstandingObligation>
    public var ownershipReceiptResetEligible: Bool
    public var emergencyIntegrationRecovery: EmergencyIntegrationRecovery?

    public init(
        integration: PersistentIntegrationOwnership = .none,
        credentials: PersistentCredentialOwnership = .none,
        login: PersistentLoginOwnership = .none,
        monitoringOwned: Bool = false,
        obligations: Set<OutstandingObligation> = [],
        ownershipReceiptResetEligible: Bool = false,
        emergencyIntegrationRecovery: EmergencyIntegrationRecovery? = nil
    ) {
        self.integration = integration
        self.credentials = credentials
        self.login = login
        self.monitoringOwned = monitoringOwned
        self.obligations = obligations
        self.ownershipReceiptResetEligible = ownershipReceiptResetEligible
        self.emergencyIntegrationRecovery = emergencyIntegrationRecovery
    }

    var loginRegistrationOwned: Bool { login != .none }

    var hasOwnedState: Bool {
        integration != .none
            || credentials != .none
            || login != .none
            || monitoringOwned
            || emergencyIntegrationRecovery != nil
            || !obligations.isEmpty
    }

    var canResumeMonitoringAfterRelaunch: Bool {
        guard !monitoringOwned,
              credentials != .none,
              obligations.isEmpty,
              emergencyIntegrationRecovery == nil else { return false }
        switch integration {
        case .uninstallable, .preexisting:
            return true
        case .none, .mixed, .uncertain:
            return false
        }
    }
}

public enum OwnershipMutation: Sendable {
    case integration(PersistentIntegrationOwnership)
    case credentials(PersistentCredentialOwnership)
    case login(PersistentLoginOwnership)
    case obligations(Set<OutstandingObligation>)
    case insertObligation(OutstandingObligation)
    case removeObligation(OutstandingObligation)
}

fileprivate enum EmergencyIntegrationAction: Equatable, Sendable {
    case uninstall
    case persist(EmergencyPersistenceTarget)
}

fileprivate struct EmergencyPersistenceTarget: Equatable, Sendable {
    let integration: PersistentIntegrationOwnership
    let obligations: Set<OutstandingObligation>
}

public struct EmergencyIntegrationRecovery: Equatable, Sendable {
    public let receipt: IntegrationInstallReceipt
    fileprivate let action: EmergencyIntegrationAction

    public var pendingIntegrationOwnership: PersistentIntegrationOwnership? {
        guard case let .persist(target) = action else { return nil }
        return target.integration
    }

    public var pendingObligations: Set<OutstandingObligation>? {
        guard case let .persist(target) = action else { return nil }
        return target.obligations
    }

    fileprivate var obligation: OutstandingObligation {
        switch action {
        case .uninstall: .integrationUninstallRetry
        case .persist: .integrationPersistenceRetry
        }
    }

    fileprivate init(receipt: IntegrationInstallReceipt, action: EmergencyIntegrationAction) {
        self.receipt = receipt
        self.action = action
    }
}

public actor AppOwnershipLedger {
    private struct LeaseWaiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID?, Never>
    }

    private let store: any SetupOwnershipStoring
    private var value = OwnershipSnapshot()
    private var hydrated = false
    private var hydrationFailure: SetupOwnershipStoreError?
    private var ownershipReceiptResetEligible = false
    private var emergencyIntegrationRecovery: EmergencyIntegrationRecovery?
    private var persistenceBusy = false
    private var persistenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var presentationHandlesByID: [UUID: AppPresentationHandle] = [:]
    private var activeLease: UUID?
    private var leaseWaiters: [LeaseWaiter] = []
#if DEBUG
    private var leaseCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var shouldBlockNextLeaseReleaseReturn = false
    private var blockedLeaseRelease = false
    private var blockedLeaseReleaseContinuation: CheckedContinuation<Void, Never>?
    private var blockedLeaseReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldBlockNextCancellableLeaseAcquisitionReturn = false
    private var blockedCancellableLeaseAcquisition = false
    private var blockedCancellableLeaseAcquisitionContinuation: CheckedContinuation<Void, Never>?
    private var blockedCancellableLeaseAcquisitionWaiters: [CheckedContinuation<Void, Never>] = []
#endif

    public init(store: any SetupOwnershipStoring = MemorySetupOwnershipStore()) {
        self.store = store
    }

    public func hydrate() async throws {
        await acquirePersistenceAccess()
        defer { releasePersistenceAccess() }
        try await hydrateWithoutPersistenceGate()
    }

    private func hydrateWithoutPersistenceGate() async throws {
        guard !hydrated else {
            if let hydrationFailure { throw hydrationFailure }
            return
        }
        do {
            if let receipt = try await store.load() {
                guard receipt.isValid else { throw SetupOwnershipStoreError.malformedReceipt }
                value = OwnershipSnapshot(
                    integration: receipt.integration,
                    credentials: receipt.credential,
                    login: receipt.login,
                    obligations: receipt.obligations
                )
            } else {
                value = OwnershipSnapshot()
            }
            hydrated = true
            hydrationFailure = nil
            ownershipReceiptResetEligible = false
        } catch let error as SetupOwnershipStoreError {
            value = OwnershipSnapshot(obligations: [.ownershipReceiptRepair])
            hydrated = true
            hydrationFailure = error
            ownershipReceiptResetEligible = Self.isResetEligible(error)
            throw error
        } catch {
            value = OwnershipSnapshot(obligations: [.ownershipReceiptRepair])
            hydrated = true
            hydrationFailure = .readFailed
            ownershipReceiptResetEligible = false
            throw SetupOwnershipStoreError.readFailed
        }
    }

    public func snapshot() -> OwnershipSnapshot {
        var snapshot = value
        snapshot.ownershipReceiptResetEligible = ownershipReceiptResetEligible
        snapshot.emergencyIntegrationRecovery = emergencyIntegrationRecovery
        if let emergencyIntegrationRecovery {
            snapshot.obligations.insert(emergencyIntegrationRecovery.obligation)
        }
        return snapshot
    }

    public func update(_ mutation: OwnershipMutation) async throws {
        try await update([mutation])
    }

    public func update(_ mutations: [OwnershipMutation]) async throws {
        await acquirePersistenceAccess()
        defer { releasePersistenceAccess() }
        if !hydrated { try await hydrateWithoutPersistenceGate() }
        var proposed = value
        for mutation in mutations {
            switch mutation {
            case let .integration(ownership): proposed.integration = ownership
            case let .credentials(ownership): proposed.credentials = ownership
            case let .login(ownership): proposed.login = ownership
            case let .obligations(obligations): proposed.obligations = obligations
            case let .insertObligation(obligation): proposed.obligations.insert(obligation)
            case let .removeObligation(obligation): proposed.obligations.remove(obligation)
            }
        }
        let receipt = SetupOwnershipReceipt(
            integration: proposed.integration,
            credential: proposed.credentials,
            login: proposed.login,
            obligations: proposed.obligations
        )
        do {
            if receipt.isEmpty {
                try await store.delete()
            } else {
                try await store.save(receipt)
            }
            value = proposed
            hydrationFailure = nil
            ownershipReceiptResetEligible = false
        } catch let error as SetupOwnershipStoreError {
            value.obligations.insert(.ownershipReceiptRepair)
            ownershipReceiptResetEligible = false
            throw error
        } catch {
            value.obligations.insert(.ownershipReceiptRepair)
            ownershipReceiptResetEligible = false
            throw SetupOwnershipStoreError.writeFailed
        }
    }

    public func resetInvalidReceipt() async throws {
        await acquirePersistenceAccess()
        defer { releasePersistenceAccess() }
        guard ownershipReceiptResetEligible,
              value.obligations.contains(.ownershipReceiptRepair) else {
            throw SetupOwnershipStoreError.resetNotRequired
        }
        try await store.resetInvalidReceipt()
        value = OwnershipSnapshot()
        hydrated = true
        hydrationFailure = nil
        ownershipReceiptResetEligible = false
    }

    fileprivate func setEmergencyIntegrationRecovery(_ recovery: EmergencyIntegrationRecovery) {
        emergencyIntegrationRecovery = recovery
    }

    fileprivate func clearEmergencyIntegrationRecovery() {
        emergencyIntegrationRecovery = nil
    }

    private static func isResetEligible(_ error: SetupOwnershipStoreError) -> Bool {
        error == .malformedReceipt || error == .unsupportedVersion || error == .receiptTooLarge
    }

    private func acquirePersistenceAccess() async {
        if !persistenceBusy {
            persistenceBusy = true
            return
        }
        await withCheckedContinuation { persistenceWaiters.append($0) }
    }

    private func releasePersistenceAccess() {
        guard !persistenceWaiters.isEmpty else {
            persistenceBusy = false
            return
        }
        persistenceWaiters.removeFirst().resume()
    }

    fileprivate func registerPresentationHandle(_ handle: AppPresentationHandle) async {
        await pruneDeadPresentationHandles()
        presentationHandlesByID[handle.id] = handle
    }

    fileprivate func presentationHandles() async -> [AppPresentationHandle] {
        await pruneDeadPresentationHandles()
        return Array(presentationHandlesByID.values)
    }

    private func pruneDeadPresentationHandles() async {
        var deadIDs: [UUID] = []
        for (id, handle) in presentationHandlesByID {
            if !(await handle.isAlive) { deadIDs.append(id) }
        }
        for id in deadIDs { presentationHandlesByID.removeValue(forKey: id) }
    }

    fileprivate func acquireLease() async -> UUID {
        if activeLease == nil {
            let token = UUID()
            activeLease = token
            return token
        }
        let id = UUID()
        let token: UUID? = await withCheckedContinuation {
            leaseWaiters.append(LeaseWaiter(id: id, continuation: $0))
            notifyLeaseWaiterCountChanged()
        }
        guard let token else {
            preconditionFailure("A durable lease waiter cannot be canceled")
        }
        return token
    }

    fileprivate func acquireLeaseForCaller() async -> UUID? {
        let token: UUID?
        let wasQueued: Bool
        if activeLease == nil {
            let immediateToken = UUID()
            activeLease = immediateToken
            token = immediateToken
            wasQueued = false
        } else {
            wasQueued = true
            let id = UUID()
            token = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<UUID?, Never>) in
                    if Task.isCancelled {
                        continuation.resume(returning: nil)
                    } else {
                        leaseWaiters.append(LeaseWaiter(id: id, continuation: continuation))
                        notifyLeaseWaiterCountChanged()
                    }
                }
            } onCancel: {
                Task { await self.cancelLeaseWaiter(id) }
            }
        }
        if wasQueued, token != nil { await blockCancellableLeaseAcquisitionReturnIfNeeded() }
        if wasQueued, Task.isCancelled, let token {
            await releaseLease(token)
            return nil
        }
        return token
    }

    private func cancelLeaseWaiter(_ id: UUID) {
        guard let index = leaseWaiters.firstIndex(where: { $0.id == id }) else { return }
        leaseWaiters.remove(at: index).continuation.resume(returning: nil)
        notifyLeaseWaiterCountChanged()
    }

    fileprivate func releaseLease(_ token: UUID) async {
        guard activeLease == token else { return }
        guard !leaseWaiters.isEmpty else {
            activeLease = nil
            await blockLeaseReleaseReturnIfNeeded()
            return
        }
        let next = UUID()
        activeLease = next
        leaseWaiters.removeFirst().continuation.resume(returning: next)
        notifyLeaseWaiterCountChanged()
        await blockLeaseReleaseReturnIfNeeded()
    }

#if DEBUG
    func livePresentationHandleCountForTesting() async -> Int {
        await pruneDeadPresentationHandles()
        return presentationHandlesByID.count
    }

    func acquireDurableLeaseForTesting() async -> UUID { await acquireLease() }

    func releaseLeaseForTesting(_ token: UUID) async { await releaseLease(token) }

    func leaseWaiterCountForTesting() -> Int { leaseWaiters.count }

    func waitForLeaseWaiterCount(_ expected: Int) async {
        if leaseWaiters.count == expected { return }
        await withCheckedContinuation { leaseCountWaiters.append((expected, $0)) }
    }

    func blockNextLeaseReleaseReturnForTesting() {
        shouldBlockNextLeaseReleaseReturn = true
    }

    func waitForBlockedLeaseReleaseForTesting() async {
        if blockedLeaseRelease { return }
        await withCheckedContinuation { blockedLeaseReleaseWaiters.append($0) }
    }

    func resumeBlockedLeaseReleaseForTesting() {
        blockedLeaseReleaseContinuation?.resume()
        blockedLeaseReleaseContinuation = nil
    }

    func blockNextCancellableLeaseAcquisitionReturnForTesting() {
        shouldBlockNextCancellableLeaseAcquisitionReturn = true
    }

    func waitForBlockedCancellableLeaseAcquisitionForTesting() async {
        if blockedCancellableLeaseAcquisition { return }
        await withCheckedContinuation { blockedCancellableLeaseAcquisitionWaiters.append($0) }
    }

    func resumeBlockedCancellableLeaseAcquisitionForTesting() {
        blockedCancellableLeaseAcquisitionContinuation?.resume()
        blockedCancellableLeaseAcquisitionContinuation = nil
    }

    private func blockCancellableLeaseAcquisitionReturnIfNeeded() async {
        guard shouldBlockNextCancellableLeaseAcquisitionReturn else { return }
        shouldBlockNextCancellableLeaseAcquisitionReturn = false
        blockedCancellableLeaseAcquisition = true
        let waiters = blockedCancellableLeaseAcquisitionWaiters
        blockedCancellableLeaseAcquisitionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { blockedCancellableLeaseAcquisitionContinuation = $0 }
        blockedCancellableLeaseAcquisition = false
    }

    private func blockLeaseReleaseReturnIfNeeded() async {
        guard shouldBlockNextLeaseReleaseReturn else { return }
        shouldBlockNextLeaseReleaseReturn = false
        blockedLeaseRelease = true
        let waiters = blockedLeaseReleaseWaiters
        blockedLeaseReleaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { blockedLeaseReleaseContinuation = $0 }
        blockedLeaseRelease = false
    }

    private func notifyLeaseWaiterCountChanged() {
        let ready = leaseCountWaiters.filter { $0.0 == leaseWaiters.count }
        leaseCountWaiters.removeAll { $0.0 == leaseWaiters.count }
        for waiter in ready { waiter.1.resume() }
    }
#else
    private func notifyLeaseWaiterCountChanged() {}
    private func blockLeaseReleaseReturnIfNeeded() async {}
    private func blockCancellableLeaseAcquisitionReturnIfNeeded() async {}
#endif

    fileprivate func setIntegration(_ ownership: PersistentIntegrationOwnership) async throws {
        try await update(.integration(ownership))
    }
    fileprivate func setCredentials(_ ownership: PersistentCredentialOwnership) async throws {
        try await update(.credentials(ownership))
    }
    func setLoginOwned(_ owned: Bool) async throws {
        try await update(.login(owned ? .registered : .none))
    }
    func setMonitoringOwned(_ owned: Bool) { value.monitoringOwned = owned }
    func insert(_ obligation: OutstandingObligation) async throws {
        try await update(.insertObligation(obligation))
    }
    func remove(_ obligation: OutstandingObligation) async throws {
        try await update(.removeObligation(obligation))
    }
}

private enum ConnectResult {
    case success(TuyaCredentials, [IntegrationPreview])
    case failure(PresentationError)
    case cancelled
}

#if DEBUG
enum OperationKind: Hashable {
    case connect, approval, pause, resume, repair, shutdown, disconnect
}
#endif

private enum ApprovalResult {
    case success(PreparedObservation, OwnershipSnapshot)
    case failure(PresentationError?, OwnershipSnapshot)
}

private struct PreparedObservation {
    let snapshot: MonitoringSnapshot
    let stream: AsyncStream<MonitoringSnapshot>
}

private enum RepairPlan: Equatable {
    case ownershipReceiptReset
    case persistEmergency
    case uninstall
    case rollback
    case adoptMixed
    case artifactOnly
    case health
}

private enum RepairResult {
    case success(updatedReceipt: IntegrationInstallReceipt?)
    case emergencyPersistence(EmergencyIntegrationRecovery)
    case artifactCleanupRequired(updatedReceipt: IntegrationInstallReceipt?)
    case legacyArtifactCleanupRequired
    case artifactVerifiedClean
    case artifactRetained
    case invalidAdoptionReceipt
    case failure(PresentationError)
    case cancelled
    case reconciled
}

private enum RepairRecordingResult {
    case recorded(OwnershipSnapshot)
    case persistenceFailed(OwnershipSnapshot)

    var snapshot: OwnershipSnapshot {
        switch self {
        case let .recorded(snapshot), let .persistenceFailed(snapshot): snapshot
        }
    }

    var wasPersisted: Bool {
        if case .recorded = self { return true }
        return false
    }
}

private enum PauseResult {
    case paused
    case cancelledAndRestored
    case pausedWithFailure(PresentationError)
}

@MainActor
private final class SharedOperation {
    private let task: Task<Void, Never>
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var completed = false
    private var finishAction: (() -> Void)?
#if DEBUG
    private var waiterCountBarriers: [(Int, CheckedContinuation<Void, Never>)] = []
#endif

    init(task: Task<Void, Never>) {
        self.task = task
        Task { [weak self, task] in
            await task.value
            self?.finish()
        }
    }

    func wait() async {
        guard !completed else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if completed {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
#if DEBUG
                    releaseWaiterCountBarriers()
#endif
                    if Task.isCancelled {
                        cancelWaiter(id)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id)
            }
        }
    }

    func waitForDriverCompletion() async {
        await task.value
    }

    func onFinish(_ action: @escaping () -> Void) {
        if completed {
            action()
        } else {
            finishAction = action
        }
    }

    nonisolated func cancel() {
        task.cancel()
    }

#if DEBUG
    func waitForWaiterCount(_ count: Int) async {
        if waiters.count >= count { return }
        await withCheckedContinuation { waiterCountBarriers.append((count, $0)) }
    }

    private func releaseWaiterCountBarriers() {
        let ready = waiterCountBarriers.filter { waiters.count >= $0.0 }
        waiterCountBarriers.removeAll { waiters.count >= $0.0 }
        for barrier in ready { barrier.1.resume() }
    }
#endif

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume()
        if waiters.isEmpty {
            task.cancel()
        }
    }

    private func finish() {
        guard !completed else { return }
        completed = true
        let continuations = waiters.values
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
        let action = finishAction
        finishAction = nil
        action?()
    }
}
