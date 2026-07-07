import ServiceManagement

@MainActor
public protocol LoginItemControlling {
    func status() -> LoginItemStatus
    @discardableResult
    func setEnabled(_ enabled: Bool) throws -> LoginItemTransition
}

public enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown
}

public struct LoginItemTransition: Equatable, Sendable {
    public let previous: LoginItemStatus
    public let current: LoginItemStatus
    public let didRegister: Bool
    public let didUnregister: Bool

    public init(
        previous: LoginItemStatus,
        current: LoginItemStatus,
        didRegister: Bool,
        didUnregister: Bool
    ) {
        self.previous = previous
        self.current = current
        self.didRegister = didRegister
        self.didUnregister = didUnregister
    }
}

public enum LoginItemControllerError: Error, Equatable, Sendable {
    case registrationFailed
    case unregistrationFailed
}

extension LoginItemControllerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .registrationFailed:
            "The login item could not be enabled."
        case .unregistrationFailed:
            "The login item could not be disabled."
        }
    }
}

@MainActor
protocol LoginItemServiceAdapting: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

@MainActor
final class MainAppServiceAdapter: LoginItemServiceAdapting {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var status: LoginItemStatus {
        switch service.status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            .unknown
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}

@MainActor
public final class LoginItemController: LoginItemControlling {
    private let service: any LoginItemServiceAdapting

    public convenience init() {
        self.init(service: MainAppServiceAdapter())
    }

    init(service: any LoginItemServiceAdapting) {
        self.service = service
    }

    public func status() -> LoginItemStatus {
        service.status
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) throws -> LoginItemTransition {
        let previous = service.status
        var didRegister = false
        var didUnregister = false
        switch (enabled, previous) {
        case (true, .notRegistered), (true, .notFound):
            do {
                try service.register()
                didRegister = true
            } catch {
                throw LoginItemControllerError.registrationFailed
            }
        case (false, .enabled), (false, .requiresApproval):
            do {
                try service.unregister()
                didUnregister = true
            } catch {
                throw LoginItemControllerError.unregistrationFailed
            }
        case (true, .enabled),
             (true, .requiresApproval),
             (true, .unknown),
             (false, .notRegistered),
             (false, .notFound),
             (false, .unknown):
            break
        }
        return LoginItemTransition(
            previous: previous,
            current: service.status,
            didRegister: didRegister,
            didUnregister: didUnregister
        )
    }
}
