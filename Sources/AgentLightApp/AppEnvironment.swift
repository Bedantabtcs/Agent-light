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
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var startID: UUID?
    @ObservationIgnored private var started = false

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
    }

    deinit {
        startTask?.cancel()
    }

    func requestStart() {
        guard !started, startTask == nil else { return }
        status = .loading
        let id = UUID()
        startID = id
        let viewModel = viewModel
        let credentials = credentials
        let monitor = monitor
        let relay = relay
        let coordinator = coordinator
        let prepareStorage = prepareStorage
        let task = Task { [weak self] in
            let outcome = await Self.performStart(
                viewModel: viewModel,
                credentials: credentials,
                monitor: monitor,
                relay: relay,
                coordinator: coordinator,
                prepareStorage: prepareStorage
            )
            self?.finishStart(outcome, id: id)
        }
        startTask = task
    }

    func start() async {
        if started { return }
        requestStart()
        await startTask?.value
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
            let storedCredentials = try credentials.load()
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
            await relay.stop()
            await viewModel.disconnect()
            return .cancelled
        } catch {
            await relay.stop()
            await viewModel.disconnect()
            return .failed
        }
    }

    private func finishStart(_ outcome: StartOutcome, id: UUID) {
        guard startID == id else { return }
        startTask = nil
        startID = nil
        switch outcome {
        case .ready:
            started = true
            status = .ready
        case .failed:
            started = false
            status = .failed
        case .cancelled:
            started = false
        }
    }

    func stop() async {
        let startup = startTask
        startTask = nil
        startID = nil
        startup?.cancel()
        await startup?.value
        await relay.stop()
        await viewModel.disconnect()
        started = false
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
        case cancelled
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
