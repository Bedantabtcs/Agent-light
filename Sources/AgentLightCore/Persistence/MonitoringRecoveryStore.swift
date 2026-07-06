import Darwin
import Foundation

public protocol TuyaLightControlling: Sendable {
    func captureBaseline() async throws -> BulbBaseline
    func apply(_ state: DesiredLightState) async throws
    func currentStateMatches(_ state: DesiredLightState) async throws -> Bool
    func restore(_ baseline: BulbBaseline) async throws
}

public protocol MonitoringRecoveryStoring: Sendable {
    func load() async throws -> MonitoringRecoveryRecord?
    func save(_ record: MonitoringRecoveryRecord) async throws
    func clear() async throws
}

public struct MonitoringRecoveryRecord: Codable, Equatable, Sendable {
    public let baseline: BulbBaseline
    public let lastCommand: DesiredLightState?
    public let pendingCommand: DesiredLightState?

    public init(
        baseline: BulbBaseline,
        lastCommand: DesiredLightState? = nil,
        pendingCommand: DesiredLightState? = nil
    ) {
        self.baseline = baseline
        self.lastCommand = lastCommand
        self.pendingCommand = pendingCommand
    }
}

public enum MonitoringRecoveryStoreError: Error, Equatable, Sendable {
    case invalidLocation
    case unsafeFile
    case malformedRecord
    case recordTooLarge
    case concurrentModification
    case ioFailure
}

extension MonitoringRecoveryStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidLocation:
            "The recovery file location is invalid."
        case .unsafeFile:
            "The recovery file is not a safe private regular file."
        case .malformedRecord:
            "The recovery record is invalid."
        case .recordTooLarge:
            "The recovery record exceeds its size limit."
        case .concurrentModification:
            "The recovery record changed during the operation."
        case .ioFailure:
            "The recovery record could not be accessed."
        }
    }
}

enum MonitoringRecoveryPOSIXError: Error, Equatable, Sendable {
    case notFound
    case alreadyExists
    case system(Int32)
}

enum MonitoringRecoveryDescriptorKind: Equatable, Sendable {
    case file
    case directory
}

struct MonitoringRecoveryFileMetadata: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let mode: mode_t
    let owner: uid_t
    let linkCount: UInt64

    var identity: MonitoringRecoveryFileIdentity {
        MonitoringRecoveryFileIdentity(device: device, inode: inode)
    }
}

struct MonitoringRecoveryFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

protocol MonitoringRecoveryPOSIXOperations: Sendable {
    func openDirectory(path: String) throws -> Int32
    func openExisting(at directory: Int32, name: String) throws -> Int32?
    func createExclusive(at directory: Int32, name: String, mode: mode_t) throws -> Int32
    func metadata(for descriptor: Int32) throws -> MonitoringRecoveryFileMetadata
    func read(from descriptor: Int32, maximumBytes: Int) throws -> Data
    func write(_ data: Data, to descriptor: Int32) throws
    func setMode(_ mode: mode_t, for descriptor: Int32) throws
    func synchronize(_ descriptor: Int32, kind: MonitoringRecoveryDescriptorKind) throws
    func swap(at directory: Int32, _ first: String, _ second: String) throws
    func renameExclusive(at directory: Int32, from: String, to: String) throws
    func unlink(at directory: Int32, name: String) throws
    func close(_ descriptor: Int32)
}

final class DarwinMonitoringRecoveryPOSIXOperations: MonitoringRecoveryPOSIXOperations, @unchecked Sendable {
    func openDirectory(path: String) throws -> Int32 {
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        return descriptor
    }

    func openExisting(at directory: Int32, name: String) throws -> Int32? {
        let descriptor = Darwin.openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw posixError() }
        return descriptor
    }

    func createExclusive(at directory: Int32, name: String, mode: mode_t) throws -> Int32 {
        let descriptor = Darwin.openat(
            directory,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode
        )
        guard descriptor >= 0 else { throw posixError() }
        return descriptor
    }

    func metadata(for descriptor: Int32) throws -> MonitoringRecoveryFileMetadata {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw posixError() }
        return MonitoringRecoveryFileMetadata(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            mode: value.st_mode,
            owner: value.st_uid,
            linkCount: UInt64(value.st_nlink)
        )
    }

    func read(from descriptor: Int32, maximumBytes: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(4096, maximumBytes))
        while result.count < maximumBytes {
            let requested = min(buffer.count, maximumBytes - result.count)
            let count = Darwin.read(descriptor, &buffer, requested)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw MonitoringRecoveryPOSIXError.system(EIO) }
                offset += count
            }
        }
    }

    func setMode(_ mode: mode_t, for descriptor: Int32) throws {
        guard fchmod(descriptor, mode) == 0 else { throw posixError() }
    }

    func synchronize(_ descriptor: Int32, kind: MonitoringRecoveryDescriptorKind) throws {
        _ = kind
        guard fsync(descriptor) == 0 else { throw posixError() }
    }

    func swap(at directory: Int32, _ first: String, _ second: String) throws {
        guard renameatx_np(directory, first, directory, second, UInt32(RENAME_SWAP)) == 0 else {
            throw posixError()
        }
    }

    func renameExclusive(at directory: Int32, from: String, to: String) throws {
        guard renameatx_np(directory, from, directory, to, UInt32(RENAME_EXCL)) == 0 else {
            throw posixError()
        }
    }

    func unlink(at directory: Int32, name: String) throws {
        guard unlinkat(directory, name, 0) == 0 else { throw posixError() }
    }

    func close(_ descriptor: Int32) {
        _ = Darwin.close(descriptor)
    }

    private func posixError() -> MonitoringRecoveryPOSIXError {
        switch errno {
        case ENOENT:
            .notFound
        case EEXIST:
            .alreadyExists
        default:
            .system(errno)
        }
    }
}

public actor FileMonitoringRecoveryStore: MonitoringRecoveryStoring {
    public static let maximumRecordBytes = 64 * 1024
    private static let maximumTemporaryNameAttempts = 8

    private let url: URL
    private let operations: any MonitoringRecoveryPOSIXOperations
    private let temporaryName: @Sendable () -> String

    public init(url: URL) {
        self.url = url
        operations = DarwinMonitoringRecoveryPOSIXOperations()
        temporaryName = {
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        }
    }

    init(
        url: URL,
        operations: any MonitoringRecoveryPOSIXOperations,
        temporaryName: @escaping @Sendable () -> String = {
            ".monitoring-recovery.\(UUID().uuidString).tmp"
        }
    ) {
        self.url = url
        self.operations = operations
        self.temporaryName = temporaryName
    }

    public func load() throws -> MonitoringRecoveryRecord? {
        try Task.checkCancellation()
        let location = try validatedLocation()
        let directory = try openValidatedDirectory(location.parentPath)
        defer { operations.close(directory.descriptor) }
        let descriptor: Int32
        do {
            guard let opened = try operations.openExisting(
                at: directory.descriptor,
                name: location.fileName
            ) else { return nil }
            descriptor = opened
        } catch {
            throw mappedOpenError(error)
        }
        defer { operations.close(descriptor) }
        let metadata = try metadataOrIO(descriptor)
        try validateFile(metadata)
        let data: Data
        do {
            data = try operations.read(
                from: descriptor,
                maximumBytes: Self.maximumRecordBytes + 1
            )
        } catch {
            throw MonitoringRecoveryStoreError.ioFailure
        }
        try Task.checkCancellation()
        guard data.count <= Self.maximumRecordBytes else {
            throw MonitoringRecoveryStoreError.recordTooLarge
        }
        try verifyParent(location.parentPath, matches: directory.metadata)
        do {
            return try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: data)
        } catch {
            throw MonitoringRecoveryStoreError.malformedRecord
        }
    }

    public func save(_ record: MonitoringRecoveryRecord) throws {
        try Task.checkCancellation()
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(record)
        } catch {
            throw MonitoringRecoveryStoreError.ioFailure
        }
        guard data.count <= Self.maximumRecordBytes else {
            throw MonitoringRecoveryStoreError.recordTooLarge
        }

        let location = try validatedLocation()
        let directory = try openValidatedDirectory(location.parentPath)
        defer { operations.close(directory.descriptor) }
        let original = try existingIdentity(
            directory: directory.descriptor,
            name: location.fileName
        )
        let temporary = try createTemporary(in: directory.descriptor, destination: location.fileName)
        var preserveTemporary = false
        var committed = false
        defer {
            operations.close(temporary.descriptor)
            if !committed, !preserveTemporary {
                try? operations.unlink(at: directory.descriptor, name: temporary.name)
            }
        }

        do {
            try operations.setMode(S_IRUSR | S_IWUSR, for: temporary.descriptor)
            try operations.write(data, to: temporary.descriptor)
            try operations.synchronize(temporary.descriptor, kind: .file)
        } catch {
            throw MonitoringRecoveryStoreError.ioFailure
        }
        try Task.checkCancellation()
        try verifyParent(location.parentPath, matches: directory.metadata)

        if let original {
            do {
                try operations.swap(
                    at: directory.descriptor,
                    temporary.name,
                    location.fileName
                )
            } catch {
                throw MonitoringRecoveryStoreError.ioFailure
            }
            let displaced = try existingIdentity(
                directory: directory.descriptor,
                name: temporary.name
            )
            guard displaced == original else {
                do {
                    try operations.swap(
                        at: directory.descriptor,
                        temporary.name,
                        location.fileName
                    )
                    try? operations.unlink(at: directory.descriptor, name: temporary.name)
                } catch {
                    preserveTemporary = true
                }
                throw MonitoringRecoveryStoreError.concurrentModification
            }
            committed = true
            do {
                try operations.unlink(at: directory.descriptor, name: temporary.name)
            } catch {
                preserveTemporary = true
                throw MonitoringRecoveryStoreError.ioFailure
            }
        } else {
            do {
                try operations.renameExclusive(
                    at: directory.descriptor,
                    from: temporary.name,
                    to: location.fileName
                )
                committed = true
            } catch MonitoringRecoveryPOSIXError.alreadyExists {
                throw MonitoringRecoveryStoreError.concurrentModification
            } catch {
                throw MonitoringRecoveryStoreError.ioFailure
            }
        }

        do {
            try operations.synchronize(directory.descriptor, kind: .directory)
        } catch {
            throw MonitoringRecoveryStoreError.ioFailure
        }
        try verifyParent(location.parentPath, matches: directory.metadata)
    }

    public func clear() throws {
        try Task.checkCancellation()
        let location = try validatedLocation()
        let directory = try openValidatedDirectory(location.parentPath)
        defer { operations.close(directory.descriptor) }
        guard let original = try existingIdentity(
            directory: directory.descriptor,
            name: location.fileName
        ) else { return }
        try verifyParent(location.parentPath, matches: directory.metadata)

        var tombstone: String?
        for _ in 0..<Self.maximumTemporaryNameAttempts {
            let candidate = try validatedTemporaryName(destination: location.fileName)
            do {
                try operations.renameExclusive(
                    at: directory.descriptor,
                    from: location.fileName,
                    to: candidate
                )
                tombstone = candidate
                break
            } catch MonitoringRecoveryPOSIXError.alreadyExists {
                continue
            } catch MonitoringRecoveryPOSIXError.notFound {
                throw MonitoringRecoveryStoreError.concurrentModification
            } catch {
                throw MonitoringRecoveryStoreError.ioFailure
            }
        }
        guard let tombstone else { throw MonitoringRecoveryStoreError.ioFailure }
        var preserveTombstone = true
        defer {
            if !preserveTombstone {
                try? operations.unlink(at: directory.descriptor, name: tombstone)
            }
        }

        let moved = try existingIdentity(directory: directory.descriptor, name: tombstone)
        guard moved == original else {
            do {
                try operations.renameExclusive(
                    at: directory.descriptor,
                    from: tombstone,
                    to: location.fileName
                )
                preserveTombstone = false
            } catch {
                preserveTombstone = true
            }
            throw MonitoringRecoveryStoreError.concurrentModification
        }

        if Task.isCancelled {
            do {
                try operations.renameExclusive(
                    at: directory.descriptor,
                    from: tombstone,
                    to: location.fileName
                )
                preserveTombstone = false
            } catch {
                preserveTombstone = true
            }
            throw CancellationError()
        }
        do {
            try operations.unlink(at: directory.descriptor, name: tombstone)
            preserveTombstone = true
            try operations.synchronize(directory.descriptor, kind: .directory)
        } catch {
            throw MonitoringRecoveryStoreError.ioFailure
        }
        try verifyParent(location.parentPath, matches: directory.metadata)
    }

    private struct Location {
        let parentPath: String
        let fileName: String
    }

    private struct OpenDirectory {
        let descriptor: Int32
        let metadata: MonitoringRecoveryFileMetadata
    }

    private struct TemporaryFile {
        let descriptor: Int32
        let name: String
    }

    private func validatedLocation() throws -> Location {
        guard url.isFileURL,
              !url.lastPathComponent.isEmpty,
              url.lastPathComponent != ".",
              url.lastPathComponent != "..",
              !url.lastPathComponent.contains("/") else {
            throw MonitoringRecoveryStoreError.invalidLocation
        }
        let standardized = url.standardizedFileURL
        return Location(
            parentPath: standardized.deletingLastPathComponent().path,
            fileName: standardized.lastPathComponent
        )
    }

    private func openValidatedDirectory(_ path: String) throws -> OpenDirectory {
        let descriptor: Int32
        do {
            descriptor = try operations.openDirectory(path: path)
        } catch {
            throw mappedOpenError(error)
        }
        do {
            let metadata = try operations.metadata(for: descriptor)
            try validateDirectory(metadata)
            return OpenDirectory(descriptor: descriptor, metadata: metadata)
        } catch {
            operations.close(descriptor)
            throw error
        }
    }

    private func verifyParent(
        _ path: String,
        matches expected: MonitoringRecoveryFileMetadata
    ) throws {
        let reopened = try openValidatedDirectory(path)
        defer { operations.close(reopened.descriptor) }
        guard reopened.metadata.identity == expected.identity else {
            throw MonitoringRecoveryStoreError.concurrentModification
        }
    }

    private func existingIdentity(directory: Int32, name: String) throws -> MonitoringRecoveryFileIdentity? {
        let descriptor: Int32
        do {
            guard let opened = try operations.openExisting(at: directory, name: name) else {
                return nil
            }
            descriptor = opened
        } catch {
            throw mappedOpenError(error)
        }
        defer { operations.close(descriptor) }
        let metadata = try metadataOrIO(descriptor)
        try validateFile(metadata)
        return metadata.identity
    }

    private func createTemporary(in directory: Int32, destination: String) throws -> TemporaryFile {
        for _ in 0..<Self.maximumTemporaryNameAttempts {
            let name = try validatedTemporaryName(destination: destination)
            do {
                let descriptor = try operations.createExclusive(
                    at: directory,
                    name: name,
                    mode: S_IRUSR | S_IWUSR
                )
                return TemporaryFile(descriptor: descriptor, name: name)
            } catch MonitoringRecoveryPOSIXError.alreadyExists {
                continue
            } catch {
                throw MonitoringRecoveryStoreError.ioFailure
            }
        }
        throw MonitoringRecoveryStoreError.ioFailure
    }

    private func validatedTemporaryName(destination: String) throws -> String {
        let value = temporaryName()
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value != destination,
              !value.contains("/") else {
            throw MonitoringRecoveryStoreError.invalidLocation
        }
        return value
    }

    private func metadataOrIO(_ descriptor: Int32) throws -> MonitoringRecoveryFileMetadata {
        do {
            return try operations.metadata(for: descriptor)
        } catch {
            throw MonitoringRecoveryStoreError.ioFailure
        }
    }

    private func validateDirectory(_ metadata: MonitoringRecoveryFileMetadata) throws {
        guard metadata.mode & S_IFMT == S_IFDIR,
              metadata.owner == geteuid(),
              metadata.mode & 0o022 == 0 else {
            throw MonitoringRecoveryStoreError.unsafeFile
        }
    }

    private func validateFile(_ metadata: MonitoringRecoveryFileMetadata) throws {
        guard metadata.mode & S_IFMT == S_IFREG,
              metadata.owner == geteuid(),
              metadata.mode & 0o777 == 0o600,
              metadata.linkCount == 1 else {
            throw MonitoringRecoveryStoreError.unsafeFile
        }
    }

    private func mappedOpenError(_ error: any Error) -> MonitoringRecoveryStoreError {
        guard let error = error as? MonitoringRecoveryPOSIXError else { return .ioFailure }
        switch error {
        case .system(ELOOP):
            return .unsafeFile
        case .notFound, .alreadyExists, .system:
            return .ioFailure
        }
    }
}
