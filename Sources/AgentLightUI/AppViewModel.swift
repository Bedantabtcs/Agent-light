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
    var requiresRepair: Bool { get }
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

@MainActor
@Observable
public final class AppViewModel: AppViewModeling {
    public private(set) var phase: AppPhase = .onboarding
    public private(set) var connectionStatus: LightConnectionStatus = .disconnected
    public private(set) var currentState: AgentState = .idle
    public private(set) var sessions: [AgentEvent] = []
    public private(set) var integrationPreviews: [IntegrationPreview] = []
    public private(set) var presentedError: PresentationError?
    public private(set) var requiresRepair = false

    @ObservationIgnored private let credentials: any CredentialStoring
    @ObservationIgnored private let integrations: any IntegrationInstalling
    @ObservationIgnored private let monitor: any MonitoringOrchestrating
    @ObservationIgnored private let loginItem: any LoginItemControlling
    @ObservationIgnored private let verifier: any TuyaConnectionVerifying

    @ObservationIgnored private var pendingCredentials: TuyaCredentials?
    @ObservationIgnored private var connectGeneration: UInt64 = 0
    @ObservationIgnored private var monitorEpoch: UInt64 = 0
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var approvalTask: Task<Void, Never>?
    @ObservationIgnored private var approvalID: UUID?
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var repairTask: Task<Void, Never>?
    @ObservationIgnored private var disconnectTask: Task<Void, Never>?
    @ObservationIgnored private var ownsIntegrations = false
    @ObservationIgnored private var ownsCredentials = false
    @ObservationIgnored private var ownsMonitoring = false
    @ObservationIgnored private var integrationStateUncertain = false
    @ObservationIgnored private var setupApproved = false
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

    public func connect(using draft: ConnectionDraft) async {
        if let pendingApproval = approvalTask {
            pendingApproval.cancel()
            await pendingApproval.value
            approvalTask = nil
            approvalID = nil
        }
        guard !integrationStateUncertain else {
            phase = .repairRequired
            requiresRepair = true
            presentedError = .integrationConflict
            return
        }
        connectGeneration &+= 1
        let generation = connectGeneration
        connectTask?.cancel()
        cancelObservation(resetState: true)
        phase = .verifying
        connectionStatus = .disconnected
        presentedError = nil
        requiresRepair = false
        integrationPreviews = []
        pendingCredentials = nil
        disconnectedCleanupComplete = false

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performConnect(using: draft, generation: generation)
        }
        connectTask = task
        await task.value
        if generation == connectGeneration {
            connectTask = nil
        }
    }

    public func approveIntegrations() async {
        if let approvalTask {
            await approvalTask.value
            return
        }
        guard (phase == .integrationReview || phase == .repairRequired), pendingCredentials != nil else {
            return
        }
        let id = UUID()
        approvalID = id
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performApproval(id: id)
        }
        approvalTask = task
        await task.value
        if approvalID == id {
            approvalTask = nil
            approvalID = nil
        }
    }

    public func pause() async {
        if let disconnectTask {
            await disconnectTask.value
            return
        }
        if let resumeTask {
            await resumeTask.value
        }
        if let pauseTask {
            await pauseTask.value
            return
        }
        guard phase == .monitoring else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.monitor.pause()
            guard !Task.isCancelled, self.phase == .monitoring else { return }
            self.cancelObservation(resetState: true)
            self.phase = .paused
            self.presentedError = nil
        }
        pauseTask = task
        await task.value
        pauseTask = nil
    }

    public func resume() async {
        if let disconnectTask {
            await disconnectTask.value
            return
        }
        if let pauseTask {
            await pauseTask.value
        }
        if let resumeTask {
            await resumeTask.value
            return
        }
        guard phase == .paused else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.monitor.resume()
                guard !Task.isCancelled, self.phase == .paused else { return }
                self.ownsMonitoring = true
                await self.beginObservation()
                guard !Task.isCancelled, self.phase == .paused else { return }
                self.phase = .monitoring
                self.presentedError = nil
            } catch {
                guard !Task.isCancelled, self.phase == .paused else { return }
                self.presentedError = Self.presentationError(for: error)
            }
        }
        resumeTask = task
        await task.value
        resumeTask = nil
    }

    public func repairIntegrations() async {
        if let disconnectTask {
            await disconnectTask.value
            return
        }
        if let pauseTask { await pauseTask.value }
        if let resumeTask { await resumeTask.value }
        if let repairTask {
            await repairTask.value
            return
        }
        let originalPhase = phase
        guard originalPhase == .monitoring || originalPhase == .paused || originalPhase == .repairRequired else {
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.integrations.repair()
                guard !Task.isCancelled else { return }
                self.ownsIntegrations = true
                self.integrationStateUncertain = false
                self.requiresRepair = false
                self.presentedError = nil
                if originalPhase == .repairRequired {
                    self.phase = self.pendingCredentials == nil ? .onboarding : .integrationReview
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.requiresRepair = true
                self.phase = .repairRequired
                self.presentedError = Self.presentationError(for: error)
            }
        }
        repairTask = task
        await task.value
        repairTask = nil
    }

    public func disconnect() async {
        if let disconnectTask {
            await disconnectTask.value
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
        let task = Task { [weak self] in
            guard let self else { return }
            await pendingApproval?.value
            await pendingPause?.value
            await pendingResume?.value
            await pendingRepair?.value
            await self.performDisconnect()
        }
        disconnectTask = task
        await task.value
        disconnectTask = nil
    }

    public func observeMonitoring() async {
        guard ownsMonitoring, phase == .monitoring || phase == .approving else { return }
        guard observationTask == nil else { return }
        await beginObservation()
    }

    private func performConnect(using draft: ConnectionDraft, generation: UInt64) async {
        let temporary: TuyaCredentials
        do {
            temporary = try Self.validatedCredentials(from: draft)
        } catch {
            guard isCurrentConnect(generation) else { return }
            phase = .onboarding
            presentedError = Self.presentationError(for: error)
            return
        }

        do {
            _ = try await verifier.verify(temporary)
            guard isCurrentConnect(generation) else { return }
            let previews = try await integrations.preview()
            guard isCurrentConnect(generation) else { return }
            pendingCredentials = temporary
            integrationPreviews = previews
            presentedError = nil
            phase = .integrationReview
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentConnect(generation) else { return }
            pendingCredentials = nil
            integrationPreviews = []
            phase = .onboarding
            presentedError = Self.presentationError(for: error)
        }
    }

    private func performApproval(id: UUID) async {
        guard let pendingCredentials else { return }
        phase = .approving
        presentedError = nil
        requiresRepair = false

        var installed = false
        var saved = false
        var enabledLogin = false
        var startedMonitoring = false
        var priorCredentials: TuyaCredentials?

        do {
            do {
                try await integrations.install()
                installed = true
                ownsIntegrations = true
            } catch let error as IntegrationError {
                switch error {
                case .committedWithCleanupFailure:
                    installed = true
                    ownsIntegrations = true
                    throw error
                case .rollbackFailed:
                    integrationStateUncertain = true
                    requiresRepair = true
                    phase = .repairRequired
                    presentedError = .integrationConflict
                    return
                default:
                    throw error
                }
            }
            try ensureCurrentApproval(id)

            priorCredentials = try credentials.load()
            try credentials.save(pendingCredentials)
            saved = true
            ownsCredentials = true

            let loginWasEnabled = loginItem.isEnabled()
            try loginItem.setEnabled(true)
            guard loginItem.isEnabled() else { throw InternalError.loginApprovalRequired }
            enabledLogin = !loginWasEnabled

            try ensureCurrentApproval(id)
            try await monitor.start()
            startedMonitoring = true
            ownsMonitoring = true
            try ensureCurrentApproval(id)
            await beginObservation()
            try ensureCurrentApproval(id)

            setupApproved = true
            disconnectedCleanupComplete = false
            phase = .monitoring
            presentedError = nil
        } catch is CancellationError {
            await compensateApproval(
                installed: installed,
                saved: saved,
                priorCredentials: priorCredentials,
                enabledLogin: enabledLogin,
                startedMonitoring: startedMonitoring,
                originalError: nil
            )
        } catch {
            await compensateApproval(
                installed: installed,
                saved: saved,
                priorCredentials: priorCredentials,
                enabledLogin: enabledLogin,
                startedMonitoring: startedMonitoring,
                originalError: error
            )
        }
    }

    private func compensateApproval(
        installed: Bool,
        saved: Bool,
        priorCredentials: TuyaCredentials?,
        enabledLogin: Bool,
        startedMonitoring: Bool,
        originalError: (any Error)?
    ) async {
        var compensationFailed = false
        cancelObservation(resetState: true)

        if startedMonitoring {
            await monitor.stop()
            ownsMonitoring = false
        }
        if enabledLogin {
            do { try loginItem.setEnabled(false) } catch { compensationFailed = true }
        }
        if saved {
            do {
                if let priorCredentials {
                    try credentials.save(priorCredentials)
                } else {
                    try credentials.delete()
                }
                ownsCredentials = false
            } catch {
                compensationFailed = true
            }
        }
        if installed {
            do {
                try await integrations.uninstall()
                ownsIntegrations = false
            } catch {
                compensationFailed = true
            }
        }

        setupApproved = false
        requiresRepair = compensationFailed
        phase = compensationFailed ? .repairRequired : .integrationReview
        if let originalError {
            presentedError = Self.presentationError(for: originalError)
        }
    }

    private func performDisconnect() async {
        var cleanupFailed = integrationStateUncertain

        if ownsMonitoring {
            await monitor.stop()
            ownsMonitoring = false
        }
        if setupApproved || loginItem.isEnabled() {
            do { try loginItem.setEnabled(false) } catch { cleanupFailed = true }
        }
        if ownsCredentials {
            do {
                try credentials.delete()
                ownsCredentials = false
            } catch {
                cleanupFailed = true
            }
        }
        if ownsIntegrations {
            do {
                try await integrations.uninstall()
                ownsIntegrations = false
            } catch {
                cleanupFailed = true
            }
        }

        pendingCredentials = nil
        integrationPreviews = []
        currentState = .idle
        sessions = []
        connectionStatus = .disconnected
        setupApproved = false
        requiresRepair = cleanupFailed
        phase = cleanupFailed ? .repairRequired : .onboarding
        presentedError = integrationStateUncertain
            ? .integrationConflict
            : (cleanupFailed ? .operationFailed : nil)
        disconnectedCleanupComplete = !cleanupFailed
    }

    private func beginObservation() async {
        monitorEpoch &+= 1
        let epoch = monitorEpoch
        observationTask?.cancel()
        observationTask = nil

        let snapshot = await monitor.currentSnapshot()
        guard epoch == monitorEpoch, !Task.isCancelled else { return }
        apply(snapshot)
        let stream = await monitor.updates()
        guard epoch == monitorEpoch, !Task.isCancelled else { return }
        observationTask = Task { [weak self] in
            for await update in stream {
                guard let self, epoch == self.monitorEpoch, !Task.isCancelled else { return }
                self.apply(update)
            }
        }
    }

    private func cancelObservation(resetState: Bool) {
        monitorEpoch &+= 1
        observationTask?.cancel()
        observationTask = nil
        if resetState {
            currentState = .idle
            sessions = []
        }
    }

    private func apply(_ snapshot: MonitoringSnapshot) {
        currentState = snapshot.state
        sessions = snapshot.sessions
        connectionStatus = snapshot.connection
    }

    private func isCurrentConnect(_ generation: UInt64) -> Bool {
        generation == connectGeneration && !Task.isCancelled
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
