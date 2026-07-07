import CoreFoundation
import Foundation
import Security
import AgentLightProtocol

public protocol CredentialStoring: Sendable {
    func save(_ credentials: TuyaCredentials) throws
    func load() throws -> TuyaCredentials?
    func delete() throws
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

public final class KeychainCredentialStore: CredentialStoring {
    private let service: String
    private let account: String
    private let operations: any SecurityOperations

    public convenience init(
        service: String = AppIdentity.keychainService,
        account: String = AppIdentity.bundleIdentifier
    ) {
        self.init(service: service, account: account, operations: DarwinSecurityOperations())
    }

    init(service: String, account: String, operations: any SecurityOperations) {
        self.service = service
        self.account = account
        self.operations = operations
    }

    public func save(_ credentials: TuyaCredentials) throws {
        guard TuyaCredentialValidator.isValid(credentials) else {
            throw CredentialStoreError.malformedData
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(credentials)
        } catch {
            throw CredentialStoreError.malformedData
        }

        var attributes = identityQuery()
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
            identityQuery() as CFDictionary,
            attributes: updateAttributes as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw CredentialStoreError.security(operation: .update, status: updateStatus)
        }
    }

    public func load() throws -> TuyaCredentials? {
        var query = identityQuery()
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

    public func delete() throws {
        let status = operations.delete(identityQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.security(operation: .delete, status: status)
        }
    }

    private func identityQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
