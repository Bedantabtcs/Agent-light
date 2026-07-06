import Darwin
import Foundation

public protocol TuyaLightControlling: Sendable {
    func captureBaseline() async throws -> BulbBaseline
    func apply(_ state: DesiredLightState) async throws
    func currentStateMatches(_ state: DesiredLightState) async throws -> Bool
    func restore(_ baseline: BulbBaseline) async throws
}

public protocol MonitoringRecoveryStoring: Sendable {
    func load() async throws -> StoredMonitoringRecovery?
    @discardableResult
    func save(_ record: MonitoringRecoveryRecord) async throws -> MonitoringRecoveryRevision
    func clear(expecting stored: StoredMonitoringRecovery) async throws
}

public struct MonitoringRecoveryRevision: Hashable, Sendable {
    private let scope: UUID
    private let generation: UInt64

    init(scope: UUID, generation: UInt64) {
        self.scope = scope
        self.generation = generation
    }

    public init() {
        scope = UUID()
        generation = 0
    }
}

public struct StoredMonitoringRecovery: Equatable, Sendable {
    public let record: MonitoringRecoveryRecord
    public let revision: MonitoringRecoveryRevision

    public init(record: MonitoringRecoveryRecord, revision: MonitoringRecoveryRevision) {
        self.record = record
        self.revision = revision
    }
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
    func duplicate(_ descriptor: Int32) throws -> Int32
    func metadata(for descriptor: Int32) throws -> MonitoringRecoveryFileMetadata
    func sameOpenFile(_ first: Int32, _ second: Int32) throws -> Bool
    func read(from descriptor: Int32, maximumBytes: Int) throws -> Data
    func write(_ data: Data, to descriptor: Int32) throws
    func setMode(_ mode: mode_t, for descriptor: Int32) throws
    func synchronize(_ descriptor: Int32, kind: MonitoringRecoveryDescriptorKind) throws
    func swap(at directory: Int32, _ first: String, _ second: String) throws
    func renameExclusive(at directory: Int32, from: String, to: String) throws
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

    func duplicate(_ descriptor: Int32) throws -> Int32 {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw posixError() }
        return duplicate
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

    func sameOpenFile(_ first: Int32, _ second: Int32) throws -> Bool {
        try metadata(for: first).identity == metadata(for: second).identity
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
    private let revisionScope = UUID()
    private var nextRevisionGeneration: UInt64 = 0
    private var revisionOwnership: [MonitoringRecoveryRevision: RevisionOwnership] = [:]

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

    deinit {
        for ownership in revisionOwnership.values {
            operations.close(ownership.descriptor)
        }
    }

    public func load() throws -> StoredMonitoringRecovery? {
        try Task.checkCancellation()
        let location = try validatedLocation()
        let directory = try openValidatedDirectory(location.parentPath)
        defer { operations.close(directory.descriptor) }
        guard let opened = try openExistingFile(
            directory: directory.descriptor,
            name: location.fileName
        ) else {
            try invalidateDestinationRevisions()
            return nil
        }
        defer { operations.close(opened.descriptor) }
        let data: Data
        do {
            data = try operations.read(
                from: opened.descriptor,
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
        let record: MonitoringRecoveryRecord
        do {
            record = try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: data)
        } catch {
            throw MonitoringRecoveryStoreError.malformedRecord
        }
        try invalidateDestinationRevisions(except: opened.descriptor)
        let generationID = try matchingGenerationID(for: opened.descriptor) ?? UUID()
        let pinnedDescriptor = try duplicateOrIO(opened.descriptor)
        let revision = issueRevision(
            pinnedDescriptor: pinnedDescriptor,
            generationID: generationID,
            location: .destination
        )
        return StoredMonitoringRecovery(record: record, revision: revision)
    }

    @discardableResult
    public func save(_ record: MonitoringRecoveryRecord) throws -> MonitoringRecoveryRevision {
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
        let original = try openExistingFile(
            directory: directory.descriptor,
            name: location.fileName
        )
        defer {
            if let original {
                operations.close(original.descriptor)
            }
        }
        let priorGenerationIDs = try original.map {
            try generationIDs(matching: $0.descriptor)
        } ?? []
        let temporary = try createTemporary(in: directory.descriptor, destination: location.fileName)
        var candidatePinnedDescriptor: Int32?
        defer {
            if let candidatePinnedDescriptor {
                operations.close(candidatePinnedDescriptor)
            }
            operations.close(temporary.descriptor)
        }

        do {
            try operations.setMode(S_IRUSR | S_IWUSR, for: temporary.descriptor)
            try operations.write(data, to: temporary.descriptor)
            try operations.synchronize(temporary.descriptor, kind: .file)
        } catch {
            throw MonitoringRecoveryStoreError.ioFailure
        }
        let preparedMetadata = try metadataOrIO(temporary.descriptor)
        try validateFile(preparedMetadata)
        candidatePinnedDescriptor = try duplicateOrIO(temporary.descriptor)
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
            let displaced = try openExistingFile(
                directory: directory.descriptor,
                name: temporary.name
            )
            defer {
                if let displaced {
                    operations.close(displaced.descriptor)
                }
            }
            guard let displaced,
                  try sameOpenFileOrIO(displaced.descriptor, original.descriptor) else {
                recoverFailedReplacement(
                    directory: directory.descriptor,
                    destination: location.fileName,
                    temporary: temporary.name,
                    originalDescriptor: original.descriptor,
                    priorGenerationIDs: priorGenerationIDs
                )
                throw MonitoringRecoveryStoreError.concurrentModification
            }
            do {
                try operations.synchronize(directory.descriptor, kind: .directory)
            } catch {
                recoverFailedReplacement(
                    directory: directory.descriptor,
                    destination: location.fileName,
                    temporary: temporary.name,
                    originalDescriptor: original.descriptor,
                    priorGenerationIDs: priorGenerationIDs
                )
                throw MonitoringRecoveryStoreError.ioFailure
            }
            do {
                try verifyParent(location.parentPath, matches: directory.metadata)
            } catch {
                recoverFailedReplacement(
                    directory: directory.descriptor,
                    destination: location.fileName,
                    temporary: temporary.name,
                    originalDescriptor: original.descriptor,
                    priorGenerationIDs: priorGenerationIDs
                )
                throw error
            }
        } else {
            do {
                try operations.renameExclusive(
                    at: directory.descriptor,
                    from: temporary.name,
                    to: location.fileName
                )
            } catch MonitoringRecoveryPOSIXError.alreadyExists {
                throw MonitoringRecoveryStoreError.concurrentModification
            } catch {
                throw MonitoringRecoveryStoreError.ioFailure
            }
            do {
                try operations.synchronize(directory.descriptor, kind: .directory)
            } catch {
                throw MonitoringRecoveryStoreError.ioFailure
            }
            try verifyParent(location.parentPath, matches: directory.metadata)
        }
        guard let installed = try openExistingFile(
            directory: directory.descriptor,
            name: location.fileName
        ) else {
            throw MonitoringRecoveryStoreError.concurrentModification
        }
        defer { operations.close(installed.descriptor) }
        guard let pinnedCandidate = candidatePinnedDescriptor,
              try sameOpenFileOrIO(installed.descriptor, temporary.descriptor),
              try sameOpenFileOrIO(installed.descriptor, pinnedCandidate) else {
            throw MonitoringRecoveryStoreError.concurrentModification
        }
        try invalidateDestinationRevisions()
        let revision = issueRevision(
            pinnedDescriptor: pinnedCandidate,
            generationID: UUID(),
            location: .destination
        )
        candidatePinnedDescriptor = nil
        return revision
    }

    public func clear(expecting expected: StoredMonitoringRecovery) throws {
        try Task.checkCancellation()
        let location = try validatedLocation()
        let directory = try openValidatedDirectory(location.parentPath)
        defer { operations.close(directory.descriptor) }
        guard let ownership = revisionOwnership[expected.revision] else {
            throw MonitoringRecoveryStoreError.concurrentModification
        }
        let ownedName: String
        switch ownership.location {
        case .destination:
            ownedName = location.fileName
        case let .tombstone(name):
            ownedName = name
        }
        guard let opened = try openExistingRecord(
            directory: directory.descriptor,
            name: ownedName
        ) else {
            invalidateGeneration(ownership.generationID)
            throw MonitoringRecoveryStoreError.concurrentModification
        }
        defer { operations.close(opened.descriptor) }
        guard opened.record == expected.record,
              try sameOpenFileOrIO(opened.descriptor, ownership.descriptor) else {
            invalidateGeneration(ownership.generationID)
            throw MonitoringRecoveryStoreError.concurrentModification
        }
        try verifyParent(location.parentPath, matches: directory.metadata)
        if case .tombstone = ownership.location {
            try commitPendingClear(
                ownership: ownership,
                opened: opened,
                tombstone: ownedName,
                location: location,
                directory: directory
            )
            return
        }

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
        updateLocation(of: ownership.generationID, to: .tombstone(tombstone))

        guard let moved = try openExistingRecord(directory: directory.descriptor, name: tombstone) else {
            rollbackClear(
                directory: directory.descriptor,
                tombstone: tombstone,
                destination: location.fileName,
                generationID: ownership.generationID
            )
            invalidateGeneration(ownership.generationID)
            throw MonitoringRecoveryStoreError.concurrentModification
        }
        defer { operations.close(moved.descriptor) }
        guard moved.record == expected.record,
              try sameOpenFileOrIO(moved.descriptor, opened.descriptor),
              try sameOpenFileOrIO(moved.descriptor, ownership.descriptor) else {
            rollbackClear(
                directory: directory.descriptor,
                tombstone: tombstone,
                destination: location.fileName,
                generationID: ownership.generationID
            )
            invalidateGeneration(ownership.generationID)
            throw MonitoringRecoveryStoreError.concurrentModification
        }

        if Task.isCancelled {
            rollbackClear(
                directory: directory.descriptor,
                tombstone: tombstone,
                destination: location.fileName,
                generationID: ownership.generationID
            )
            throw CancellationError()
        }
        try commitPendingClear(
            ownership: ownership,
            opened: moved,
            tombstone: tombstone,
            location: location,
            directory: directory
        )
    }

    private func commitPendingClear(
        ownership: RevisionOwnership,
        opened: OpenedRecord,
        tombstone: String,
        location: Location,
        directory: OpenDirectory
    ) throws {
        guard try sameOpenFileOrIO(opened.descriptor, ownership.descriptor) else {
            invalidateGeneration(ownership.generationID)
            throw MonitoringRecoveryStoreError.concurrentModification
        }
        try Task.checkCancellation()
        do {
            try operations.synchronize(directory.descriptor, kind: .directory)
        } catch {
            throw MonitoringRecoveryStoreError.ioFailure
        }
        try verifyParent(location.parentPath, matches: directory.metadata)
        invalidateGeneration(ownership.generationID)
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

    private struct OpenedFile {
        let descriptor: Int32
        let metadata: MonitoringRecoveryFileMetadata
    }

    private struct OpenedRecord {
        let descriptor: Int32
        let record: MonitoringRecoveryRecord
    }

    private struct RevisionOwnership {
        enum Location: Equatable {
            case destination
            case tombstone(String)
        }

        let generationID: UUID
        let descriptor: Int32
        var location: Location
    }

    private func issueRevision(
        pinnedDescriptor: Int32,
        generationID: UUID,
        location: RevisionOwnership.Location
    ) -> MonitoringRecoveryRevision {
        nextRevisionGeneration &+= 1
        let revision = MonitoringRecoveryRevision(
            scope: revisionScope,
            generation: nextRevisionGeneration
        )
        revisionOwnership[revision] = RevisionOwnership(
            generationID: generationID,
            descriptor: pinnedDescriptor,
            location: location
        )
        return revision
    }

    private func duplicateOrIO(_ descriptor: Int32) throws -> Int32 {
        do {
            return try operations.duplicate(descriptor)
        } catch {
            throw MonitoringRecoveryStoreError.ioFailure
        }
    }

    private func sameOpenFileOrIO(_ first: Int32, _ second: Int32) throws -> Bool {
        do {
            return try operations.sameOpenFile(first, second)
        } catch {
            throw MonitoringRecoveryStoreError.ioFailure
        }
    }

    private func matchingGenerationID(for descriptor: Int32) throws -> UUID? {
        for ownership in revisionOwnership.values {
            if try sameOpenFileOrIO(ownership.descriptor, descriptor) {
                return ownership.generationID
            }
        }
        return nil
    }

    private func generationIDs(matching descriptor: Int32) throws -> Set<UUID> {
        var result: Set<UUID> = []
        for ownership in revisionOwnership.values {
            if try sameOpenFileOrIO(ownership.descriptor, descriptor) {
                result.insert(ownership.generationID)
            }
        }
        return result
    }

    private func invalidateDestinationRevisions(except descriptor: Int32? = nil) throws {
        var revisionsToRemove: [MonitoringRecoveryRevision] = []
        for (revision, ownership) in revisionOwnership {
            guard case .destination = ownership.location else { continue }
            if let descriptor,
               try sameOpenFileOrIO(ownership.descriptor, descriptor) {
                continue
            }
            revisionsToRemove.append(revision)
        }
        removeRevisions(revisionsToRemove)
    }

    private func invalidateGeneration(_ generationID: UUID) {
        let revisions = revisionOwnership.compactMap { revision, ownership in
            ownership.generationID == generationID ? revision : nil
        }
        removeRevisions(revisions)
    }

    private func invalidateGenerations(_ generationIDs: Set<UUID>) {
        for generationID in generationIDs {
            invalidateGeneration(generationID)
        }
    }

    private func removeRevisions(_ revisions: [MonitoringRecoveryRevision]) {
        for revision in revisions {
            guard let ownership = revisionOwnership.removeValue(forKey: revision) else { continue }
            operations.close(ownership.descriptor)
        }
    }

    private func updateLocation(
        of generationID: UUID,
        to location: RevisionOwnership.Location
    ) {
        let revisions = revisionOwnership.compactMap { revision, ownership in
            ownership.generationID == generationID ? revision : nil
        }
        for revision in revisions {
            guard var ownership = revisionOwnership[revision] else { continue }
            ownership.location = location
            revisionOwnership[revision] = ownership
        }
    }

    private func updateLocations(
        of generationIDs: Set<UUID>,
        to location: RevisionOwnership.Location
    ) {
        for generationID in generationIDs {
            updateLocation(of: generationID, to: location)
        }
    }

    private func recoverFailedReplacement(
        directory: Int32,
        destination: String,
        temporary: String,
        originalDescriptor: Int32,
        priorGenerationIDs: Set<UUID>
    ) {
        _ = try? operations.swap(at: directory, temporary, destination)

        if name(destination, in: directory, matches: originalDescriptor) {
            updateLocations(of: priorGenerationIDs, to: .destination)
        } else if name(temporary, in: directory, matches: originalDescriptor) {
            updateLocations(of: priorGenerationIDs, to: .tombstone(temporary))
        } else {
            invalidateGenerations(priorGenerationIDs)
        }
    }

    private func name(_ name: String, in directory: Int32, matches descriptor: Int32) -> Bool {
        guard let opened = try? openExistingFile(directory: directory, name: name) else {
            return false
        }
        defer { operations.close(opened.descriptor) }
        return (try? sameOpenFileOrIO(opened.descriptor, descriptor)) == true
    }

    private func rollbackClear(
        directory: Int32,
        tombstone: String,
        destination: String,
        generationID: UUID
    ) {
        do {
            try operations.renameExclusive(
                at: directory,
                from: tombstone,
                to: destination
            )
            updateLocation(of: generationID, to: .destination)
        } catch {
        }
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

    private func openExistingFile(directory: Int32, name: String) throws -> OpenedFile? {
        let descriptor: Int32
        do {
            guard let opened = try operations.openExisting(at: directory, name: name) else {
                return nil
            }
            descriptor = opened
        } catch {
            throw mappedOpenError(error)
        }
        do {
            let metadata = try metadataOrIO(descriptor)
            try validateFile(metadata)
            return OpenedFile(descriptor: descriptor, metadata: metadata)
        } catch {
            operations.close(descriptor)
            throw error
        }
    }

    private func openExistingRecord(directory: Int32, name: String) throws -> OpenedRecord? {
        guard let opened = try openExistingFile(directory: directory, name: name) else {
            return nil
        }
        let data: Data
        do {
            data = try operations.read(
                from: opened.descriptor,
                maximumBytes: Self.maximumRecordBytes + 1
            )
        } catch {
            operations.close(opened.descriptor)
            throw MonitoringRecoveryStoreError.ioFailure
        }
        guard data.count <= Self.maximumRecordBytes else {
            operations.close(opened.descriptor)
            throw MonitoringRecoveryStoreError.recordTooLarge
        }
        do {
            return OpenedRecord(
                descriptor: opened.descriptor,
                record: try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: data)
            )
        } catch let error as MonitoringRecoveryStoreError {
            operations.close(opened.descriptor)
            throw error
        } catch {
            operations.close(opened.descriptor)
            throw MonitoringRecoveryStoreError.malformedRecord
        }
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
        let permissionAndSpecialBits = S_IRWXU | S_IRWXG | S_IRWXO | S_ISUID | S_ISGID | S_ISVTX
        guard metadata.mode & S_IFMT == S_IFREG,
              metadata.owner == geteuid(),
              metadata.mode & permissionAndSpecialBits == S_IRUSR | S_IWUSR,
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
