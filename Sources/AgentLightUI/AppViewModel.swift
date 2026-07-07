import Foundation
import Observation
import AgentLightCore

public protocol TuyaConnectionVerifying: Sendable {
    func verify(_ credentials: TuyaCredentials) async throws -> ResolvedLightCapabilities
}

@MainActor
public protocol AppViewModeling: AnyObject {
    var phase: AppPhase { get }
    var connectionStatus: LightConnectionStatus { get }
    var currentState: AgentState { get }
    var sessions: [AgentEvent] { get }
    var integrationPreviews: [IntegrationPreview] { get }
    var presentedError: PresentationError? { get }
    var outstandingObligations: Set<OutstandingObligation> { get }
    var loginItemStatus: LoginItemStatus { get }
    func connect(using draft: ConnectionDraft) async
    func approveIntegrations() async
    func pause() async
    func resume() async
    func repairIntegrations() async
    func disconnect() async
    func observeMonitoring() async
    func synchronizeOwnership() async
    func requestLaunchAtLogin() async
}

public extension AppViewModeling {
    func synchronizeOwnership() async {}
    var loginItemStatus: LoginItemStatus { .unknown }
    func requestLaunchAtLogin() async {}
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

public enum OutstandingObligation: Hashable, Sendable {
    case integrationUninstallRetry
    case integrationRollbackRepair
    case integrationMixedAdoption
    case integrationArtifactCleanup
    case credentialRestore
    case credentialDelete
    case loginRegistrationCleanup
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
    @ObservationIgnored private var connectTask: SharedOperation?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var observationID: UUID?
    @ObservationIgnored private var approvalTask: SharedOperation?
    @ObservationIgnored private var approvalID: UUID?
    @ObservationIgnored private var pauseTask: SharedOperation?
    @ObservationIgnored private var resumeTask: SharedOperation?
    @ObservationIgnored private var repairTask: SharedOperation?
    @ObservationIgnored private var disconnectTask: SharedOperation?
    @ObservationIgnored private var integrationOwnership: IntegrationOwnership = .none
    @ObservationIgnored private var credentialOwnership: CredentialOwnership = .none
    @ObservationIgnored private var loginRegistrationOwned = false
    @ObservationIgnored private var ownsMonitoring = false
#if DEBUG
    @ObservationIgnored private var actionEntryCounts: [OperationKind: Int] = [:]
    @ObservationIgnored private var actionEntryBarriers: [(OperationKind, Int, CheckedContinuation<Void, Never>)] = []
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
            let existing = await ledger.snapshot()
            guard !Task.isCancelled else {
                self?.cancelApproval(id: id)
                await ledger.releaseLease(lease)
                return
            }
            await ledger.registerPresentationHandle(presentationHandle)
            guard !Task.isCancelled else {
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
        guard await hydrateOwnership() else { return }
        if let disconnectTask {
            await disconnectTask.wait()
            return
        }
        if let resumeTask {
            await resumeTask.wait()
        }
        if let pauseTask {
            await pauseTask.wait()
            return
        }
        guard phase == .monitoring else { return }
        let monitor = monitor
        let task = Task { [weak self, monitor] in
            await monitor.pause()
            if Task.isCancelled {
                do {
                    try await monitor.resume()
                    self?.applyPause(.cancelledAndRestored)
                } catch {
                    self?.applyPause(.pausedWithFailure(Self.presentationError(for: error)))
                }
                return
            }
            self?.applyPause(.paused)
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
            break
        case .paused:
            cancelObservation(resetState: true)
            phase = .paused
            presentedError = nil
        case let .pausedWithFailure(error):
            cancelObservation(resetState: true)
            phase = .paused
            presentedError = error
        }
    }

    public func resume() async {
#if DEBUG
        recordActionEntry(.resume)
#endif
        guard await hydrateOwnership() else { return }
        if let disconnectTask {
            await disconnectTask.wait()
            return
        }
        if let pauseTask {
            await pauseTask.wait()
        }
        if let resumeTask {
            await resumeTask.wait()
            return
        }
        guard phase == .paused else { return }
        let monitor = monitor
        let task = Task { [weak self, monitor] in
            do {
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
                self.installObservation(observation)
                guard !Task.isCancelled, self.phase == .paused else { return }
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
        let requestedPlan = Self.repairPlan(for: outstandingObligations, phase: originalPhase)
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
                    snapshot: current,
                    plan: requestedPlan ?? .health,
                    originalPhase: originalPhase
                )
                await ledger.releaseLease(lease)
                return
            }
            let result = await Self.performRepair(plan, using: integrations)
            let snapshot = await Self.recordRepair(
                result,
                plan: plan,
                priorIntegration: current.integration,
                ledger: ledger
            )
            self?.applyRepair(result, snapshot: snapshot, plan: plan, originalPhase: originalPhase)
            await ledger.releaseLease(lease)
        }
        let operation = SharedOperation(task: task)
        repairTask = operation
        operation.onFinish { [weak self, weak operation] in
            guard let self, self.repairTask === operation else { return }
            self.repairTask = nil
        }
        await operation.wait()
    }

    public func disconnect() async {
#if DEBUG
        recordActionEntry(.disconnect)
#endif
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

    public func requestLaunchAtLogin() async {
        guard phase == .monitoring || phase == .paused || phase == .repairRequired,
              let lease = await ownershipLedger.acquireLeaseForCaller() else { return }
        do {
            let transition = try loginItem.setEnabled(true)
            loginItemStatus = transition.current
            if transition.didRegister {
                loginRegistrationOwned = true
                await ownershipLedger.setLoginOwned(true)
            }
            presentedError = transition.current == .requiresApproval ? .loginApprovalRequired : nil
        } catch {
            loginItemStatus = loginItem.status()
            presentedError = .operationFailed
        }
        await ownershipLedger.releaseLease(lease)
    }

    public func observeMonitoring() async {
        guard await hydrateOwnership() else { return }
        guard ownsMonitoring, phase == .monitoring || phase == .approving else { return }
        guard observationTask == nil else { return }
        await beginObservation()
    }

    public func synchronizeOwnership() async {
        connectGeneration &+= 1
        let pendingConnect = connectTask
        pendingConnect?.cancel()
        await pendingConnect?.wait()
        guard let lease = await ownershipLedger.acquireLeaseForCaller() else { return }
        await ownershipLedger.registerPresentationHandle(presentationHandle)
        let snapshot = await ownershipLedger.snapshot()
        syncOwnership(snapshot)
        ownsMonitoring = snapshot.monitoringOwned
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
        guard let lease = await ownershipLedger.acquireLeaseForCaller() else { return false }
        await ownershipLedger.registerPresentationHandle(presentationHandle)
        let snapshot = await ownershipLedger.snapshot()
        syncOwnership(snapshot)
        ownsMonitoring = snapshot.monitoringOwned
        guard !snapshot.obligations.isEmpty else {
            reconcileEmptyLedgerPresentation(snapshot)
            await ownershipLedger.releaseLease(lease)
            return true
        }
        connectGeneration &+= 1
        connectTask?.cancel()
        phase = .repairRequired
        presentedError = Self.presentationError(for: snapshot)
        await ownershipLedger.releaseLease(lease)
        return true
    }

    private func reconcileEmptyLedgerPresentation(_ snapshot: OwnershipSnapshot) {
        guard !snapshot.hasOwnedState, phase == .repairRequired else { return }
        pendingCredentials = nil
        integrationPreviews = []
        phase = .onboarding
        presentedError = nil
    }

#if DEBUG
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
        case .disconnect: operation = disconnectTask
        case .connect: operation = connectTask
        }
        await operation?.waitForWaiterCount(count)
    }
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
            integrationPreviews = previews
            presentedError = nil
            phase = .integrationReview
        case let .failure(error):
            pendingCredentials = nil
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
                guard receipt.isValid else {
                    await ledger.setIntegration(.mixed)
                    await ledger.insert(.integrationMixedAdoption)
                    return .failure(.integrationConflict, await ledger.snapshot())
                }
                await ledger.setIntegration(Self.integrationOwnership(for: receipt))
            } catch let error as IntegrationError {
                switch error {
                case let .committedWithReceiptCleanupFailure(receipt, _):
                    if receipt.isValid {
                        await ledger.setIntegration(Self.integrationOwnership(for: receipt))
                    } else {
                        await ledger.setIntegration(.mixed)
                        await ledger.insert(.integrationMixedAdoption)
                    }
                    await ledger.insert(.integrationArtifactCleanup)
                    return await compensatedApprovalResult(
                        error: .integrationConflict,
                        integrations: integrations,
                        credentials: credentials,
                        loginItem: loginItem,
                        monitor: monitor,
                        ledger: ledger
                    )
                case .committedWithCleanupFailure:
                    await ledger.setIntegration(.mixed)
                    await ledger.insert(.integrationMixedAdoption)
                    await ledger.insert(.integrationArtifactCleanup)
                    return .failure(.integrationConflict, await ledger.snapshot())
                case .rollbackFailed:
                    await ledger.setIntegration(.uncertain)
                    await ledger.insert(.integrationRollbackRepair)
                    return .failure(.integrationConflict, await ledger.snapshot())
                default:
                    throw error
                }
            }

            try Task.checkCancellation()
            let previous = try credentials.load()
            try credentials.save(pendingCredentials)
            await ledger.setCredentials(previous.map(CredentialOwnership.replaced) ?? .created)

            try Task.checkCancellation()
            let transition = try loginItem.setEnabled(true)
            if transition.didRegister { await ledger.setLoginOwned(true) }
            guard transition.current == .enabled else { throw InternalError.loginApprovalRequired }

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
                    await ledger.setLoginOwned(false)
                    await ledger.remove(.loginRegistrationCleanup)
                } else {
                    await ledger.insert(.loginRegistrationCleanup)
                }
            } catch {
                await ledger.insert(.loginRegistrationCleanup)
            }
        }
        if snapshot.credentials != .none {
            do {
                switch snapshot.credentials {
                case .none: break
                case .created:
                    try credentials.delete()
                    await ledger.remove(.credentialDelete)
                case let .replaced(previous):
                    try credentials.save(previous)
                    await ledger.remove(.credentialRestore)
                }
                await ledger.setCredentials(.none)
            } catch {
                await ledger.insert(snapshot.credentials == .created ? .credentialDelete : .credentialRestore)
            }
        }
        snapshot = await ledger.snapshot()
        switch snapshot.integration {
        case .none:
            break
        case .preexisting:
            await ledger.setIntegration(.none)
        case .uninstallable:
            do {
                try await integrations.uninstall()
                await ledger.setIntegration(.none)
                await ledger.remove(.integrationUninstallRetry)
            } catch let error as IntegrationError where Self.isCommittedCleanup(error) {
                await ledger.setIntegration(.none)
                await ledger.remove(.integrationUninstallRetry)
                await ledger.insert(.integrationArtifactCleanup)
            } catch {
                await ledger.insert(.integrationUninstallRetry)
            }
        case .mixed:
            await ledger.insert(.integrationMixedAdoption)
        case .uncertain:
            await ledger.insert(.integrationRollbackRepair)
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
            installObservation(observation)
            phase = .monitoring
            presentedError = nil
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
        credentialOwnership = snapshot.credentials
        loginRegistrationOwned = snapshot.loginRegistrationOwned
        outstandingObligations = snapshot.obligations
    }

    private func finishDisconnect(_ snapshot: OwnershipSnapshot) {
        syncOwnership(snapshot)
        ownsMonitoring = snapshot.monitoringOwned

        pendingCredentials = nil
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

    private static func repairPlan(
        for obligations: Set<OutstandingObligation>,
        phase: AppPhase
    ) -> RepairPlan? {
        if obligations.contains(.integrationUninstallRetry) { return .uninstall }
        if obligations.contains(.integrationRollbackRepair) { return .rollback }
        if obligations.contains(.integrationArtifactCleanup) { return .artifactOnly }
        if obligations.contains(.integrationMixedAdoption) { return .adoptMixed }
        return phase == .monitoring || phase == .paused ? .health : nil
    }

    private static func repairPlan(
        _ plan: RepairPlan,
        isValidFor snapshot: OwnershipSnapshot
    ) -> Bool {
        switch plan {
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
        using integrations: any IntegrationInstalling
    ) async -> RepairResult {
        do {
            try Task.checkCancellation()
            switch plan {
            case .uninstall:
                try await integrations.uninstall()
            case .rollback, .health:
                try await integrations.repair()
            case .adoptMixed:
                let receipt = try await integrations.installWithReceipt()
                guard receipt.isValid else { return .invalidAdoptionReceipt }
            case .artifactOnly:
                return try await integrations.verifyArtifactCleanup()
                    ? .artifactVerifiedClean
                    : .artifactRetained
            }
            return .success
        } catch IntegrationError.artifactCleanupFailure {
            return .artifactCleanupRequired
        } catch let IntegrationError.committedWithReceiptCleanupFailure(receipt, _) {
            return receipt.isValid ? .artifactCleanupRequired : .legacyArtifactCleanupRequired
        } catch IntegrationError.committedWithCleanupFailure {
            return plan == .adoptMixed ? .legacyArtifactCleanupRequired : .artifactCleanupRequired
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(Self.presentationError(for: error))
        }
    }

    private static func recordRepair(
        _ result: RepairResult,
        plan: RepairPlan,
        priorIntegration: IntegrationOwnership,
        ledger: AppOwnershipLedger
    ) async -> OwnershipSnapshot {
        switch result {
        case .success:
            switch plan {
            case .uninstall:
                await ledger.remove(.integrationUninstallRetry)
                await ledger.setIntegration(.none)
            case .rollback:
                await ledger.remove(.integrationRollbackRepair)
                await ledger.setIntegration(.none)
            case .adoptMixed:
                await ledger.remove(.integrationMixedAdoption)
                await ledger.setIntegration(.none)
            case .health, .artifactOnly: break
            }
        case .artifactCleanupRequired:
            switch plan {
            case .uninstall: await ledger.remove(.integrationUninstallRetry)
            case .rollback: await ledger.remove(.integrationRollbackRepair)
            case .adoptMixed: await ledger.remove(.integrationMixedAdoption)
            case .health, .artifactOnly: break
            }
            await ledger.insert(.integrationArtifactCleanup)
            switch plan {
            case .uninstall, .rollback, .adoptMixed:
                await ledger.setIntegration(.none)
            case .health, .artifactOnly:
                await ledger.setIntegration(priorIntegration)
            }
        case .legacyArtifactCleanupRequired:
            await ledger.insert(.integrationArtifactCleanup)
        case .artifactVerifiedClean:
            await ledger.remove(.integrationArtifactCleanup)
        case .artifactRetained, .invalidAdoptionReceipt, .cancelled:
            break
        case .reconciled:
            break
        case .failure:
            if plan == .health { await ledger.insert(.integrationRollbackRepair) }
        }
        return await ledger.snapshot()
    }

    private func applyRepair(
        _ result: RepairResult,
        snapshot: OwnershipSnapshot,
        plan: RepairPlan,
        originalPhase: AppPhase
    ) {
        syncOwnership(snapshot)
        switch result {
        case .success:
            switch plan {
            case .uninstall:
                outstandingObligations.remove(.integrationUninstallRetry)
                integrationOwnership = .none
            case .rollback:
                outstandingObligations.remove(.integrationRollbackRepair)
                integrationOwnership = .none
            case .adoptMixed:
                outstandingObligations.remove(.integrationMixedAdoption)
                integrationOwnership = .none
            case .health, .artifactOnly:
                break
            }
            if originalPhase == .repairRequired, outstandingObligations.isEmpty {
                presentedError = nil
                phase = pendingCredentials == nil ? .onboarding : .integrationReview
            }
        case .artifactCleanupRequired:
            switch plan {
            case .uninstall: outstandingObligations.remove(.integrationUninstallRetry)
            case .rollback: outstandingObligations.remove(.integrationRollbackRepair)
            case .adoptMixed: outstandingObligations.remove(.integrationMixedAdoption)
            case .health, .artifactOnly: break
            }
            outstandingObligations.insert(.integrationArtifactCleanup)
            switch plan {
            case .uninstall, .rollback, .adoptMixed:
                integrationOwnership = .none
            case .health, .artifactOnly:
                break
            }
        case .legacyArtifactCleanupRequired:
            outstandingObligations.insert(.integrationArtifactCleanup)
            phase = .repairRequired
        case .artifactVerifiedClean:
            outstandingObligations.remove(.integrationArtifactCleanup)
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
            if plan == .health {
                outstandingObligations.insert(.integrationRollbackRepair)
            }
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
    }

    private static func presentationError(for snapshot: OwnershipSnapshot) -> PresentationError {
        let integrationObligations: Set<OutstandingObligation> = [
            .integrationUninstallRetry,
            .integrationRollbackRepair,
            .integrationMixedAdoption,
            .integrationArtifactCleanup
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
        guard let components = URLComponents(string: endpointText),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let endpoint = components.url else {
            throw ValidationError.invalidEndpoint
        }
        return TuyaCredentials(
            endpoint: endpoint,
            accessID: accessID,
            accessSecret: accessSecret,
            deviceID: deviceID
        )
    }

    private static func integrationOwnership(
        for receipt: IntegrationInstallReceipt
    ) -> IntegrationOwnership {
        switch receipt.overallOwnership {
        case .fresh: .uninstallable
        case .fullyPreexisting: .preexisting
        case .mixed: .mixed
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
}

fileprivate enum CredentialOwnership: Equatable, Sendable {
    case none
    case created
    case replaced(TuyaCredentials)
}

fileprivate enum IntegrationOwnership: Equatable, Sendable {
    case none
    case uninstallable
    case preexisting
    case mixed
    case uncertain
}

fileprivate struct OwnershipSnapshot: Sendable {
    var integration: IntegrationOwnership = .none
    var credentials: CredentialOwnership = .none
    var loginRegistrationOwned = false
    var monitoringOwned = false
    var obligations: Set<OutstandingObligation> = []

    var hasOwnedState: Bool {
        integration != .none
            || credentials != .none
            || loginRegistrationOwned
            || monitoringOwned
            || !obligations.isEmpty
    }
}

public actor AppOwnershipLedger {
    private struct LeaseWaiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID?, Never>
    }

    private var value = OwnershipSnapshot()
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

    public init() {}

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

    fileprivate func snapshot() -> OwnershipSnapshot { value }
    fileprivate func setIntegration(_ ownership: IntegrationOwnership) { value.integration = ownership }
    fileprivate func setCredentials(_ ownership: CredentialOwnership) { value.credentials = ownership }
    func setLoginOwned(_ owned: Bool) { value.loginRegistrationOwned = owned }
    func setMonitoringOwned(_ owned: Bool) { value.monitoringOwned = owned }
    func insert(_ obligation: OutstandingObligation) { value.obligations.insert(obligation) }
    func remove(_ obligation: OutstandingObligation) { value.obligations.remove(obligation) }
}

private enum ConnectResult {
    case success(TuyaCredentials, [IntegrationPreview])
    case failure(PresentationError)
    case cancelled
}

#if DEBUG
enum OperationKind: Hashable {
    case connect, approval, pause, resume, repair, disconnect
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
    case uninstall
    case rollback
    case adoptMixed
    case artifactOnly
    case health
}

private enum RepairResult {
    case success
    case artifactCleanupRequired
    case legacyArtifactCleanupRequired
    case artifactVerifiedClean
    case artifactRetained
    case invalidAdoptionReceipt
    case failure(PresentationError)
    case cancelled
    case reconciled
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
