import CoreFoundation
import Foundation
import Security
import AgentLightProtocol

public protocol CredentialStoring: Sendable {
    func save(_ credentials: TuyaCredentials) throws
    func load() throws -> TuyaCredentials?
    func delete() throws
}

public protocol PreviousCredentialStoring: Sendable {
    func loadPrevious() throws -> TuyaCredentials?
    func savePrevious(_ credentials: TuyaCredentials) throws
    func deletePrevious() throws
}

public enum CredentialStoreOperation: String, Equatable, Sendable {
    case add
    case update
    case load
    case delete
}

public enum CredentialStoreError: Error, Equatable, Sendable {
    case security(operation: CredentialStoreOperation, status: OSStatus)
    case malformedData
}

extension CredentialStoreError: LocalizedError, CustomStringConvertible {
    public var description: String {
        switch self {
        case let .security(operation, status):
            "Keychain \(operation.rawValue) failed with OSStatus \(status)."
        case .malformedData:
            "Stored credentials are malformed."
        }
    }

    public var errorDescription: String? {
        description
    }
}

protocol SecurityOperations: Sendable {
    func add(_ attributes: CFDictionary) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

struct DarwinSecurityOperations: SecurityOperations {
    func add(_ attributes: CFDictionary) -> OSStatus {
        SecItemAdd(attributes, nil)
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

enum TuyaCredentialValidator {
    static func isValid(_ credentials: TuyaCredentials) -> Bool {
        guard !credentials.accessID.isEmpty,
              !credentials.accessSecret.isEmpty,
              !credentials.deviceID.isEmpty,
              TuyaDataCenter(endpoint: credentials.endpoint) != nil else {
            return false
        }
        return true
    }
}

public final class KeychainCredentialStore: CredentialStoring, PreviousCredentialStoring {
    private let service: String
    private let account: String
    private let previousAccount: String
    private let operations: any SecurityOperations

    public convenience init(
        service: String = AppIdentity.keychainService,
        account: String = AppIdentity.bundleIdentifier
    ) {
        self.init(
            service: service,
            account: account,
            previousAccount: account + ".previous-v1",
            operations: DarwinSecurityOperations()
        )
    }

    init(service: String, account: String, operations: any SecurityOperations) {
        self.service = service
        self.account = account
        previousAccount = account + ".previous-v1"
        self.operations = operations
    }

    init(
        service: String,
        account: String,
        previousAccount: String,
        operations: any SecurityOperations
    ) {
        self.service = service
        self.account = account
        self.previousAccount = previousAccount
        self.operations = operations
    }

    public func save(_ credentials: TuyaCredentials) throws {
        try save(credentials, account: account)
    }

    public func load() throws -> TuyaCredentials? {
        try load(account: account)
    }

    public func delete() throws {
        try delete(account: account)
    }

    public func savePrevious(_ credentials: TuyaCredentials) throws {
        try save(credentials, account: previousAccount)
    }

    public func loadPrevious() throws -> TuyaCredentials? {
        try load(account: previousAccount)
    }

    public func deletePrevious() throws {
        try delete(account: previousAccount)
    }

    private func save(_ credentials: TuyaCredentials, account: String) throws {
        guard TuyaCredentialValidator.isValid(credentials) else {
            throw CredentialStoreError.malformedData
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(credentials)
        } catch {
            throw CredentialStoreError.malformedData
        }

        var attributes = identityQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = operations.add(attributes as CFDictionary)
        if addStatus == errSecSuccess { return }
        guard addStatus == errSecDuplicateItem else {
            throw CredentialStoreError.security(operation: .add, status: addStatus)
        }

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = operations.update(
            identityQuery(account: account) as CFDictionary,
            attributes: updateAttributes as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw CredentialStoreError.security(operation: .update, status: updateStatus)
        }
    }

    private func load(account: String) throws -> TuyaCredentials? {
        var query = identityQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = operations.copyMatching(query as CFDictionary, result: &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw CredentialStoreError.security(operation: .load, status: status)
        }
        guard let data = result as? Data else {
            throw CredentialStoreError.malformedData
        }

        let credentials: TuyaCredentials
        do {
            credentials = try JSONDecoder().decode(TuyaCredentials.self, from: data)
        } catch {
            throw CredentialStoreError.malformedData
        }
        guard TuyaCredentialValidator.isValid(credentials) else {
            throw CredentialStoreError.malformedData
        }
        return credentials
    }

    private func delete(account: String) throws {
        let status = operations.delete(identityQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.security(operation: .delete, status: status)
        }
    }

    private func identityQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
