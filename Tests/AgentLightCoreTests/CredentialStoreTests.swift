import CoreFoundation
import Foundation
import Security
import XCTest
import AgentLightProtocol
@testable import AgentLightCore

final class CredentialStoreTests: XCTestCase {
    private let service = "com.bbatchas.agentlight.tuya.tests"
    private let account = "credential-store-test"

    func testSaveAddsOneGenericPasswordItemWithExactIdentityAccessibilityAndJSON() throws {
        let operations = FakeSecurityOperations()
        let store = makeStore(operations: operations)
        let credentials = makeCredentials()

        try store.save(credentials)

        let add = try XCTUnwrap(operations.addQueries.only)
        XCTAssertEqual(add[kSecClass] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(add[kSecAttrService] as? String, service)
        XCTAssertEqual(add[kSecAttrAccount] as? String, account)
        XCTAssertEqual(
            add[kSecAttrAccessible] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        let encoded = try XCTUnwrap(add[kSecValueData] as? Data)
        XCTAssertEqual(try JSONDecoder().decode(TuyaCredentials.self, from: encoded), credentials)
        XCTAssertEqual(add.count, 5)
        XCTAssertTrue(operations.updateCalls.isEmpty)
    }

    func testDuplicateSaveUpdatesOnlyDataAndAccessibilityUsingExactIdentity() throws {
        let operations = FakeSecurityOperations(addStatuses: [errSecDuplicateItem])
        let store = makeStore(operations: operations)
        let credentials = makeCredentials()

        try store.save(credentials)

        let update = try XCTUnwrap(operations.updateCalls.only)
        assertIdentityQuery(update.query)
        XCTAssertEqual(update.query.count, 3)
        XCTAssertEqual(
            update.attributes[kSecAttrAccessible] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        let encoded = try XCTUnwrap(update.attributes[kSecValueData] as? Data)
        XCTAssertEqual(try JSONDecoder().decode(TuyaCredentials.self, from: encoded), credentials)
        XCTAssertEqual(update.attributes.count, 2)
    }

    func testDuplicateRaceUpdateFailureReportsOnlyUpdateAndStatus() throws {
        let operations = FakeSecurityOperations(
            addStatuses: [errSecDuplicateItem],
            updateStatuses: [errSecItemNotFound]
        )
        let store = makeStore(operations: operations)

        XCTAssertThrowsError(try store.save(makeCredentials())) { error in
            XCTAssertEqual(
                error as? CredentialStoreError,
                .security(operation: .update, status: errSecItemNotFound)
            )
            self.assertRedacted(error)
        }
    }

    func testAddFailureReportsOnlyAddAndStatus() throws {
        let operations = FakeSecurityOperations(addStatuses: [errSecInteractionNotAllowed])
        let store = makeStore(operations: operations)

        XCTAssertThrowsError(try store.save(makeCredentials())) { error in
            XCTAssertEqual(
                error as? CredentialStoreError,
                .security(operation: .add, status: errSecInteractionNotAllowed)
            )
            self.assertRedacted(error)
        }
    }

    func testLoadRequestsOneDataResultAndDecodesCredentials() throws {
        let credentials = makeCredentials()
        let operations = FakeSecurityOperations(
            copyResults: [(errSecSuccess, try JSONEncoder().encode(credentials) as CFData)]
        )
        let store = makeStore(operations: operations)

        XCTAssertEqual(try store.load(), credentials)

        let query = try XCTUnwrap(operations.copyQueries.only)
        assertIdentityQuery(query)
        XCTAssertEqual(query[kSecMatchLimit] as? String, kSecMatchLimitOne as String)
        XCTAssertEqual(query[kSecReturnData] as? Bool, true)
        XCTAssertEqual(query.count, 5)
    }

    func testLoadReturnsNilWhenItemDoesNotExist() throws {
        let operations = FakeSecurityOperations(copyResults: [(errSecItemNotFound, nil)])
        XCTAssertNil(try makeStore(operations: operations).load())
    }

    func testLoadRejectsMalformedJSONWithoutRevealingReturnedBytes() throws {
        let returned = Data("keychain-returned-private-bytes".utf8)
        let operations = FakeSecurityOperations(copyResults: [(errSecSuccess, returned as CFData)])

        XCTAssertThrowsError(try makeStore(operations: operations).load()) { error in
            XCTAssertEqual(error as? CredentialStoreError, .malformedData)
            XCTAssertFalse(String(describing: error).contains("keychain-returned-private-bytes"))
        }
    }

    func testLoadRejectsUnexpectedResultTypeWithoutRevealingIt() throws {
        let returned = "unexpected-keychain-private-value" as CFString
        let operations = FakeSecurityOperations(copyResults: [(errSecSuccess, returned)])

        XCTAssertThrowsError(try makeStore(operations: operations).load()) { error in
            XCTAssertEqual(error as? CredentialStoreError, .malformedData)
            XCTAssertFalse(String(describing: error).contains("unexpected-keychain-private-value"))
        }
    }

    func testLoadRejectsDecodedEndpointOutsideTuyaHTTPSBoundary() throws {
        let invalidEndpoints = [
            "http://openapi.tuyaus.com",
            "https://user:password@openapi.tuyaus.com",
            "https://openapi.tuyaus.com/path",
            "https://openapi.tuyaus.com?private=query",
            "https://openapi.tuyaus.com#fragment"
        ]

        for endpoint in invalidEndpoints {
            let credentials = TuyaCredentials(
                endpoint: try XCTUnwrap(URL(string: endpoint)),
                accessID: "access-id-private",
                accessSecret: "access-secret-private",
                deviceID: "device-id-private"
            )
            let operations = FakeSecurityOperations(
                copyResults: [(errSecSuccess, try JSONEncoder().encode(credentials) as CFData)]
            )

            XCTAssertThrowsError(try makeStore(operations: operations).load()) { error in
                XCTAssertEqual(error as? CredentialStoreError, .malformedData)
                self.assertRedacted(error)
            }
        }
    }

    func testLoadFailureReportsOnlyLoadAndStatus() throws {
        let operations = FakeSecurityOperations(copyResults: [(errSecAuthFailed, nil)])

        XCTAssertThrowsError(try makeStore(operations: operations).load()) { error in
            XCTAssertEqual(
                error as? CredentialStoreError,
                .security(operation: .load, status: errSecAuthFailed)
            )
            self.assertRedacted(error)
        }
    }

    func testDeleteUsesExactIdentity() throws {
        let operations = FakeSecurityOperations()
        try makeStore(operations: operations).delete()

        let query = try XCTUnwrap(operations.deleteQueries.only)
        assertIdentityQuery(query)
        XCTAssertEqual(query.count, 3)
    }

    func testDeleteTreatsNotFoundAsSuccess() throws {
        let operations = FakeSecurityOperations(deleteStatuses: [errSecItemNotFound])
        XCTAssertNoThrow(try makeStore(operations: operations).delete())
    }

    func testDeleteFailureReportsOnlyDeleteAndStatus() throws {
        let operations = FakeSecurityOperations(deleteStatuses: [errSecNotAvailable])

        XCTAssertThrowsError(try makeStore(operations: operations).delete()) { error in
            XCTAssertEqual(
                error as? CredentialStoreError,
                .security(operation: .delete, status: errSecNotAvailable)
            )
            self.assertRedacted(error)
        }
    }

    func testRealKeychainRoundTripWhenEnvironmentPermits() throws {
        let unique = UUID().uuidString
        let store = KeychainCredentialStore(
            service: AppIdentity.keychainService + ".round-trip-tests." + unique,
            account: "round-trip-" + unique
        )
        defer { try? store.delete() }

        do {
            let credentials = makeCredentials()
            try store.save(credentials)
            XCTAssertEqual(try store.load(), credentials)
            try store.delete()
            XCTAssertNil(try store.load())
        } catch let error as CredentialStoreError where error.isEnvironmentKeychainDenial {
            throw XCTSkip("The test environment does not permit Keychain access (status \(error.statusCode)).")
        }
    }

    private func makeStore(operations: FakeSecurityOperations) -> KeychainCredentialStore {
        KeychainCredentialStore(service: service, account: account, operations: operations)
    }

    private func makeCredentials() -> TuyaCredentials {
        TuyaCredentials(
            endpoint: URL(string: "https://openapi.tuyaus.com")!,
            accessID: "access-id-private",
            accessSecret: "access-secret-private",
            deviceID: "device-id-private"
        )
    }

    private func assertIdentityQuery(
        _ query: NSDictionary,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(query[kSecClass] as? String, kSecClassGenericPassword as String, file: file, line: line)
        XCTAssertEqual(query[kSecAttrService] as? String, service, file: file, line: line)
        XCTAssertEqual(query[kSecAttrAccount] as? String, account, file: file, line: line)
    }

    private func assertRedacted(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let description = String(describing: error)
        let sensitiveValues = [
            "access-id-private",
            "access-secret-private",
            "device-id-private",
            "openapi.tuyaus.com",
            service,
            account,
            "kSecAttr",
            "private=query"
        ]
        for value in sensitiveValues {
            XCTAssertFalse(description.contains(value), "Leaked \(value)", file: file, line: line)
        }
    }
}

private final class FakeSecurityOperations: SecurityOperations, @unchecked Sendable {
    struct UpdateCall {
        let query: NSDictionary
        let attributes: NSDictionary
    }

    private(set) var addQueries: [NSDictionary] = []
    private(set) var updateCalls: [UpdateCall] = []
    private(set) var copyQueries: [NSDictionary] = []
    private(set) var deleteQueries: [NSDictionary] = []
    private var addStatuses: [OSStatus]
    private var updateStatuses: [OSStatus]
    private var copyResults: [(OSStatus, CFTypeRef?)]
    private var deleteStatuses: [OSStatus]

    init(
        addStatuses: [OSStatus] = [errSecSuccess],
        updateStatuses: [OSStatus] = [errSecSuccess],
        copyResults: [(OSStatus, CFTypeRef?)] = [(errSecItemNotFound, nil)],
        deleteStatuses: [OSStatus] = [errSecSuccess]
    ) {
        self.addStatuses = addStatuses
        self.updateStatuses = updateStatuses
        self.copyResults = copyResults
        self.deleteStatuses = deleteStatuses
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        addQueries.append(attributes as NSDictionary)
        return addStatuses.removeFirst()
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        updateCalls.append(UpdateCall(query: query as NSDictionary, attributes: attributes as NSDictionary))
        return updateStatuses.removeFirst()
    }

    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus {
        copyQueries.append(query as NSDictionary)
        let next = copyResults.removeFirst()
        result.pointee = next.1
        return next.0
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        deleteQueries.append(query as NSDictionary)
        return deleteStatuses.removeFirst()
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}

private extension CredentialStoreError {
    var statusCode: OSStatus {
        guard case let .security(_, status) = self else { return errSecSuccess }
        return status
    }

    var isEnvironmentKeychainDenial: Bool {
        [errSecMissingEntitlement, errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable]
            .contains(statusCode)
    }
}
