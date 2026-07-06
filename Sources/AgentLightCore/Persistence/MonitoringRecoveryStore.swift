import Darwin
import Foundation

public protocol TuyaLightControlling: Sendable {
    func captureBaseline() async throws -> BulbBaseline
    func apply(_ state: DesiredLightState) async throws
    func currentStateMatchesLastCommand() async throws -> Bool
    func currentStateMatches(_ state: DesiredLightState) async throws -> Bool
    func restore(_ baseline: BulbBaseline) async throws
}

public extension TuyaLightControlling {
    func currentStateMatchesLastCommand() async throws -> Bool {
        throw TuyaClientError.apiFailure
    }

    func currentStateMatches(_ state: DesiredLightState) async throws -> Bool {
        _ = state
        return try await currentStateMatchesLastCommand()
    }
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
    case ioFailure
}

extension MonitoringRecoveryStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidLocation:
            "The recovery file location is invalid."
        case .unsafeFile:
            "The recovery file is not a safe regular file."
        case .malformedRecord:
            "The recovery record is invalid."
        case .ioFailure:
            "The recovery record could not be accessed."
        }
    }
}

public actor FileMonitoringRecoveryStore: MonitoringRecoveryStoring {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> MonitoringRecoveryRecord? {
        let path = try validatedPath()
        var metadata = stat()
        if lstat(path, &metadata) != 0 {
            if errno == ENOENT { return nil }
            throw MonitoringRecoveryStoreError.ioFailure
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw MonitoringRecoveryStoreError.unsafeFile
        }
        guard metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == 0o600 else {
            throw MonitoringRecoveryStoreError.unsafeFile
        }

        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw errno == ELOOP
                ? MonitoringRecoveryStoreError.unsafeFile
                : MonitoringRecoveryStoreError.ioFailure
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
            try handle.close()
        } catch {
            throw MonitoringRecoveryStoreError.ioFailure
        }
        do {
            return try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: data)
        } catch {
            throw MonitoringRecoveryStoreError.malformedRecord
        }
    }

    public func save(_ record: MonitoringRecoveryRecord) throws {
        let path = try validatedPath()
        let parent = url.deletingLastPathComponent()
        try validateParent(parent)
        try rejectUnsafeExistingDestination(path)

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(record)
        } catch {
            throw MonitoringRecoveryStoreError.ioFailure
        }

        let temporaryURL = parent.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let temporaryPath = temporaryURL.path
        let descriptor = open(
            temporaryPath,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw MonitoringRecoveryStoreError.ioFailure
        }
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary {
                _ = unlink(temporaryPath)
            }
        }

        do {
            try writeAll(data, to: descriptor)
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
                  fsync(descriptor) == 0,
                  close(descriptor) == 0 else {
                throw MonitoringRecoveryStoreError.ioFailure
            }
            guard rename(temporaryPath, path) == 0 else {
                throw MonitoringRecoveryStoreError.ioFailure
            }
            shouldRemoveTemporary = false
            try synchronizeDirectory(parent.path)
        } catch let error as MonitoringRecoveryStoreError {
            _ = close(descriptor)
            throw error
        } catch {
            _ = close(descriptor)
            throw MonitoringRecoveryStoreError.ioFailure
        }
    }

    public func clear() throws {
        let path = try validatedPath()
        var metadata = stat()
        if lstat(path, &metadata) != 0 {
            if errno == ENOENT { return }
            throw MonitoringRecoveryStoreError.ioFailure
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw MonitoringRecoveryStoreError.unsafeFile
        }
        guard unlink(path) == 0 else {
            throw MonitoringRecoveryStoreError.ioFailure
        }
        try synchronizeDirectory(url.deletingLastPathComponent().path)
    }

    private func validatedPath() throws -> String {
        guard url.isFileURL,
              !url.lastPathComponent.isEmpty,
              url.lastPathComponent != ".",
              url.lastPathComponent != ".." else {
            throw MonitoringRecoveryStoreError.invalidLocation
        }
        return url.standardizedFileURL.path
    }

    private func validateParent(_ parent: URL) throws {
        var metadata = stat()
        guard lstat(parent.standardizedFileURL.path, &metadata) == 0 else {
            throw MonitoringRecoveryStoreError.invalidLocation
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw MonitoringRecoveryStoreError.unsafeFile
        }
        guard metadata.st_uid == geteuid(), metadata.st_mode & 0o022 == 0 else {
            throw MonitoringRecoveryStoreError.unsafeFile
        }
    }

    private func rejectUnsafeExistingDestination(_ path: String) throws {
        var metadata = stat()
        if lstat(path, &metadata) != 0 {
            if errno == ENOENT { return }
            throw MonitoringRecoveryStoreError.ioFailure
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw MonitoringRecoveryStoreError.unsafeFile
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    rawBuffer.count - written
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw MonitoringRecoveryStoreError.ioFailure
                }
                guard result > 0 else {
                    throw MonitoringRecoveryStoreError.ioFailure
                }
                written += result
            }
        }
    }

    private func synchronizeDirectory(_ path: String) throws {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw MonitoringRecoveryStoreError.ioFailure
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw MonitoringRecoveryStoreError.ioFailure
        }
    }
}
