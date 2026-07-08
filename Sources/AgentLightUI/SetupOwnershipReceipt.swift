import Darwin
import Foundation
import AgentLightCore

public enum PersistentIntegrationOwnership: Codable, Equatable, Sendable {
    case none
    case uninstallable(IntegrationInstallReceipt)
    case preexisting(IntegrationInstallReceipt)
    case mixed(IntegrationInstallReceipt)
    case uncertain(IntegrationInstallReceipt?)

    var receipt: IntegrationInstallReceipt? {
        switch self {
        case .none: nil
        case let .uninstallable(receipt), let .preexisting(receipt),
             let .mixed(receipt): receipt
        case let .uncertain(receipt): receipt
        }
    }

    var isValid: Bool {
        switch self {
        case .none:
            true
        case let .uninstallable(receipt):
            receipt.hasVerifiableFingerprints && receipt.overallOwnership == .fresh
        case let .preexisting(receipt):
            receipt.hasVerifiableFingerprints && receipt.overallOwnership == .fullyPreexisting
        case let .mixed(receipt):
            receipt.hasVerifiableFingerprints && receipt.overallOwnership == .mixed
        case let .uncertain(receipt):
            receipt?.hasVerifiableFingerprints ?? true
        }
    }
}

public enum PersistentCredentialOwnership: String, Codable, Equatable, Sendable {
    case none
    case created
    case replacedWithBackup
}

public enum PersistentLoginOwnership: String, Equatable, Sendable {
    case none
    case registered
    case pendingApproval

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case Self.none.rawValue:
            self = .none
        case Self.registered.rawValue, "owned":
            self = .registered
        case Self.pendingApproval.rawValue:
            self = .pendingApproval
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid login ownership")
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension PersistentLoginOwnership: Codable {}

public struct SetupOwnershipReceipt: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public var integration: PersistentIntegrationOwnership
    public var credential: PersistentCredentialOwnership
    public var login: PersistentLoginOwnership
    public var obligations: Set<OutstandingObligation>

    public init(
        version: Int = SetupOwnershipReceipt.currentVersion,
        integration: PersistentIntegrationOwnership = .none,
        credential: PersistentCredentialOwnership = .none,
        login: PersistentLoginOwnership = .none,
        obligations: Set<OutstandingObligation> = []
    ) {
        self.version = version
        self.integration = integration
        self.credential = credential
        self.login = login
        self.obligations = obligations
    }

    var isValid: Bool {
        version == Self.currentVersion && integration.isValid
    }

    var isEmpty: Bool {
        integration == .none && credential == .none && login == .none && obligations.isEmpty
    }
}

public protocol SetupOwnershipStoring: Sendable {
    func load() async throws -> SetupOwnershipReceipt?
    func save(_ receipt: SetupOwnershipReceipt) async throws
    func delete() async throws
    func resetInvalidReceipt() async throws
}

public extension SetupOwnershipStoring {
    func resetInvalidReceipt() async throws {
        throw SetupOwnershipStoreError.resetNotRequired
    }
}

public enum SetupOwnershipStoreError: Error, Equatable, Sendable {
    case unsafeReceipt
    case malformedReceipt
    case unsupportedVersion
    case receiptTooLarge
    case writeFailed
    case readFailed
    case resetNotRequired
    case invalidReceiptAlreadyPreserved
}

extension SetupOwnershipStoreError: LocalizedError, CustomStringConvertible {
    public var description: String {
        switch self {
        case .unsafeReceipt: "Ownership receipt storage is unsafe."
        case .malformedReceipt: "Ownership receipt is malformed."
        case .unsupportedVersion: "Ownership receipt version is unsupported."
        case .receiptTooLarge: "Ownership receipt exceeds its size limit."
        case .writeFailed: "Ownership receipt could not be saved."
        case .readFailed: "Ownership receipt could not be read."
        case .resetNotRequired: "Ownership receipt reset is not required."
        case .invalidReceiptAlreadyPreserved: "An invalid ownership receipt is already preserved."
        }
    }

    public var errorDescription: String? { description }
}

public actor MemorySetupOwnershipStore: SetupOwnershipStoring {
    private var receipt: SetupOwnershipReceipt?

    public init(receipt: SetupOwnershipReceipt? = nil) {
        self.receipt = receipt
    }

    public func load() async throws -> SetupOwnershipReceipt? { receipt }
    public func save(_ receipt: SetupOwnershipReceipt) async throws { self.receipt = receipt }
    public func delete() async throws { receipt = nil }
    public func resetInvalidReceipt() async throws {
        guard let receipt, !receipt.isValid else {
            throw SetupOwnershipStoreError.resetNotRequired
        }
        self.receipt = nil
    }
}

public actor FileSetupOwnershipStore: SetupOwnershipStoring {
    private static let maximumEncodedSize = 64 * 1024
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() async throws -> SetupOwnershipReceipt? {
        let directory = try openDirectory()
        defer { _ = close(directory) }
        return try authenticatedReceipt(name: url.lastPathComponent, in: directory)?.receipt
    }

    private func authenticatedReceipt(
        name: String,
        in directory: Int32
    ) throws -> (receipt: SetupOwnershipReceipt, identity: FileIdentity)? {
        let descriptor = openat(
            directory,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw SetupOwnershipStoreError.unsafeReceipt }
            throw SetupOwnershipStoreError.readFailed
        }
        defer { _ = close(descriptor) }

        let before = try validatedIdentity(for: descriptor)
        guard before.size <= Self.maximumEncodedSize else {
            throw SetupOwnershipStoreError.receiptTooLarge
        }
        let data = try readAll(from: descriptor, expectedSize: before.size)
        let after = try validatedIdentity(for: descriptor)
        guard before == after else { throw SetupOwnershipStoreError.readFailed }

        let version: ReceiptVersion
        do {
            version = try JSONDecoder().decode(ReceiptVersion.self, from: data)
        } catch {
            throw SetupOwnershipStoreError.malformedReceipt
        }
        guard version.version == SetupOwnershipReceipt.currentVersion else {
            throw SetupOwnershipStoreError.unsupportedVersion
        }
        let receipt: SetupOwnershipReceipt
        do {
            receipt = try JSONDecoder().decode(SetupOwnershipReceipt.self, from: data)
        } catch {
            throw SetupOwnershipStoreError.malformedReceipt
        }
        guard receipt.isValid else { throw SetupOwnershipStoreError.malformedReceipt }
        return (receipt, before)
    }

    public func save(_ receipt: SetupOwnershipReceipt) async throws {
        guard receipt.isValid else {
            throw receipt.version == SetupOwnershipReceipt.currentVersion
                ? SetupOwnershipStoreError.malformedReceipt
                : SetupOwnershipStoreError.unsupportedVersion
        }
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(receipt)
        } catch {
            throw SetupOwnershipStoreError.writeFailed
        }
        guard data.count <= Self.maximumEncodedSize else {
            throw SetupOwnershipStoreError.receiptTooLarge
        }

        let directory = try openDirectory()
        defer { _ = close(directory) }
        let name = url.lastPathComponent
        let existing = try authenticatedReceipt(name: name, in: directory)?.identity
        let temporary = ".\(name).agent-light-\(UUID().uuidString)"
        let descriptor = openat(
            directory,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw SetupOwnershipStoreError.writeFailed }
        var descriptorOpen = true
        var temporaryIsOwned = true
        defer {
            if descriptorOpen { _ = close(descriptor) }
            if temporaryIsOwned { _ = unlinkat(directory, temporary, 0) }
        }

        do {
            try writeAll(data, to: descriptor)
            guard fchmod(descriptor, mode_t(0o600)) == 0,
                  fsync(descriptor) == 0 else { throw SetupOwnershipStoreError.writeFailed }
            _ = try validatedIdentity(for: descriptor)
            guard close(descriptor) == 0 else { throw SetupOwnershipStoreError.writeFailed }
            descriptorOpen = false

            if let existing {
                guard renameatx_np(
                    directory,
                    temporary,
                    directory,
                    name,
                    UInt32(RENAME_SWAP)
                ) == 0 else { throw SetupOwnershipStoreError.writeFailed }
                temporaryIsOwned = false
                do {
                    let displaced = try inspectRequired(name: temporary, in: directory)
                    guard displaced == existing else {
                        throw SetupOwnershipStoreError.unsafeReceipt
                    }
                } catch {
                    if renameatx_np(
                        directory,
                        temporary,
                        directory,
                        name,
                        UInt32(RENAME_SWAP)
                    ) == 0 {
                        temporaryIsOwned = true
                    }
                    throw SetupOwnershipStoreError.unsafeReceipt
                }
                do {
                    try sync(directory)
                    guard unlinkat(directory, temporary, 0) == 0 else {
                        throw SetupOwnershipStoreError.writeFailed
                    }
                    temporaryIsOwned = false
                } catch {
                    if renameatx_np(
                        directory,
                        temporary,
                        directory,
                        name,
                        UInt32(RENAME_SWAP)
                    ) == 0 {
                        temporaryIsOwned = true
                        try sync(directory)
                    }
                    throw SetupOwnershipStoreError.writeFailed
                }
                try sync(directory)
            } else {
                guard renameatx_np(
                    directory,
                    temporary,
                    directory,
                    name,
                    UInt32(RENAME_EXCL)
                ) == 0 else {
                    if errno == EEXIST { throw SetupOwnershipStoreError.unsafeReceipt }
                    throw SetupOwnershipStoreError.writeFailed
                }
                temporaryIsOwned = false
                try sync(directory)
            }
            _ = try inspectRequired(name: name, in: directory)
        } catch let error as SetupOwnershipStoreError {
            throw error
        } catch {
            throw SetupOwnershipStoreError.writeFailed
        }
    }

    public func delete() async throws {
        let directory = try openDirectory()
        defer { _ = close(directory) }
        let name = url.lastPathComponent
        guard let existing = try authenticatedReceipt(name: name, in: directory)?.identity else { return }
        let quarantine = ".\(name).agent-light-removal-\(UUID().uuidString)"
        guard renameatx_np(
            directory,
            name,
            directory,
            quarantine,
            UInt32(RENAME_EXCL)
        ) == 0 else { throw SetupOwnershipStoreError.writeFailed }
        var quarantineExists = true
        defer {
            if quarantineExists { _ = renameat(directory, quarantine, directory, name) }
        }
        guard try inspectRequired(name: quarantine, in: directory) == existing else {
            throw SetupOwnershipStoreError.unsafeReceipt
        }
        try sync(directory)
        guard unlinkat(directory, quarantine, 0) == 0 else {
            throw SetupOwnershipStoreError.writeFailed
        }
        quarantineExists = false
        try sync(directory)
    }

    public func resetInvalidReceipt() async throws {
        let directory = try openDirectory()
        defer { _ = close(directory) }
        let name = url.lastPathComponent
        let candidate = try inspect(name: name, in: directory)
        do {
            guard try authenticatedReceipt(name: name, in: directory) != nil else {
                throw SetupOwnershipStoreError.resetNotRequired
            }
            throw SetupOwnershipStoreError.resetNotRequired
        } catch SetupOwnershipStoreError.malformedReceipt,
                SetupOwnershipStoreError.unsupportedVersion,
                SetupOwnershipStoreError.receiptTooLarge {
            // Only explicit reset may preserve an invalid receipt outside the active path.
        }
        guard let existing = candidate,
              try inspectRequired(name: name, in: directory) == existing else {
            throw SetupOwnershipStoreError.unsafeReceipt
        }
        let invalidName = url.deletingPathExtension()
            .appendingPathExtension("invalid")
            .lastPathComponent
        guard try inspect(name: invalidName, in: directory) == nil else {
            throw SetupOwnershipStoreError.invalidReceiptAlreadyPreserved
        }
        guard renameatx_np(
            directory,
            name,
            directory,
            invalidName,
            UInt32(RENAME_EXCL)
        ) == 0 else { throw SetupOwnershipStoreError.writeFailed }
        var preserved = true
        defer {
            if !preserved { _ = renameat(directory, invalidName, directory, name) }
        }
        do {
            guard try inspectRequired(name: invalidName, in: directory) == existing else {
                throw SetupOwnershipStoreError.unsafeReceipt
            }
            try sync(directory)
        } catch {
            preserved = false
            throw error
        }
    }

    private func openDirectory() throws -> Int32 {
        let directory = url.deletingLastPathComponent()
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw SetupOwnershipStoreError.unsafeReceipt
            }
            throw SetupOwnershipStoreError.readFailed
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            _ = close(descriptor)
            throw SetupOwnershipStoreError.unsafeReceipt
        }
        return descriptor
    }

    private func inspect(name: String, in directory: Int32) throws -> FileIdentity? {
        var metadata = stat()
        guard fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw SetupOwnershipStoreError.readFailed
        }
        return try validatedIdentity(metadata)
    }

    private func inspectRequired(name: String, in directory: Int32) throws -> FileIdentity {
        guard let identity = try inspect(name: name, in: directory) else {
            throw SetupOwnershipStoreError.writeFailed
        }
        return identity
    }

    private func validatedIdentity(for descriptor: Int32) throws -> FileIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw SetupOwnershipStoreError.readFailed
        }
        return try validatedIdentity(metadata)
    }

    private func validatedIdentity(_ metadata: stat) throws -> FileIdentity {
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & mode_t(0o777) == mode_t(0o600),
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= Int64(Int.max) else {
            throw SetupOwnershipStoreError.unsafeReceipt
        }
        return FileIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            size: Int(metadata.st_size),
            mode: metadata.st_mode,
            modifiedSeconds: metadata.st_mtimespec.tv_sec,
            modifiedNanoseconds: metadata.st_mtimespec.tv_nsec
        )
    }

    private func readAll(from descriptor: Int32, expectedSize: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(expectedSize)
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, min($0.count, Self.maximumEncodedSize + 1 - result.count))
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw SetupOwnershipStoreError.readFailed
            }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= Self.maximumEncodedSize else {
                throw SetupOwnershipStoreError.receiptTooLarge
            }
        }
        guard result.count == expectedSize else { throw SetupOwnershipStoreError.readFailed }
        return result
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SetupOwnershipStoreError.writeFailed }
                offset += count
            }
        }
    }

    private func sync(_ directory: Int32) throws {
        guard fsync(directory) == 0 else { throw SetupOwnershipStoreError.writeFailed }
    }
}

private struct ReceiptVersion: Decodable {
    let version: Int
}

private struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int
    let mode: mode_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
}
