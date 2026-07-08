import AppKit
import Darwin
import Foundation
import Observation
import AgentLightCore
import AgentLightProtocol
import AgentLightUI

protocol RelayServing: Sendable {
    func start(handler: @escaping @Sendable (Data) async -> Void) async throws
    func stop() async
}

protocol RelayEventCoordinating: Sendable {
    func accept(_ data: Data) async
}

extension RelayEventCoordinator: RelayEventCoordinating {}

actor UnixRelaySocketAdapter: RelayServing {
    private let server: UnixDatagramServer

    init(path: String) {
        server = UnixDatagramServer(path: path)
    }

    func start(handler: @escaping @Sendable (Data) async -> Void) async throws {
        try await server.start(handler: handler)
    }

    func stop() async {
        await server.stop()
    }
}

struct ProductionTuyaConnectionVerifier: TuyaConnectionVerifying {
    typealias ServiceFactory = @Sendable (TuyaCredentials) -> any TuyaDeviceServicing
    private let serviceFactory: ServiceFactory

    init(serviceFactory: @escaping ServiceFactory = { TuyaClient(credentials: $0) }) {
        self.serviceFactory = serviceFactory
    }

    func verify(_ credentials: TuyaCredentials) async throws -> ResolvedLightCapabilities {
        let service = serviceFactory(credentials)
        async let status = service.status()
        async let specification = service.specification()
        return try await TuyaCapabilityResolver.resolve(
            specification: specification,
            status: status
        )
    }
}

enum AppEnvironmentStatus: Equatable {
    case loading
    case ready
    case failed
    case credentialResetFailed
}

@MainActor
@Observable
final class AppEnvironment {
    private(set) var status: AppEnvironmentStatus = .loading

    @ObservationIgnored private let viewModel: any AppViewModeling
    @ObservationIgnored private let credentials: any CredentialStoring
    @ObservationIgnored private let monitor: any MonitoringOrchestrating
    @ObservationIgnored private let coordinator: any RelayEventCoordinating
    @ObservationIgnored private let prepareStorage: @Sendable () async throws -> Void
    @ObservationIgnored private let beforeApproval: @Sendable () async -> Void
    @ObservationIgnored private let beforeRelayStart: @Sendable () async -> Void
    @ObservationIgnored private let terminateApplication: @MainActor @Sendable () -> Void
    @ObservationIgnored private let shutdownController: EnvironmentShutdownController
    @ObservationIgnored private var lifecycle: Lifecycle = .idle
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var operationTail: Task<Void, Never>?
    @ObservationIgnored private var restartAfterStop = false

    init(
        viewModel: any AppViewModeling,
        credentials: any CredentialStoring,
        monitor: any MonitoringOrchestrating,
        relay: any RelayServing,
        coordinator: any RelayEventCoordinating,
        prepareStorage: @escaping @Sendable () async throws -> Void,
        beforeApproval: @escaping @Sendable () async -> Void = {},
        beforeRelayStart: @escaping @Sendable () async -> Void = {},
        terminateApplication: @escaping @MainActor @Sendable () -> Void = {
            NSApplication.shared.terminate(nil)
        }
    ) {
        self.viewModel = viewModel
        self.credentials = credentials
        self.monitor = monitor
        self.coordinator = coordinator
        self.prepareStorage = prepareStorage
        self.beforeApproval = beforeApproval
        self.beforeRelayStart = beforeRelayStart
        self.terminateApplication = terminateApplication
        shutdownController = EnvironmentShutdownController(relay: relay, viewModel: viewModel)
    }

    deinit {
        let tail = operationTail
        tail?.cancel()
        let shutdownController = shutdownController
        Task {
            let shutdown = Task { await shutdownController.shutdown() }
            await tail?.value
            await shutdown.value
        }
    }

    func requestStart() {
        switch lifecycle {
        case .idle:
            beginStart()
        case .stopping:
            restartAfterStop = true
        case .starting, .ready:
            break
        }
    }

    private func beginStart() {
        guard lifecycle == .idle else { return }
        status = .loading
        let id = UUID()
        lifecycle = .starting
        operationID = id
        let viewModel = viewModel
        let credentials = credentials
        let monitor = monitor
        let coordinator = coordinator
        let prepareStorage = prepareStorage
        let beforeApproval = beforeApproval
        let beforeRelayStart = beforeRelayStart
        let shutdownController = shutdownController
        let canContinue: @MainActor @Sendable () -> Bool = { [weak self] in
            self?.lifecycle == .starting
        }
        let task = Task { [weak self] in
            guard let relayGeneration = await shutdownController.arm() else {
                self?.finishStart(.cancelled, id: id)
                return
            }
            let outcome = await Self.performStart(
                viewModel: viewModel,
                credentials: credentials,
                monitor: monitor,
                coordinator: coordinator,
                prepareStorage: prepareStorage,
                beforeApproval: beforeApproval,
                beforeRelayStart: beforeRelayStart,
                shutdownController: shutdownController,
                relayGeneration: relayGeneration,
                canContinue: canContinue
            )
            if outcome != .ready {
                await shutdownController.shutdown(generation: relayGeneration)
            }
            self?.finishStart(outcome, id: id)
        }
        operationTail = task
    }

    func start() async {
        requestStart()
        while lifecycle == .starting || lifecycle == .stopping {
            let current = operationTail
            await current?.value
            if current == nil { break }
        }
    }

    private nonisolated static func performStart(
        viewModel: any AppViewModeling,
        credentials: any CredentialStoring,
        monitor: any MonitoringOrchestrating,
        coordinator: any RelayEventCoordinating,
        prepareStorage: @Sendable () async throws -> Void,
        beforeApproval: @Sendable () async -> Void,
        beforeRelayStart: @Sendable () async -> Void,
        shutdownController: EnvironmentShutdownController,
        relayGeneration: UInt64,
        canContinue: @MainActor @Sendable () -> Bool
    ) async -> StartOutcome {
        do {
            try await prepareStorage()
            try Task.checkCancellation()
            try await monitor.recoverIfNeeded()
            try Task.checkCancellation()
            await viewModel.synchronizeOwnership()
            try Task.checkCancellation()
            let synchronizedPhase = await viewModel.phase
            if synchronizedPhase == .monitoring || synchronizedPhase == .paused {
                await viewModel.repairIntegrations()
            }
            try Task.checkCancellation()
            let storedCredentials: TuyaCredentials?
            do {
                storedCredentials = try credentials.load()
            } catch CredentialStoreError.malformedData {
                do {
                    try credentials.delete()
                    storedCredentials = nil
                } catch {
                    return .credentialResetFailed
                }
            }
            if let storedCredentials, await viewModel.phase == .onboarding {
                await viewModel.connect(using: ConnectionDraft(
                    endpoint: storedCredentials.endpoint.absoluteString,
                    accessID: storedCredentials.accessID,
                    accessSecret: storedCredentials.accessSecret,
                    deviceID: storedCredentials.deviceID
                ))
                if await viewModel.phase == .integrationReview,
                   await viewModel.automaticSetupResumeAuthorized {
                    await beforeApproval()
                    await viewModel.approveIntegrations()
                }
            }
            try Task.checkCancellation()
            guard await canContinue() else { throw CancellationError() }
            await beforeRelayStart()
            let coordinator = coordinator
            let didStart = try await shutdownController.start(
                generation: relayGeneration
            ) { data in
                await coordinator.accept(data)
            }
            guard didStart else { throw CancellationError() }
            try Task.checkCancellation()
            return .ready
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed
        }
    }

    private func finishStart(_ outcome: StartOutcome, id: UUID) {
        guard lifecycle == .starting, operationID == id else { return }
        operationTail = nil
        operationID = nil
        switch outcome {
        case .ready:
            lifecycle = .ready
            status = .ready
        case .failed:
            lifecycle = .idle
            status = .failed
        case .credentialResetFailed:
            lifecycle = .idle
            status = .credentialResetFailed
        case .cancelled:
            lifecycle = .idle
        }
    }

    func stop() async {
        if lifecycle == .stopping {
            restartAfterStop = false
            await operationTail?.value
            return
        }

        let prior = operationTail
        let id = UUID()
        lifecycle = .stopping
        operationID = id
        restartAfterStop = false
        prior?.cancel()
        let shutdownController = shutdownController
        let task = Task { [weak self] in
            await shutdownController.shutdown()
            self?.finishStop(id: id)
        }
        operationTail = task
        await task.value
    }

    private func finishStop(id: UUID) {
        guard lifecycle == .stopping, operationID == id else { return }
        let shouldRestart = restartAfterStop
        lifecycle = .idle
        operationID = nil
        operationTail = nil
        restartAfterStop = false
        status = .loading
        if shouldRestart { beginStart() }
    }

    func requestQuit() {
        Task { [weak self] in
            guard let self else { return }
            await self.stop()
            self.terminateApplication()
        }
    }

    private enum StartOutcome: Sendable {
        case ready
        case failed
        case credentialResetFailed
        case cancelled
    }

    private enum Lifecycle: Sendable {
        case idle
        case starting
        case ready
        case stopping
    }
}

private actor EnvironmentShutdownController {
    private struct RegisteredStart {
        let id: UUID
        let task: Task<Void, Error>
    }

    private let relay: any RelayServing
    private let viewModel: any AppViewModeling
    private var isArmed = true
    private var generation: UInt64 = 0
    private var registeredStart: RegisteredStart?
    private var shutdownTask: Task<Void, Never>?

    init(relay: any RelayServing, viewModel: any AppViewModeling) {
        self.relay = relay
        self.viewModel = viewModel
    }

    func arm() async -> UInt64? {
        guard !Task.isCancelled else { return nil }
        await shutdownTask?.value
        guard !Task.isCancelled else { return nil }
        generation &+= 1
        isArmed = true
        return generation
    }

    func start(
        generation expectedGeneration: UInt64,
        handler: @escaping @Sendable (Data) async -> Void
    ) async throws -> Bool {
        guard isArmed, expectedGeneration == generation else { return false }
        let id = UUID()
        let relay = relay
        let task = Task {
            try await relay.start(handler: handler)
        }
        registeredStart = RegisteredStart(id: id, task: task)
        do {
            try await task.value
            clearRegisteredStart(id: id)
            return true
        } catch {
            clearRegisteredStart(id: id)
            throw error
        }
    }

    func shutdown(generation expectedGeneration: UInt64? = nil) async {
        if let expectedGeneration, expectedGeneration != generation { return }
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard isArmed else { return }
        isArmed = false
        let pendingStart = registeredStart
        let relay = relay
        let viewModel = viewModel
        let task = Task {
            if let pendingStart {
                _ = try? await pendingStart.task.value
            }
            await relay.stop()
            await viewModel.shutdownMonitoring()
        }
        shutdownTask = task
        await task.value
        if let pendingStart {
            clearRegisteredStart(id: pendingStart.id)
        }
        shutdownTask = nil
    }

    private func clearRegisteredStart(id: UUID) {
        guard registeredStart?.id == id else { return }
        registeredStart = nil
    }
}

struct ProductionAppComposition {
    let environment: AppEnvironment
    let viewModel: AppViewModel

    @MainActor
    static func make() -> ProductionAppComposition {
        let credentials = KeychainCredentialStore()
        let light = TuyaLightController(credentials: credentials)
        let recoveryURL = AppIdentity.applicationSupportDirectory
            .appending(path: "monitoring-recovery-v1.json")
        let recoveryStore = FileMonitoringRecoveryStore(url: recoveryURL)
        let monitor = MonitoringOrchestrator(light: light, recoveryStore: recoveryStore)
        let relayPath = bundledRelayPath()
        let integrations = IntegrationInstaller(relayPath: relayPath)
        let loginItem = LoginItemController()
        let verifier = ProductionTuyaConnectionVerifier()
        let ownershipURL = AppIdentity.applicationSupportDirectory
            .appending(path: "setup-ownership-v1.json")
        let ownershipStore = FileSetupOwnershipStore(url: ownershipURL)
        let ownershipLedger = AppOwnershipLedger(store: ownershipStore)
        let viewModel = AppViewModel(
            credentials: credentials,
            integrations: integrations,
            monitor: monitor,
            loginItem: loginItem,
            verifier: verifier,
            ownershipLedger: ownershipLedger
        )
        let coordinator = RelayEventCoordinator(monitor: monitor)
        let relay = UnixRelaySocketAdapter(path: AppIdentity.socketPath)
        let environment = AppEnvironment(
            viewModel: viewModel,
            credentials: credentials,
            monitor: monitor,
            relay: relay,
            coordinator: coordinator,
            prepareStorage: { try await prepareApplicationSupport() }
        )
        return ProductionAppComposition(environment: environment, viewModel: viewModel)
    }

    private static func bundledRelayPath() -> String {
        Bundle.main.url(forAuxiliaryExecutable: "AgentLightRelay")?.path
            ?? AppIdentity.applicationSupportDirectory.appending(path: "AgentLightRelay").path
    }

    static func prepareApplicationSupport(
        at directory: URL = AppIdentity.applicationSupportDirectory
    ) async throws {
        let created: Bool
        if mkdir(directory.path, mode_t(0o700)) == 0 {
            created = true
        } else if errno == EEXIST {
            created = false
        } else {
            throw ApplicationSupportPreparationError.storageFailure
        }
        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw ApplicationSupportPreparationError.unsafeDirectory
        }
        defer { _ = close(descriptor) }
        if created, fchmod(descriptor, mode_t(0o700)) != 0 {
            throw ApplicationSupportPreparationError.storageFailure
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw ApplicationSupportPreparationError.unsafeDirectory
        }
        guard fsync(descriptor) == 0 else {
            throw ApplicationSupportPreparationError.storageFailure
        }
    }
}

enum ApplicationSupportPreparationError: Error, Equatable {
    case unsafeDirectory
    case storageFailure
}
