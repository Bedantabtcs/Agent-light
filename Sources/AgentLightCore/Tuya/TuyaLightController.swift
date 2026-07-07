import Foundation

public protocol TuyaDeviceServicing: Sendable {
    func status() async throws -> [TuyaStatus]
    func specification() async throws -> TuyaSpecification
    func send(commands: [TuyaCommand]) async throws
}

extension TuyaClient: TuyaDeviceServicing {}

public actor TuyaLightController: TuyaLightControlling {
    public typealias ServiceFactory = @Sendable (TuyaCredentials) -> any TuyaDeviceServicing

    private let credentials: any CredentialStoring
    private let serviceFactory: ServiceFactory
    private var cachedCredentials: TuyaCredentials?
    private var cachedService: (any TuyaDeviceServicing)?
    private var cachedCapabilities: ResolvedLightCapabilities?

    public init(
        credentials: any CredentialStoring,
        serviceFactory: @escaping ServiceFactory = { TuyaClient(credentials: $0) }
    ) {
        self.credentials = credentials
        self.serviceFactory = serviceFactory
    }

    public func captureBaseline() async throws -> BulbBaseline {
        let (service, capabilities) = try await context()
        let status = try await service.status()
        return try capabilities.baseline(from: status)
    }

    public func apply(_ state: DesiredLightState) async throws {
        let (service, capabilities) = try await context()
        try await service.send(commands: LightColorMapper.commands(for: state, capabilities: capabilities))
    }

    public func currentStateMatches(_ state: DesiredLightState) async throws -> Bool {
        let (service, capabilities) = try await context()
        let expected = try LightColorMapper.commands(for: state, capabilities: capabilities)
        var actual: [String: JSONValue] = [:]
        for item in try await service.status() {
            guard actual[item.code] == nil else {
                throw CapabilityError.duplicateStatus(item.code)
            }
            actual[item.code] = item.value
        }
        return try expected.allSatisfy { command in
            guard let value = actual[command.code] else { return false }
            if command.code == capabilities.colorCode,
               case let .string(encoded) = value,
               let data = encoded.data(using: .utf8) {
                return try JSONValue.decode(data) == command.value
            }
            return value == command.value
        }
    }

    public func restore(_ baseline: BulbBaseline) async throws {
        let (service, capabilities) = try await context()
        try await service.send(commands: capabilities.restoreCommands(from: baseline))
    }

    private func context() async throws -> (any TuyaDeviceServicing, ResolvedLightCapabilities) {
        guard let loaded = try credentials.load() else {
            throw TuyaClientError.authenticationFailure
        }
        if loaded == cachedCredentials,
           let cachedService,
           let cachedCapabilities {
            return (cachedService, cachedCapabilities)
        }
        let service = serviceFactory(loaded)
        let capabilities = try await TuyaCapabilityResolver.resolve(
            specification: service.specification()
        )
        cachedCredentials = loaded
        cachedService = service
        cachedCapabilities = capabilities
        return (service, capabilities)
    }
}
