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
              pendingCredentials != nil else {
            return
        }
        let id = UUID()
        approvalID = id
        let integrations = integrations
        let task = Task { [weak self, integrations] in
            let result = await Self.approvalInstallResult(using: integrations)
            guard let self else {
                await Self.cleanupAbandonedInstall(result, using: integrations)
                return
            }
            await self.performApprovalAfterInstall(result, id: id)
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
                try? await monitor.resume()
                return
            }
            guard let self else { return }
            guard self.phase == .monitoring else { return }
            self.cancelObservation(resetState: true)
            self.phase = .paused
            self.presentedError = nil
        }
        let operation = SharedOperation(task: task)
        pauseTask = operation
        operation.onFinish { [weak self, weak operation] in
            guard let self, self.pauseTask === operation else { return }
            self.pauseTask = nil
        }
        await operation.wait()
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
        let task = Task { [weak self, integrations] in
            let result = await Self.performRepair(plan, using: integrations)
            self?.applyRepair(result, plan: plan, originalPhase: originalPhase)
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
        let task = Task { [weak self, monitor, integrations] in
            await pendingApproval?.wait()
            await pendingPause?.wait()
            await pendingResume?.wait()
            await pendingRepair?.wait()
            let shouldStop = self?.ownsMonitoring ?? false
            if shouldStop { await monitor.stop() }
            guard let ownership = self?.prepareDisconnectCleanup(stoppedMonitoring: shouldStop) else { return }
            let result = await Self.disconnectIntegrationResult(ownership, using: integrations)
            self?.finishDisconnect(result)
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

    private static func approvalInstallResult(
        using integrations: any IntegrationInstalling
    ) async -> ApprovalInstallResult {
        do {
            return .installed(try await integrations.installWithReceipt())
        } catch let error as IntegrationError {
            switch error {
            case let .committedWithCleanupFailure(receipt, _):
                return .committedWithArtifactCleanup(receipt)
            case .rollbackFailed:
                return .rollbackFailed
            default:
                return .failed(Self.presentationError(for: error))
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(Self.presentationError(for: error))
        }
    }

    private static func cleanupAbandonedInstall(
        _ result: ApprovalInstallResult,
        using integrations: any IntegrationInstalling
    ) async {
        let receipt: IntegrationInstallReceipt
        switch result {
        case let .installed(value), let .committedWithArtifactCleanup(value):
            receipt = value
        case .rollbackFailed, .failed, .cancelled:
            return
        }
        guard receipt.overallOwnership == .fresh else { return }
        try? await integrations.uninstall()
    }

    private func performApprovalAfterInstall(_ installResult: ApprovalInstallResult, id: UUID) async {
        guard let pendingCredentials else { return }
        phase = .approving
        presentedError = nil

        let installed: Bool
        var saved = false
        var startedMonitoring = false

        switch installResult {
        case let .installed(receipt):
            installed = true
            integrationOwnership = Self.integrationOwnership(for: receipt)
        case let .committedWithArtifactCleanup(receipt):
            integrationOwnership = Self.integrationOwnership(for: receipt)
            outstandingObligations.insert(.integrationArtifactCleanup)
            await compensateApproval(
                installed: true,
                saved: false,
                startedMonitoring: false,
                originalError: IntegrationError.artifactCleanupFailure([])
            )
            return
        case .rollbackFailed:
            integrationOwnership = .uncertain
            outstandingObligations.insert(.integrationRollbackRepair)
            phase = .repairRequired
            presentedError = .integrationConflict
            return
        case let .failed(error):
            phase = .integrationReview
            presentedError = error
            return
        case .cancelled:
            return
        }

        do {
            try ensureCurrentApproval(id)

            let priorCredentials = try credentials.load()
            try credentials.save(pendingCredentials)
            saved = true
            credentialOwnership = priorCredentials.map(CredentialOwnership.replaced) ?? .created

            let loginTransition = try loginItem.setEnabled(true)
            loginRegistrationOwned = loginTransition.didRegister
            guard loginTransition.current == .enabled else { throw InternalError.loginApprovalRequired }

            try ensureCurrentApproval(id)
            try await monitor.start()
            startedMonitoring = true
            ownsMonitoring = true
            try ensureCurrentApproval(id)
            await beginObservation()
            try ensureCurrentApproval(id)

            disconnectedCleanupComplete = false
            phase = .monitoring
            presentedError = nil
        } catch is CancellationError {
            await compensateApproval(
                installed: installed,
                saved: saved,
                startedMonitoring: startedMonitoring,
                originalError: nil
            )
        } catch {
            await compensateApproval(
                installed: installed,
                saved: saved,
                startedMonitoring: startedMonitoring,
                originalError: error
            )
        }
    }

    private func compensateApproval(
        installed: Bool,
        saved: Bool,
        startedMonitoring: Bool,
        originalError: (any Error)?
    ) async {
        cancelObservation(resetState: true)

        if startedMonitoring {
            await monitor.stop()
            ownsMonitoring = false
        }
        cleanupLoginRegistration()
        if saved { cleanupCredentials() }
        if installed { await cleanupIntegrations() }

        phase = outstandingObligations.isEmpty ? .integrationReview : .repairRequired
        if let originalError {
            presentedError = Self.presentationError(for: originalError)
        }
    }

    private func prepareDisconnectCleanup(stoppedMonitoring: Bool) -> IntegrationOwnership {
        if stoppedMonitoring {
            ownsMonitoring = false
        }
        cleanupLoginRegistration()
        cleanupCredentials()
        return integrationOwnership
    }

    private static func disconnectIntegrationResult(
        _ ownership: IntegrationOwnership,
        using integrations: any IntegrationInstalling
    ) async -> DisconnectIntegrationResult {
        switch ownership {
        case .none, .preexisting:
            return .clean
        case .uninstallable:
            do {
                try await integrations.uninstall()
                return .clean
            } catch {
                return .uninstallRetry
            }
        case .mixed:
            return .mixedAdoption
        case .uncertain:
            return .rollbackRepair
        }
    }

    private func finishDisconnect(_ integrationResult: DisconnectIntegrationResult) {
        switch integrationResult {
        case .clean:
            integrationOwnership = .none
            outstandingObligations.remove(.integrationUninstallRetry)
        case .uninstallRetry:
            outstandingObligations.insert(.integrationUninstallRetry)
        case .mixedAdoption:
            outstandingObligations.insert(.integrationMixedAdoption)
        case .rollbackRepair:
            outstandingObligations.insert(.integrationRollbackRepair)
        }

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

    private func cleanupLoginRegistration() {
        guard loginRegistrationOwned else {
            outstandingObligations.remove(.loginRegistrationCleanup)
            return
        }
        do {
            let transition = try loginItem.setEnabled(false)
            if transition.current == .notRegistered || transition.current == .notFound {
                loginRegistrationOwned = false
                outstandingObligations.remove(.loginRegistrationCleanup)
            } else {
                outstandingObligations.insert(.loginRegistrationCleanup)
            }
        } catch {
            outstandingObligations.insert(.loginRegistrationCleanup)
        }
    }

    private func cleanupCredentials() {
        do {
            switch credentialOwnership {
            case .none:
                outstandingObligations.remove(.credentialRestore)
                outstandingObligations.remove(.credentialDelete)
                return
            case .created:
                try credentials.delete()
                outstandingObligations.remove(.credentialDelete)
            case let .replaced(previous):
                try credentials.save(previous)
                outstandingObligations.remove(.credentialRestore)
            }
            credentialOwnership = .none
        } catch {
            switch credentialOwnership {
            case .created:
                outstandingObligations.insert(.credentialDelete)
            case .replaced:
                outstandingObligations.insert(.credentialRestore)
            case .none:
                break
            }
        }
    }

    private func cleanupIntegrations() async {
        switch integrationOwnership {
        case .none:
            return
        case .preexisting:
            integrationOwnership = .none
            outstandingObligations.remove(.integrationUninstallRetry)
        case .uninstallable:
            do {
                try await integrations.uninstall()
                integrationOwnership = .none
                outstandingObligations.remove(.integrationUninstallRetry)
            } catch {
                outstandingObligations.insert(.integrationUninstallRetry)
            }
        case .mixed:
            outstandingObligations.insert(.integrationMixedAdoption)
        case .uncertain:
            outstandingObligations.insert(.integrationRollbackRepair)
        }
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
                return .success
            }
            return .success
        } catch IntegrationError.artifactCleanupFailure {
            return .artifactCleanupRequired
        } catch IntegrationError.committedWithCleanupFailure {
            return .artifactCleanupRequired
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(Self.presentationError(for: error))
        }
    }

    private func applyRepair(_ result: RepairResult, plan: RepairPlan, originalPhase: AppPhase) {
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

    private func ensureCurrentApproval(_ id: UUID) throws {
        guard approvalID == id, !Task.isCancelled else { throw CancellationError() }
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

private enum CredentialOwnership: Equatable {
    case none
    case created
    case replaced(TuyaCredentials)
}

private enum IntegrationOwnership: Equatable {
    case none
    case uninstallable
    case preexisting
    case mixed
    case uncertain
}

private enum ConnectResult {
    case success(TuyaCredentials, [IntegrationPreview])
    case failure(PresentationError)
    case cancelled
}

private enum ApprovalInstallResult {
    case installed(IntegrationInstallReceipt)
    case committedWithArtifactCleanup(IntegrationInstallReceipt)
    case rollbackFailed
    case failed(PresentationError)
    case cancelled
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
    case failure(PresentationError)
    case cancelled
}

private enum DisconnectIntegrationResult {
    case clean
    case uninstallRetry
    case mixedAdoption
    case rollbackRepair
}

@MainActor
private final class SharedOperation {
    private let task: Task<Void, Never>
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var completed = false
    private var finishAction: (() -> Void)?

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
                if completed || Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
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
