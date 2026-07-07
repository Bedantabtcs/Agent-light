import AppKit
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
    @ObservationIgnored private let relay: any RelayServing
    @ObservationIgnored private let coordinator: any RelayEventCoordinating
    @ObservationIgnored private let prepareStorage: @Sendable () async throws -> Void
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
        prepareStorage: @escaping @Sendable () async throws -> Void
    ) {
        self.viewModel = viewModel
        self.credentials = credentials
        self.monitor = monitor
        self.relay = relay
        self.coordinator = coordinator
        self.prepareStorage = prepareStorage
        shutdownController = EnvironmentShutdownController(relay: relay, viewModel: viewModel)
    }

    deinit {
        let tail = operationTail
        tail?.cancel()
        let shutdownController = shutdownController
        Task {
            await tail?.value
            await shutdownController.shutdown()
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
        let relay = relay
        let coordinator = coordinator
        let prepareStorage = prepareStorage
        let shutdownController = shutdownController
        let task = Task { [weak self] in
            await shutdownController.arm()
            let outcome = await Self.performStart(
                viewModel: viewModel,
                credentials: credentials,
                monitor: monitor,
                relay: relay,
                coordinator: coordinator,
                prepareStorage: prepareStorage
            )
            if outcome != .ready {
                await shutdownController.shutdown()
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
        relay: any RelayServing,
        coordinator: any RelayEventCoordinating,
        prepareStorage: @Sendable () async throws -> Void
    ) async -> StartOutcome {
        do {
            try await prepareStorage()
            try Task.checkCancellation()
            try await monitor.recoverIfNeeded()
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
            await viewModel.synchronizeOwnership()
            try Task.checkCancellation()
            if let storedCredentials, await viewModel.phase == .onboarding {
                await viewModel.connect(using: ConnectionDraft(
                    endpoint: storedCredentials.endpoint.absoluteString,
                    accessID: storedCredentials.accessID,
                    accessSecret: storedCredentials.accessSecret,
                    deviceID: storedCredentials.deviceID
                ))
                if await viewModel.phase == .integrationReview {
                    await viewModel.approveIntegrations()
                }
            }
            try Task.checkCancellation()
            let coordinator = coordinator
            try await relay.start { data in
                await coordinator.accept(data)
            }
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
            await prior?.value
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
            await self?.stop()
            NSApplication.shared.terminate(nil)
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
    private let relay: any RelayServing
    private let viewModel: any AppViewModeling
    private var isArmed = true
    private var shutdownTask: Task<Void, Never>?

    init(relay: any RelayServing, viewModel: any AppViewModeling) {
        self.relay = relay
        self.viewModel = viewModel
    }

    func arm() async {
        await shutdownTask?.value
        isArmed = true
    }

    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard isArmed else { return }
        isArmed = false
        let relay = relay
        let viewModel = viewModel
        let task = Task {
            await relay.stop()
            await viewModel.disconnect()
        }
        shutdownTask = task
        await task.value
        shutdownTask = nil
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
        let ownershipLedger = AppOwnershipLedger()
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
            prepareStorage: prepareApplicationSupport
        )
        return ProductionAppComposition(environment: environment, viewModel: viewModel)
    }

    private static func bundledRelayPath() -> String {
        Bundle.main.url(forAuxiliaryExecutable: "AgentLightRelay")?.path
            ?? AppIdentity.applicationSupportDirectory.appending(path: "AgentLightRelay").path
    }

    private static func prepareApplicationSupport() async throws {
        let directory = AppIdentity.applicationSupportDirectory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }
}
