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
    func connect(using draft: ConnectionDraft) async
    func approveIntegrations() async
    func pause() async
    func resume() async
    func repairIntegrations() async
    func disconnect() async
    func observeMonitoring() async
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

    @ObservationIgnored private let credentials: any CredentialStoring
    @ObservationIgnored private let integrations: any IntegrationInstalling
    @ObservationIgnored private let monitor: any MonitoringOrchestrating
    @ObservationIgnored private let loginItem: any LoginItemControlling
    @ObservationIgnored private let verifier: any TuyaConnectionVerifying
    @ObservationIgnored private let ownershipLedger = OwnershipLedger()

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
    @ObservationIgnored private var disconnectedCleanupComplete = false

    public init(
        credentials: any CredentialStoring,
        integrations: any IntegrationInstalling,
        monitor: any MonitoringOrchestrating,
        loginItem: any LoginItemControlling,
        verifier: any TuyaConnectionVerifying
    ) {
        self.credentials = credentials
        self.integrations = integrations
        self.monitor = monitor
        self.loginItem = loginItem
        self.verifier = verifier
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
        disconnectedCleanupComplete = false

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
        let task = Task { [weak self, integrations, credentials, monitor, ledger] in
            let result = await Self.runApproval(
                pendingCredentials: pendingCredentials,
                integrations: integrations,
                credentials: credentials,
                loginItem: loginItem,
                monitor: monitor,
                ledger: ledger
            )
            self?.applyApproval(result, id: id)
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

    public func pause() async {
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
        if let disconnectTask {
            await disconnectTask.wait()
            return
        }
        if let pauseTask { await pauseTask.wait() }
        if let resumeTask { await resumeTask.wait() }
        if let repairTask {
            await repairTask.wait()
            return
        }
        let originalPhase = phase
        guard originalPhase == .monitoring || originalPhase == .paused || originalPhase == .repairRequired else {
            return
        }
        let plan = repairPlan
        let integrations = integrations
        let ledger = ownershipLedger
        let task = Task { [weak self, integrations, ledger] in
            let result = await Self.performRepair(plan, using: integrations)
            let snapshot = await Self.recordRepair(result, plan: plan, ledger: ledger)
            self?.applyRepair(result, snapshot: snapshot, plan: plan, originalPhase: originalPhase)
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
        if let disconnectTask {
            await disconnectTask.wait()
            return
        }
        guard !disconnectedCleanupComplete else { return }
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
        let cleanupTask = Task { [monitor, integrations, credentials, ledger] in
            await pendingApproval?.wait()
            await pendingPause?.wait()
            await pendingResume?.wait()
            await pendingRepair?.wait()
            return await Self.cleanupOwnedState(
                integrations: integrations,
                credentials: credentials,
                loginItem: loginItem,
                monitor: monitor,
                ledger: ledger
            )
        }
        let task = Task { [weak self, cleanupTask] in
            let snapshot = await cleanupTask.value
            self?.finishDisconnect(snapshot)
        }
        let operation = SharedOperation(task: task)
        disconnectTask = operation
        operation.onFinish { [weak self, weak operation] in
            guard let self, self.disconnectTask === operation else { return }
            self.disconnectTask = nil
        }
        await operation.wait()
    }

    public func observeMonitoring() async {
        guard ownsMonitoring, phase == .monitoring || phase == .approving else { return }
        guard observationTask == nil else { return }
        await beginObservation()
    }

#if DEBUG
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
        ledger: OwnershipLedger
    ) async -> ApprovalResult {
        do {
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
        ledger: OwnershipLedger
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
        ledger: OwnershipLedger
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
            } catch IntegrationError.artifactCleanupFailure {
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
            ownsMonitoring = snapshot.monitoringOwned
            installObservation(observation)
            phase = .monitoring
            presentedError = nil
        case let .failure(error, snapshot):
            syncOwnership(snapshot)
            ownsMonitoring = snapshot.monitoringOwned
            cancelObservation(resetState: true)
            phase = snapshot.obligations.isEmpty ? .integrationReview : .repairRequired
            if let error { presentedError = error }
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
        phase = outstandingObligations.isEmpty ? .onboarding : .repairRequired
        if outstandingObligations.isEmpty {
            presentedError = nil
        } else if presentedError == nil {
            presentedError = hasIntegrationObligation
                ? .integrationConflict
                : .operationFailed
        }
        disconnectedCleanupComplete = outstandingObligations.isEmpty
    }

    private var repairPlan: RepairPlan {
        if outstandingObligations.contains(.integrationUninstallRetry) { return .uninstall }
        if outstandingObligations.contains(.integrationRollbackRepair) { return .rollback }
        if outstandingObligations.contains(.integrationMixedAdoption) { return .adoptMixed }
        if outstandingObligations.contains(.integrationArtifactCleanup) { return .artifactOnly }
        return .health
    }

    private static func performRepair(
        _ plan: RepairPlan,
        using integrations: any IntegrationInstalling
    ) async -> RepairResult {
        do {
            switch plan {
            case .uninstall:
                try await integrations.uninstall()
            case .rollback, .health:
                try await integrations.repair()
            case .adoptMixed:
                _ = try await integrations.installWithReceipt()
            case .artifactOnly:
                return try await integrations.verifyArtifactCleanup()
                    ? .artifactVerifiedClean
                    : .artifactRetained
            }
            return .success
        } catch IntegrationError.artifactCleanupFailure {
            return .artifactCleanupRequired
        } catch IntegrationError.committedWithReceiptCleanupFailure {
            return .artifactCleanupRequired
        } catch IntegrationError.committedWithCleanupFailure {
            return .legacyArtifactCleanupRequired
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(Self.presentationError(for: error))
        }
    }

    private static func recordRepair(
        _ result: RepairResult,
        plan: RepairPlan,
        ledger: OwnershipLedger
    ) async -> OwnershipSnapshot {
        switch result {
        case .success:
            switch plan {
            case .uninstall:
                await ledger.remove(.integrationUninstallRetry)
                await ledger.setIntegration(.none)
            case .rollback:
                await ledger.remove(.integrationRollbackRepair)
                await ledger.setIntegration(.preexisting)
            case .adoptMixed:
                await ledger.remove(.integrationMixedAdoption)
                await ledger.setIntegration(.preexisting)
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
            await ledger.setIntegration(plan == .uninstall ? .none : .preexisting)
        case .legacyArtifactCleanupRequired:
            await ledger.insert(.integrationArtifactCleanup)
        case .artifactVerifiedClean:
            await ledger.remove(.integrationArtifactCleanup)
        case .artifactRetained, .cancelled:
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
                integrationOwnership = .preexisting
            case .adoptMixed:
                outstandingObligations.remove(.integrationMixedAdoption)
                integrationOwnership = .preexisting
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
            integrationOwnership = plan == .uninstall ? .none : .preexisting
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
        case let .failure(error):
            if plan == .health {
                outstandingObligations.insert(.integrationRollbackRepair)
            }
            phase = .repairRequired
            presentedError = error
        case .cancelled:
            break
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

private enum ValidationError: Error {
    case invalidCredential
    case invalidEndpoint
}

private enum InternalError: Error {
    case loginApprovalRequired
}

private enum CredentialOwnership: Equatable, Sendable {
    case none
    case created
    case replaced(TuyaCredentials)
}

private enum IntegrationOwnership: Equatable, Sendable {
    case none
    case uninstallable
    case preexisting
    case mixed
    case uncertain
}

private struct OwnershipSnapshot: Sendable {
    var integration: IntegrationOwnership = .none
    var credentials: CredentialOwnership = .none
    var loginRegistrationOwned = false
    var monitoringOwned = false
    var obligations: Set<OutstandingObligation> = []
}

private actor OwnershipLedger {
    private var value = OwnershipSnapshot()

    func snapshot() -> OwnershipSnapshot { value }
    func setIntegration(_ ownership: IntegrationOwnership) { value.integration = ownership }
    func setCredentials(_ ownership: CredentialOwnership) { value.credentials = ownership }
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
enum OperationKind {
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
    case failure(PresentationError)
    case cancelled
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
