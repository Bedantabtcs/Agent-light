import XCTest
@testable import AgentLightCore

@MainActor
final class LoginItemControllerTests: XCTestCase {
    func testIsEnabledOnlyForEnabledStatus() {
        XCTAssertTrue(LoginItemController(service: FakeLoginItemService(status: .enabled)).isEnabled())
        XCTAssertFalse(LoginItemController(service: FakeLoginItemService(status: .notRegistered)).isEnabled())
        XCTAssertFalse(LoginItemController(service: FakeLoginItemService(status: .requiresApproval)).isEnabled())
        XCTAssertFalse(LoginItemController(service: FakeLoginItemService(status: .notFound)).isEnabled())
        XCTAssertFalse(LoginItemController(service: FakeLoginItemService(status: .unknown)).isEnabled())
    }

    func testEnableRegistersOnlyFromNotRegisteredOrNotFound() throws {
        for status in [LoginItemServiceStatus.notRegistered, .notFound] {
            let service = FakeLoginItemService(status: status)
            let controller = LoginItemController(service: service)

            try controller.setEnabled(true)
            try controller.setEnabled(true)

            XCTAssertEqual(service.registerCount, 1)
            XCTAssertEqual(service.unregisterCount, 0)
            XCTAssertTrue(controller.isEnabled())
        }
    }

    func testEnableDoesNotRegisterEnabledApprovalPendingOrUnknownService() throws {
        for status in [LoginItemServiceStatus.enabled, .requiresApproval, .unknown] {
            let service = FakeLoginItemService(status: status)
            let controller = LoginItemController(service: service)

            try controller.setEnabled(true)

            XCTAssertEqual(service.registerCount, 0)
            XCTAssertEqual(service.unregisterCount, 0)
        }
    }

    func testDisableUnregistersOnlyEnabledOrApprovalPendingService() throws {
        for status in [LoginItemServiceStatus.enabled, .requiresApproval] {
            let service = FakeLoginItemService(status: status)
            let controller = LoginItemController(service: service)

            try controller.setEnabled(false)
            try controller.setEnabled(false)

            XCTAssertEqual(service.registerCount, 0)
            XCTAssertEqual(service.unregisterCount, 1)
            XCTAssertFalse(controller.isEnabled())
        }
    }

    func testDisableDoesNotUnregisterNotRegisteredNotFoundOrUnknownService() throws {
        for status in [LoginItemServiceStatus.notRegistered, .notFound, .unknown] {
            let service = FakeLoginItemService(status: status)
            let controller = LoginItemController(service: service)

            try controller.setEnabled(false)

            XCTAssertEqual(service.registerCount, 0)
            XCTAssertEqual(service.unregisterCount, 0)
        }
    }

    func testRegisterFailureIsGenericAndDoesNotLeakAdapterError() {
        let service = FakeLoginItemService(
            status: .notRegistered,
            registerError: SensitiveLoginItemError(message: "private-register-details")
        )
        let controller = LoginItemController(service: service)

        XCTAssertThrowsError(try controller.setEnabled(true)) { error in
            XCTAssertEqual(error as? LoginItemControllerError, .registrationFailed)
            XCTAssertFalse(String(describing: error).contains("private-register-details"))
        }
    }

    func testUnregisterFailureIsGenericAndDoesNotLeakAdapterError() {
        let service = FakeLoginItemService(
            status: .enabled,
            unregisterError: SensitiveLoginItemError(message: "private-unregister-details")
        )
        let controller = LoginItemController(service: service)

        XCTAssertThrowsError(try controller.setEnabled(false)) { error in
            XCTAssertEqual(error as? LoginItemControllerError, .unregistrationFailed)
            XCTAssertFalse(String(describing: error).contains("private-unregister-details"))
        }
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemServiceAdapting {
    private(set) var status: LoginItemServiceStatus
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private let registerError: Error?
    private let unregisterError: Error?

    init(
        status: LoginItemServiceStatus,
        registerError: Error? = nil,
        unregisterError: Error? = nil
    ) {
        self.status = status
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}

private struct SensitiveLoginItemError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
