import ServiceManagement

@MainActor
public protocol LoginItemControlling {
    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool) throws
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

enum LoginItemServiceStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown
}

@MainActor
protocol LoginItemServiceAdapting: AnyObject {
    var status: LoginItemServiceStatus { get }
    func register() throws
    func unregister() throws
}

@MainActor
final class MainAppServiceAdapter: LoginItemServiceAdapting {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var status: LoginItemServiceStatus {
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

    public func isEnabled() -> Bool {
        service.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        switch (enabled, service.status) {
        case (true, .notRegistered), (true, .notFound):
            do {
                try service.register()
            } catch {
                throw LoginItemControllerError.registrationFailed
            }
        case (false, .enabled), (false, .requiresApproval):
            do {
                try service.unregister()
            } catch {
                throw LoginItemControllerError.unregistrationFailed
            }
        case (true, .enabled),
             (true, .requiresApproval),
             (true, .unknown),
             (false, .notRegistered),
             (false, .notFound),
             (false, .unknown):
            return
        }
    }
}
