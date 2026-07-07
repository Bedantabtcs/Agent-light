import XCTest
@testable import AgentLightCore

@MainActor
final class LoginItemControllerTests: XCTestCase {
    func testStatusExposesEveryServiceStateWithoutCollapsingApprovalPending() {
        for status in LoginItemStatus.allCases {
            let controller = LoginItemController(service: FakeLoginItemService(status: status))
            XCTAssertEqual(controller.status(), status)
        }
    }

    func testEnableReportsRegistrationOwnershipAndResultingEnabledStatus() throws {
        for previous in [LoginItemStatus.notRegistered, .notFound] {
            let service = FakeLoginItemService(status: previous, registerResult: .enabled)
            let controller = LoginItemController(service: service)

            let transition = try controller.setEnabled(true)

            XCTAssertEqual(
                transition,
                LoginItemTransition(
                    previous: previous,
                    current: .enabled,
                    didRegister: true,
                    didUnregister: false
                )
            )
            XCTAssertEqual(service.registerCount, 1)
        }
    }

    func testEnableReportsNewRegistrationThatRequiresSystemApproval() throws {
        let service = FakeLoginItemService(status: .notRegistered, registerResult: .requiresApproval)
        let controller = LoginItemController(service: service)

        let transition = try controller.setEnabled(true)

        XCTAssertEqual(
            transition,
            LoginItemTransition(
                previous: .notRegistered,
                current: .requiresApproval,
                didRegister: true,
                didUnregister: false
            )
        )
        XCTAssertEqual(service.registerCount, 1)
    }

    func testEnableDoesNotClaimOwnershipOfPreexistingEnabledApprovalPendingOrUnknownState() throws {
        for status in [LoginItemStatus.enabled, .requiresApproval, .unknown] {
            let service = FakeLoginItemService(status: status)
            let controller = LoginItemController(service: service)

            let transition = try controller.setEnabled(true)

            XCTAssertEqual(
                transition,
                LoginItemTransition(
                    previous: status,
                    current: status,
                    didRegister: false,
                    didUnregister: false
                )
            )
            XCTAssertEqual(service.registerCount, 0)
        }
    }

    func testDisableReportsUnregistrationOwnershipOnlyForRegisteredStates() throws {
        for status in [LoginItemStatus.enabled, .requiresApproval] {
            let service = FakeLoginItemService(status: status)
            let controller = LoginItemController(service: service)

            let transition = try controller.setEnabled(false)

            XCTAssertEqual(
                transition,
                LoginItemTransition(
                    previous: status,
                    current: .notRegistered,
                    didRegister: false,
                    didUnregister: true
                )
            )
            XCTAssertEqual(service.unregisterCount, 1)
        }
    }

    func testDisableDoesNotMutateOrClaimOwnershipForUnregisteredOrUnknownStates() throws {
        for status in [LoginItemStatus.notRegistered, .notFound, .unknown] {
            let service = FakeLoginItemService(status: status)
            let controller = LoginItemController(service: service)

            let transition = try controller.setEnabled(false)

            XCTAssertEqual(
                transition,
                LoginItemTransition(
                    previous: status,
                    current: status,
                    didRegister: false,
                    didUnregister: false
                )
            )
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
        XCTAssertEqual(controller.status(), .notRegistered)
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
        XCTAssertEqual(controller.status(), .enabled)
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemServiceAdapting {
    private(set) var status: LoginItemStatus
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private let registerResult: LoginItemStatus
    private let registerError: Error?
    private let unregisterError: Error?

    init(
        status: LoginItemStatus,
        registerResult: LoginItemStatus = .enabled,
        registerError: Error? = nil,
        unregisterError: Error? = nil
    ) {
        self.status = status
        self.registerResult = registerResult
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = registerResult
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

private extension LoginItemStatus {
    static let allCases: [LoginItemStatus] = [
        .notRegistered, .enabled, .requiresApproval, .notFound, .unknown
    ]
}
