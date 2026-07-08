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
    func openOrCreateWritable(at directory: Int32, name: String, mode: mode_t) throws -> Int32
    func createExclusive(at directory: Int32, name: String, mode: mode_t) throws -> Int32
    func duplicate(_ descriptor: Int32) throws -> Int32
    func metadata(for descriptor: Int32) throws -> MonitoringRecoveryFileMetadata
    func metadata(at directory: Int32, name: String) throws -> MonitoringRecoveryFileMetadata?
    func sameOpenFile(_ first: Int32, _ second: Int32) throws -> Bool
    func read(from descriptor: Int32, maximumBytes: Int) throws -> Data
    func write(_ data: Data, to descriptor: Int32) throws
    func truncate(_ descriptor: Int32) throws
    func setMode(_ mode: mode_t, for descriptor: Int32) throws
    func synchronize(_ descriptor: Int32, kind: MonitoringRecoveryDescriptorKind) throws
    func lockExclusive(_ descriptor: Int32) throws
    func unlock(_ descriptor: Int32)
    func swap(at directory: Int32, _ first: String, _ second: String) throws
    func renameExclusive(at directory: Int32, from: String, to: String) throws
    func renameReplacing(at directory: Int32, from: String, to: String) throws
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

    func openOrCreateWritable(at directory: Int32, name: String, mode: mode_t) throws -> Int32 {
        let descriptor = Darwin.openat(
            directory,
            name,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode
        )
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

    func metadata(at directory: Int32, name: String) throws -> MonitoringRecoveryFileMetadata? {
        var value = stat()
        if fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw posixError()
        }
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

    func truncate(_ descriptor: Int32) throws {
        guard ftruncate(descriptor, 0) == 0,
              lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw posixError()
        }
    }

    func setMode(_ mode: mode_t, for descriptor: Int32) throws {
        guard fchmod(descriptor, mode) == 0 else { throw posixError() }
    }

    func synchronize(_ descriptor: Int32, kind: MonitoringRecoveryDescriptorKind) throws {
        _ = kind
        guard fsync(descriptor) == 0 else { throw posixError() }
    }

    func lockExclusive(_ descriptor: Int32) throws {
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw posixError()
        }
    }

    func unlock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
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

    func renameReplacing(at directory: Int32, from: String, to: String) throws {
        guard renameat(directory, from, directory, to) == 0 else {
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
    private static let maximumLockAttempts = 8
    private static let previousName = ".monitoring-recovery.previous"
    private static let tombstoneName = ".monitoring-recovery.tombstone"
    private static let lockName = ".monitoring-recovery.lock"
    private static let stagingName = ".monitoring-recovery.stage"

    private let url: URL
    private let operations: any MonitoringRecoveryPOSIXOperations
    private let temporaryName: @Sendable () -> String
    private let revisionScope = UUID()
    private var nextRevisionGeneration: UInt64 = 0
    private var revisionOwnership: [MonitoringRecoveryRevision: RevisionOwnership] = [:]

    public init(url: URL) {
        self.url = url
        operations = DarwinMonitoringRecoveryPOSIXOperations()
        temporaryName = { Self.stagingName }
    }

    init(
        url: URL,
        operations: any MonitoringRecoveryPOSIXOperations,
        temporaryName: @escaping @Sendable () -> String = { ".monitoring-recovery.stage" }
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
        let directory = try openLockedDirectory(location)
        defer { close(directory) }

        let selectedName: String
        if try slotExists(location.activeName, in: directory.descriptor) {
            selectedName = location.activeName
        } else if try slotExists(location.tombstoneName, in: directory.descriptor) {
            invalidateAllRevisions()
            return nil
        } else if try slotExists(location.previousName, in: directory.descriptor) {
            selectedName = location.previousName
        } else {
            invalidateAllRevisions()
            return nil
        }

        guard let opened = try openExistingRecord(
            directory: directory.descriptor,
            name: selectedName
        ) else {
            throw MonitoringRecoveryStoreError.concurrentModification
        }
        defer { operations.close(opened.descriptor) }
        try Task.checkCancellation()
        try verifyParent(location.parentPath, matches: directory.metadata)
        try verifyLock(directory, location: location)
        try invalidateRevisions(except: opened.descriptor)
        let generationID = try matchingGenerationID(for: opened.descriptor) ?? UUID()
        let pinnedDescriptor = try duplicateOrIO(opened.descriptor)
        let revision = issueRevision(
            pinnedDescriptor: pinnedDescriptor,
            generationID: generationID,
            location: selectedName
        )
        return StoredMonitoringRecovery(record: opened.record, revision: revision)
    }

    @discardableResult
    public func save(_ record: MonitoringRecoveryRecord) throws -> MonitoringRecoveryRevision {
        try Task.checkCancellation()
        let data = try encoded(record)
        let location = try validatedLocation()
        let directory = try openLockedDirectory(location)
        defer { close(directory) }

        let original = try openExistingFile(
            directory: directory.descriptor,
            name: location.activeName
        )
        defer {
            if let original { operations.close(original.descriptor) }
        }
        let priorGenerationIDs = try original.map {
            try generationIDs(matching: $0.descriptor)
        } ?? []
        let staging = try prepareStaging(
            data,
            directory: directory.descriptor,
            location: location
        )
        var candidatePinnedDescriptor: Int32? = try duplicateOrIO(staging.descriptor)
        defer {
            if let candidatePinnedDescriptor { operations.close(candidatePinnedDescriptor) }
            operations.close(staging.descriptor)
        }

        try Task.checkCancellation()
        try verifyParent(location.parentPath, matches: directory.metadata)
        try verifyLock(directory, location: location)

        var movedOriginal = false
        var installedCandidate = false
        do {
            if let original {
                if try slotExists(location.tombstoneName, in: directory.descriptor) {
                    try renameReplacing(
                        directory: directory.descriptor,
                        from: location.tombstoneName,
                        to: location.previousName
                    )
                }
                try renameReplacing(
                    directory: directory.descriptor,
                    from: location.activeName,
                    to: location.previousName
                )
                movedOriginal = true
                updateLocations(of: priorGenerationIDs, to: location.previousName)
                guard name(location.previousName, in: directory.descriptor, matches: original.descriptor) else {
                    throw MonitoringRecoveryStoreError.concurrentModification
                }
            }

            try renameReplacing(
                directory: directory.descriptor,
                from: staging.name,
                to: location.activeName
            )
            installedCandidate = true
            guard let installed = try openExistingFile(
                directory: directory.descriptor,
                name: location.activeName
            ) else {
                throw MonitoringRecoveryStoreError.concurrentModification
            }
            defer { operations.close(installed.descriptor) }
            guard let pinnedCandidate = candidatePinnedDescriptor,
                  try sameOpenFileOrIO(installed.descriptor, staging.descriptor),
                  try sameOpenFileOrIO(installed.descriptor, pinnedCandidate) else {
                throw MonitoringRecoveryStoreError.concurrentModification
            }

            if original == nil,
               try slotExists(location.tombstoneName, in: directory.descriptor) {
                try renameReplacing(
                    directory: directory.descriptor,
                    from: location.tombstoneName,
                    to: location.previousName
                )
            }
            try synchronizeDirectory(directory.descriptor)
            try verifyParent(location.parentPath, matches: directory.metadata)
            try verifyLock(directory, location: location)
            invalidateAllRevisions()
            let revision = issueRevision(
                pinnedDescriptor: pinnedCandidate,
                generationID: UUID(),
                location: location.activeName
            )
            candidatePinnedDescriptor = nil
            return revision
        } catch {
            if movedOriginal {
                recoverFailedSave(
                    directory: directory.descriptor,
                    location: location,
                    originalDescriptor: original?.descriptor,
                    priorGenerationIDs: priorGenerationIDs,
                    installedCandidate: installedCandidate
                )
            }
            throw mappedOperationError(error)
        }
    }

    public func clear(expecting expected: StoredMonitoringRecovery) throws {
        try Task.checkCancellation()
        let location = try validatedLocation()
        let directory = try openLockedDirectory(location)
        defer { close(directory) }
        guard let ownership = revisionOwnership[expected.revision] else {
            throw MonitoringRecoveryStoreError.concurrentModification
        }
        guard let opened = try openExistingRecord(
            directory: directory.descriptor,
            name: ownership.location
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
        try verifyLock(directory, location: location)

        if ownership.location != location.tombstoneName {
            try renameReplacing(
                directory: directory.descriptor,
                from: ownership.location,
                to: location.tombstoneName
            )
            updateLocation(of: ownership.generationID, to: location.tombstoneName)
            guard let moved = try openExistingRecord(
                directory: directory.descriptor,
                name: location.tombstoneName
            ) else {
                invalidateGeneration(ownership.generationID)
                throw MonitoringRecoveryStoreError.concurrentModification
            }
            defer { operations.close(moved.descriptor) }
            guard moved.record == expected.record,
                  try sameOpenFileOrIO(moved.descriptor, opened.descriptor),
                  try sameOpenFileOrIO(moved.descriptor, ownership.descriptor) else {
                restoreUnexpectedClearReplacement(
                    directory: directory.descriptor,
                    tombstone: location.tombstoneName,
                    destination: ownership.location
                )
                invalidateGeneration(ownership.generationID)
                throw MonitoringRecoveryStoreError.concurrentModification
            }
            if Task.isCancelled {
                rollbackClear(
                    directory: directory.descriptor,
                    tombstone: location.tombstoneName,
                    destination: ownership.location,
                    generationID: ownership.generationID
                )
                throw CancellationError()
            }
        }

        try absorbStagingIfPresent(directory: directory.descriptor, location: location)
        try commitPendingClear(
            ownership: ownership,
            location: location,
            directory: directory
        )
    }

    private struct Location {
        let parentPath: String
        let activeName: String
        let previousName: String
        let tombstoneName: String
        let lockName: String
        let stagingName: String

        var knownNames: [String] {
            [activeName, previousName, tombstoneName, lockName, stagingName]
        }
    }

    private struct OpenDirectory {
        let descriptor: Int32
        let metadata: MonitoringRecoveryFileMetadata
    }

    private struct LockedDirectory {
        let descriptor: Int32
        let metadata: MonitoringRecoveryFileMetadata
        let lockDescriptor: Int32
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
        let generationID: UUID
        let descriptor: Int32
        var location: String
    }

    private func encoded(_ record: MonitoringRecoveryRecord) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(record)
            guard data.count <= Self.maximumRecordBytes else {
                throw MonitoringRecoveryStoreError.recordTooLarge
            }
            return data
        } catch let error as MonitoringRecoveryStoreError {
            throw error
        } catch {
            throw MonitoringRecoveryStoreError.ioFailure
        }
    }

    private func issueRevision(
        pinnedDescriptor: Int32,
        generationID: UUID,
        location: String
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
        do { return try operations.duplicate(descriptor) }
        catch { throw MonitoringRecoveryStoreError.ioFailure }
    }

    private func sameOpenFileOrIO(_ first: Int32, _ second: Int32) throws -> Bool {
        do { return try operations.sameOpenFile(first, second) }
        catch { throw MonitoringRecoveryStoreError.ioFailure }
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

    private func invalidateRevisions(except descriptor: Int32) throws {
        var revisionsToRemove: [MonitoringRecoveryRevision] = []
        for (revision, ownership) in revisionOwnership {
            if try sameOpenFileOrIO(ownership.descriptor, descriptor) { continue }
            revisionsToRemove.append(revision)
        }
        removeRevisions(revisionsToRemove)
    }

    private func invalidateAllRevisions() {
        removeRevisions(Array(revisionOwnership.keys))
    }

    private func invalidateGeneration(_ generationID: UUID) {
        let revisions = revisionOwnership.compactMap { revision, ownership in
            ownership.generationID == generationID ? revision : nil
        }
        removeRevisions(revisions)
    }

    private func invalidateGenerations(_ generationIDs: Set<UUID>) {
        for generationID in generationIDs { invalidateGeneration(generationID) }
    }

    private func removeRevisions(_ revisions: [MonitoringRecoveryRevision]) {
        for revision in revisions {
            guard let ownership = revisionOwnership.removeValue(forKey: revision) else { continue }
            operations.close(ownership.descriptor)
        }
    }

    private func updateLocation(of generationID: UUID, to location: String) {
        let revisions = revisionOwnership.compactMap { revision, ownership in
            ownership.generationID == generationID ? revision : nil
        }
        for revision in revisions {
            guard var ownership = revisionOwnership[revision] else { continue }
            ownership.location = location
            revisionOwnership[revision] = ownership
        }
    }

    private func updateLocations(of generationIDs: Set<UUID>, to location: String) {
        for generationID in generationIDs { updateLocation(of: generationID, to: location) }
    }

    private func recoverFailedSave(
        directory: Int32,
        location: Location,
        originalDescriptor: Int32?,
        priorGenerationIDs: Set<UUID>,
        installedCandidate: Bool
    ) {
        if installedCandidate {
            try? operations.swap(
                at: directory,
                location.previousName,
                location.activeName
            )
        } else {
            try? operations.renameReplacing(
                at: directory,
                from: location.previousName,
                to: location.activeName
            )
        }
        guard let originalDescriptor else {
            invalidateGenerations(priorGenerationIDs)
            return
        }
        if name(location.activeName, in: directory, matches: originalDescriptor) {
            updateLocations(of: priorGenerationIDs, to: location.activeName)
        } else if name(location.previousName, in: directory, matches: originalDescriptor) {
            updateLocations(of: priorGenerationIDs, to: location.previousName)
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
            try operations.renameReplacing(at: directory, from: tombstone, to: destination)
            updateLocation(of: generationID, to: destination)
        } catch {
        }
    }

    private func restoreUnexpectedClearReplacement(
        directory: Int32,
        tombstone: String,
        destination: String
    ) {
        guard (try? slotExists(destination, in: directory)) == false else { return }
        try? operations.renameReplacing(at: directory, from: tombstone, to: destination)
    }

    private func absorbStagingIfPresent(directory: Int32, location: Location) throws {
        guard try slotExists(location.stagingName, in: directory) else { return }
        try renameReplacing(
            directory: directory,
            from: location.stagingName,
            to: location.previousName
        )
    }

    private func commitPendingClear(
        ownership: RevisionOwnership,
        location: Location,
        directory: LockedDirectory
    ) throws {
        guard let tombstone = try openExistingFile(
            directory: directory.descriptor,
            name: location.tombstoneName
        ) else {
            invalidateGeneration(ownership.generationID)
            throw MonitoringRecoveryStoreError.concurrentModification
        }
        defer { operations.close(tombstone.descriptor) }
        guard try sameOpenFileOrIO(tombstone.descriptor, ownership.descriptor) else {
            invalidateGeneration(ownership.generationID)
            throw MonitoringRecoveryStoreError.concurrentModification
        }
        try Task.checkCancellation()
        try synchronizeDirectory(directory.descriptor)
        try verifyParent(location.parentPath, matches: directory.metadata)
        try verifyLock(directory, location: location)
        invalidateGeneration(ownership.generationID)
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
        let activeName = standardized.lastPathComponent
        let reserved = [Self.previousName, Self.tombstoneName, Self.lockName, Self.stagingName]
        guard !reserved.contains(activeName) else {
            throw MonitoringRecoveryStoreError.invalidLocation
        }
        return Location(
            parentPath: standardized.deletingLastPathComponent().path,
            activeName: activeName,
            previousName: Self.previousName,
            tombstoneName: Self.tombstoneName,
            lockName: Self.lockName,
            stagingName: Self.stagingName
        )
    }

    private func openValidatedDirectory(_ path: String) throws -> OpenDirectory {
        let descriptor: Int32
        do { descriptor = try operations.openDirectory(path: path) }
        catch { throw mappedOpenError(error) }
        do {
            let metadata = try operations.metadata(for: descriptor)
            try validateDirectory(metadata)
            return OpenDirectory(descriptor: descriptor, metadata: metadata)
        } catch {
            operations.close(descriptor)
            throw error
        }
    }

    private func openLockedDirectory(_ location: Location) throws -> LockedDirectory {
        let directory = try openValidatedDirectory(location.parentPath)
        do {
            for _ in 0..<Self.maximumLockAttempts {
                let lockDescriptor: Int32
                do {
                    lockDescriptor = try operations.openOrCreateWritable(
                        at: directory.descriptor,
                        name: location.lockName,
                        mode: S_IRUSR | S_IWUSR
                    )
                } catch {
                    throw mappedOpenError(error)
                }
                do {
                    try validateFile(try metadataOrIO(lockDescriptor))
                    try operations.lockExclusive(lockDescriptor)
                    let locked = LockedDirectory(
                        descriptor: directory.descriptor,
                        metadata: directory.metadata,
                        lockDescriptor: lockDescriptor
                    )
                    guard try lockMatchesPath(locked, location: location) else {
                        operations.unlock(lockDescriptor)
                        operations.close(lockDescriptor)
                        continue
                    }
                    try validateKnownSlots(location, directory: directory.descriptor)
                    try Task.checkCancellation()
                    return locked
                } catch {
                    operations.unlock(lockDescriptor)
                    operations.close(lockDescriptor)
                    throw error
                }
            }
            throw MonitoringRecoveryStoreError.concurrentModification
        } catch {
            operations.close(directory.descriptor)
            throw mappedOperationError(error)
        }
    }

    private func close(_ directory: LockedDirectory) {
        operations.unlock(directory.lockDescriptor)
        operations.close(directory.lockDescriptor)
        operations.close(directory.descriptor)
    }

    private func lockMatchesPath(_ directory: LockedDirectory, location: Location) throws -> Bool {
        guard let opened = try openExistingFile(
            directory: directory.descriptor,
            name: location.lockName
        ) else { return false }
        defer { operations.close(opened.descriptor) }
        return try sameOpenFileOrIO(opened.descriptor, directory.lockDescriptor)
    }

    private func verifyLock(_ directory: LockedDirectory, location: Location) throws {
        guard try lockMatchesPath(directory, location: location) else {
            throw MonitoringRecoveryStoreError.concurrentModification
        }
    }

    private func validateKnownSlots(_ location: Location, directory: Int32) throws {
        for name in location.knownNames {
            guard let metadata = try metadataAt(directory: directory, name: name) else { continue }
            try validateFile(metadata)
        }
    }

    private func slotExists(_ name: String, in directory: Int32) throws -> Bool {
        try metadataAt(directory: directory, name: name) != nil
    }

    private func metadataAt(directory: Int32, name: String) throws -> MonitoringRecoveryFileMetadata? {
        do { return try operations.metadata(at: directory, name: name) }
        catch { throw mappedOpenError(error) }
    }

    private func verifyParent(_ path: String, matches expected: MonitoringRecoveryFileMetadata) throws {
        let reopened: OpenDirectory
        do {
            reopened = try openValidatedDirectory(path)
        } catch {
            throw MonitoringRecoveryStoreError.concurrentModification
        }
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
        } catch {
            operations.close(opened.descriptor)
            throw MonitoringRecoveryStoreError.malformedRecord
        }
    }

    private func prepareStaging(
        _ data: Data,
        directory: Int32,
        location: Location
    ) throws -> TemporaryFile {
        for _ in 0..<Self.maximumTemporaryNameAttempts {
            let name = try validatedTemporaryName(location: location)
            let descriptor: Int32
            do {
                descriptor = try operations.createExclusive(
                    at: directory,
                    name: name,
                    mode: S_IRUSR | S_IWUSR
                )
            } catch MonitoringRecoveryPOSIXError.alreadyExists where name == location.stagingName {
                do {
                    descriptor = try operations.openOrCreateWritable(
                        at: directory,
                        name: name,
                        mode: S_IRUSR | S_IWUSR
                    )
                    try validateFile(try metadataOrIO(descriptor))
                } catch {
                    throw mappedOpenError(error)
                }
            } catch MonitoringRecoveryPOSIXError.alreadyExists {
                continue
            } catch {
                throw MonitoringRecoveryStoreError.ioFailure
            }
            do {
                try operations.truncate(descriptor)
                try operations.setMode(S_IRUSR | S_IWUSR, for: descriptor)
                try operations.write(data, to: descriptor)
                try operations.synchronize(descriptor, kind: .file)
                try validateFile(try metadataOrIO(descriptor))
                return TemporaryFile(descriptor: descriptor, name: name)
            } catch {
                operations.close(descriptor)
                throw MonitoringRecoveryStoreError.ioFailure
            }
        }
        throw MonitoringRecoveryStoreError.ioFailure
    }

    private func validatedTemporaryName(location: Location) throws -> String {
        let value = temporaryName()
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value != location.activeName,
              value != location.previousName,
              value != location.tombstoneName,
              value != location.lockName,
              !value.contains("/") else {
            throw MonitoringRecoveryStoreError.invalidLocation
        }
        return value
    }

    private func renameReplacing(directory: Int32, from: String, to: String) throws {
        do {
            try operations.renameReplacing(at: directory, from: from, to: to)
        } catch MonitoringRecoveryPOSIXError.notFound {
            throw MonitoringRecoveryStoreError.concurrentModification
        } catch {
            throw MonitoringRecoveryStoreError.ioFailure
        }
    }

    private func synchronizeDirectory(_ descriptor: Int32) throws {
        do { try operations.synchronize(descriptor, kind: .directory) }
        catch { throw MonitoringRecoveryStoreError.ioFailure }
    }

    private func metadataOrIO(_ descriptor: Int32) throws -> MonitoringRecoveryFileMetadata {
        do { return try operations.metadata(for: descriptor) }
        catch { throw MonitoringRecoveryStoreError.ioFailure }
    }

    private func validateDirectory(_ metadata: MonitoringRecoveryFileMetadata) throws {
        let permissionAndSpecialBits = S_IRWXU | S_IRWXG | S_IRWXO | S_ISUID | S_ISGID | S_ISVTX
        guard metadata.mode & S_IFMT == S_IFDIR,
              metadata.owner == geteuid(),
              metadata.mode & permissionAndSpecialBits == S_IRWXU else {
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

    private func mappedOperationError(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let error = error as? MonitoringRecoveryStoreError { return error }
        return MonitoringRecoveryStoreError.ioFailure
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
