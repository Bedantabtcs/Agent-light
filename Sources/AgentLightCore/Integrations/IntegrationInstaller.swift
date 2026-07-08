import AgentLightProtocol
import CryptoKit
import Darwin
import Foundation

public struct IntegrationPreview: Equatable, Sendable {
    public let source: AgentSource
    public let path: String
    public let before: String
    public let after: String
    public let hadOwnedEntries: Bool

    public init(
        source: AgentSource,
        path: String,
        before: String,
        after: String,
        hadOwnedEntries: Bool
    ) {
        self.source = source
        self.path = path
        self.before = before
        self.after = after
        self.hadOwnedEntries = hadOwnedEntries
    }

    public init(source: AgentSource, path: String, before: String, after: String) {
        self.init(source: source, path: path, before: before, after: after, hadOwnedEntries: false)
    }
}

public enum IntegrationSourceOwnership: String, Codable, Equatable, Sendable {
    case fresh
    case fullyPreexisting
    case partial
}

public enum IntegrationTrustStatus: String, Codable, Equatable, Sendable {
    case notRequired
    case required
    case userConfirmed
}

public enum IntegrationOverallOwnership: Equatable, Sendable {
    case fresh
    case fullyPreexisting
    case mixed
}

public struct IntegrationSourceReceipt: Codable, Equatable, Sendable {
    public let source: AgentSource
    public let ownership: IntegrationSourceOwnership
    public let marker: String?
    public let installedContentFingerprint: String?
    public let trust: IntegrationTrustStatus

    public init(
        source: AgentSource,
        ownership: IntegrationSourceOwnership,
        marker: String? = nil,
        installedContentFingerprint: String? = nil,
        trust: IntegrationTrustStatus? = nil
    ) {
        self.source = source
        self.ownership = ownership
        self.marker = marker
        self.installedContentFingerprint = installedContentFingerprint
        self.trust = trust ?? (source == .codex ? .required : .notRequired)
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case ownership
        case marker
        case installedContentFingerprint
        case trust
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(AgentSource.self, forKey: .source)
        ownership = try container.decode(IntegrationSourceOwnership.self, forKey: .ownership)
        marker = try container.decodeIfPresent(String.self, forKey: .marker)
        installedContentFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .installedContentFingerprint
        )
        trust = try container.decodeIfPresent(IntegrationTrustStatus.self, forKey: .trust)
            ?? (source == .codex ? .required : .notRequired)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(ownership, forKey: .ownership)
        try container.encodeIfPresent(marker, forKey: .marker)
        try container.encodeIfPresent(
            installedContentFingerprint,
            forKey: .installedContentFingerprint
        )
        try container.encode(trust, forKey: .trust)
    }
}

public struct IntegrationInstallReceipt: Codable, Equatable, Sendable {
    public let sources: [IntegrationSourceReceipt]

    public init(sources: [IntegrationSourceReceipt]) {
        self.sources = sources
    }

    public static func validated(
        sources: [IntegrationSourceReceipt]
    ) throws -> IntegrationInstallReceipt {
        let receipt = IntegrationInstallReceipt(sources: sources)
        guard receipt.isValid else { throw IntegrationReceiptValidationError.invalidSources }
        return receipt
    }

    public var isValid: Bool {
        let counts = Dictionary(grouping: sources, by: \.source).mapValues(\.count)
        return sources.count == AgentSource.allCases.count
            && AgentSource.allCases.allSatisfy { counts[$0] == 1 }
    }

    public var overallOwnership: IntegrationOverallOwnership {
        guard isValid else { return .mixed }
        if !sources.isEmpty, sources.allSatisfy({ $0.ownership == .fresh }) { return .fresh }
        if !sources.isEmpty, sources.allSatisfy({ $0.ownership == .fullyPreexisting }) {
            return .fullyPreexisting
        }
        return .mixed
    }

    public var hasVerifiableFingerprints: Bool {
        isValid && sources.allSatisfy { source in
            guard source.marker == AppIdentity.integrationIdentifier,
                  let fingerprint = source.installedContentFingerprint,
                  fingerprint.count == 64 else { return false }
            let hasExpectedTrustBoundary = source.source == .codex
                ? source.trust != .notRequired
                : source.trust == .notRequired
            return hasExpectedTrustBoundary && fingerprint.utf8.allSatisfy {
                ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                    || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
            }
        }
    }
}

public enum IntegrationReceiptValidationError: Error, Equatable, Sendable {
    case invalidSources
}

public protocol IntegrationInstalling: Sendable {
    func preview() async throws -> [IntegrationPreview]
    func install() async throws
    func installWithReceipt() async throws -> IntegrationInstallReceipt
    func repair() async throws
    func repair(using receipt: IntegrationInstallReceipt) async throws -> IntegrationInstallReceipt
    func uninstall() async throws
    func uninstall(using receipt: IntegrationInstallReceipt) async throws
    func verifyArtifactCleanup() async throws -> Bool
}

public extension IntegrationInstalling {
    func installWithReceipt() async throws -> IntegrationInstallReceipt {
        try await install()
        return IntegrationInstallReceipt(
            sources: AgentSource.allCases.map {
                IntegrationSourceReceipt(source: $0, ownership: .partial)
            }
        )
    }

    func verifyArtifactCleanup() async throws -> Bool { false }

    func repair(using receipt: IntegrationInstallReceipt) async throws -> IntegrationInstallReceipt {
        throw IntegrationError.ownershipVerificationFailed
    }

    func uninstall(using receipt: IntegrationInstallReceipt) async throws {
        throw IntegrationError.ownershipVerificationFailed
    }
}

public enum IntegrationError: Error, Equatable {
    case topLevelMustBeObject
    case hooksMustBeObject
    case eventMustBeArray(String)
    case unsupportedCursorVersion
    case unsafeDestination(String)
    case destinationChanged(String)
    case fileOperation(String)
    case verificationFailed(String)
    case committedWithCleanupFailure([String])
    case committedWithReceiptCleanupFailure(receipt: IntegrationInstallReceipt, failures: [String])
    case artifactCleanupFailure([String])
    case rollbackFailed([String])
    case ownershipVerificationFailed
    case receiptRequired
}

public struct IntegrationConfigEditor: Sendable {
    public let source: AgentSource
    public let relayPath: String

    public init(source: AgentSource, relayPath: String) {
        self.source = source
        self.relayPath = relayPath
    }

    public func install(into data: Data) throws -> Data {
        var root = try rootObject(from: data)
        removeOwnedCommands(from: &root)
        var hooks: [String: JSONValue]
        if let existing = root["hooks"] {
            guard case let .object(value) = existing else { throw IntegrationError.hooksMustBeObject }
            hooks = value
        } else {
            hooks = [:]
        }

        for event in events {
            var entries: [JSONValue]
            if let existing = hooks[event] {
                guard case let .array(value) = existing else {
                    throw IntegrationError.eventMustBeArray(event)
                }
                entries = value
            } else {
                entries = []
            }
            entries.append(hookEntry(for: event))
            hooks[event] = .array(entries)
        }
        root["hooks"] = .object(hooks)

        if source == .cursor {
            if let version = root["version"], version != .number(1) {
                throw IntegrationError.unsupportedCursorVersion
            }
            root["version"] = .number(1)
        }
        return try JSONValue.object(root).encodedData()
    }

    public func uninstall(from data: Data) throws -> Data {
        var root = try rootObject(from: data)
        let removed = removeOwnedCommands(from: &root)
        if source == .cursor, removed, root["hooks"] == nil, root.count == 1, root["version"] == .number(1) {
            root.removeValue(forKey: "version")
        }
        return try JSONValue.object(root).encodedData()
    }

    func hasOwnedEntries(in data: Data) throws -> Bool {
        var root = try rootObject(from: data)
        return removeOwnedCommands(from: &root)
    }

    func installedContentFingerprint(in data: Data) throws -> String {
        let root = try rootObject(from: data)
        guard case let .object(hooks)? = root["hooks"] else {
            throw IntegrationError.ownershipVerificationFailed
        }
        var ownedHooks: [String: JSONValue] = [:]
        for (event, value) in hooks {
            guard case let .array(entries) = value else { continue }
            let ownedEntries: [JSONValue]
            if source == .cursor {
                ownedEntries = entries.filter(isOwnedHandler)
            } else {
                ownedEntries = entries.compactMap { entry in
                    guard case var .object(group) = entry,
                          case let .array(handlers)? = group["hooks"] else { return nil }
                    let ownedHandlers = handlers.filter(isOwnedHandler)
                    guard !ownedHandlers.isEmpty else { return nil }
                    group["hooks"] = .array(ownedHandlers)
                    return .object(group)
                }
            }
            if !ownedEntries.isEmpty { ownedHooks[event] = .array(ownedEntries) }
        }
        guard !ownedHooks.isEmpty else { throw IntegrationError.ownershipVerificationFailed }
        var material = Data(AppIdentity.integrationIdentifier.utf8)
        material.append(0)
        material.append(contentsOf: source.rawValue.utf8)
        material.append(0)
        material.append(try JSONValue.object(ownedHooks).encodedData())
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    func ownership(before data: Data, after installed: Data) throws -> IntegrationSourceOwnership {
        guard try hasOwnedEntries(in: data) else { return .fresh }
        return try JSONValue.decode(data) == JSONValue.decode(installed)
            ? .fullyPreexisting
            : .partial
    }

    private var events: [String] {
        switch source {
        case .codex:
            ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop"]
        case .claudeCode:
            [
                "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop",
                "StopFailure", "SessionEnd", "Notification"
            ]
        case .cursor:
            [
                "beforeSubmitPrompt", "preToolUse", "beforeShellExecution", "postToolUse",
                "afterShellExecution", "stop", "sessionEnd"
            ]
        }
    }

    private func rootObject(from data: Data) throws -> [String: JSONValue] {
        guard case let .object(root) = try JSONValue.decode(data) else {
            throw IntegrationError.topLevelMustBeObject
        }
        return root
    }

    private func hookEntry(for event: String) -> JSONValue {
        let directHandler: JSONValue = .object(["command": .string(command(for: event))])
        if source == .cursor {
            return directHandler
        }
        let handler: JSONValue = .object([
            "command": .string(command(for: event)),
            "type": .string("command")
        ])
        return .object(["hooks": .array([handler])])
    }

    private func command(for event: String) -> String {
        "\(shellQuote(relayPath)) --integration-id \(AppIdentity.integrationIdentifier) "
            + "--source \(source.rawValue) --event \(event)"
    }

    @discardableResult
    private func removeOwnedCommands(from root: inout [String: JSONValue]) -> Bool {
        guard case let .object(originalHooks)? = root["hooks"] else { return false }
        var hooks = originalHooks
        var removedAny = false

        for (event, value) in originalHooks {
            guard case let .array(entries) = value else { continue }
            let result = source == .cursor
                ? removingOwnedDirectHandlers(from: entries)
                : removingOwnedNestedHandlers(from: entries)
            guard result.removed else { continue }
            removedAny = true
            if result.entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = .array(result.entries)
            }
        }

        if removedAny {
            if hooks.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = .object(hooks)
            }
        }
        return removedAny
    }

    private func removingOwnedDirectHandlers(from entries: [JSONValue]) -> (entries: [JSONValue], removed: Bool) {
        let filtered = entries.filter { !isOwnedHandler($0) }
        return (filtered, filtered.count != entries.count)
    }

    private func removingOwnedNestedHandlers(from entries: [JSONValue]) -> (entries: [JSONValue], removed: Bool) {
        var result: [JSONValue] = []
        var removedAny = false

        for entry in entries {
            guard case var .object(group) = entry, case let .array(handlers)? = group["hooks"] else {
                result.append(entry)
                continue
            }
            let filtered = handlers.filter { !isOwnedHandler($0) }
            guard filtered.count != handlers.count else {
                result.append(entry)
                continue
            }
            removedAny = true
            if !filtered.isEmpty {
                group["hooks"] = .array(filtered)
                result.append(.object(group))
            } else if Set(group.keys) != ["hooks"] {
                group["hooks"] = .array([])
                result.append(.object(group))
            }
        }
        return (result, removedAny)
    }

    private func isOwnedHandler(_ value: JSONValue) -> Bool {
        guard
            case let .object(handler) = value,
            case let .string(command)? = handler["command"],
            let words = shellWords(command)
        else {
            return false
        }
        return words.indices.dropLast().contains { index in
            words[index] == "--integration-id"
                && words[words.index(after: index)] == AppIdentity.integrationIdentifier
        }
    }
}

public struct IntegrationConfiguration: Equatable, Sendable {
    public let source: AgentSource
    public let url: URL

    public init(source: AgentSource, url: URL) {
        self.source = source
        self.url = url
    }
}

public struct IntegrationConfigurationPaths: Equatable, Sendable {
    public let codex: URL
    public let claudeCode: URL
    public let cursor: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        codex = homeDirectory.appending(path: ".codex/hooks.json")
        claudeCode = homeDirectory.appending(path: ".claude/settings.json")
        cursor = homeDirectory.appending(path: ".cursor/hooks.json")
    }

    public init(codex: URL, claudeCode: URL, cursor: URL) {
        self.codex = codex
        self.claudeCode = claudeCode
        self.cursor = cursor
    }

    public var all: [IntegrationConfiguration] {
        [
            IntegrationConfiguration(source: .codex, url: codex),
            IntegrationConfiguration(source: .claudeCode, url: claudeCode),
            IntegrationConfiguration(source: .cursor, url: cursor)
        ]
    }
}

struct IntegrationFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let mode: mode_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
}

struct IntegrationFileRecord: Equatable, Sendable {
    let data: Data
    let identity: IntegrationFileIdentity

    var mode: mode_t { identity.mode & mode_t(0o7777) }
}

enum IntegrationFileSnapshot: Equatable, Sendable {
    case missing
    case file(IntegrationFileRecord)

    var data: Data {
        switch self {
        case .missing: Data()
        case let .file(record): record.data
        }
    }

    func matchesDisplacedVersion(of expected: IntegrationFileSnapshot) -> Bool {
        switch (self, expected) {
        case (.missing, .missing):
            true
        case let (.file(actual), .file(expected)):
            actual.data == expected.data
                && actual.identity.device == expected.identity.device
                && actual.identity.inode == expected.identity.inode
                && actual.identity.size == expected.identity.size
                && actual.identity.mode == expected.identity.mode
                && actual.identity.modifiedSeconds == expected.identity.modifiedSeconds
                && actual.identity.modifiedNanoseconds == expected.identity.modifiedNanoseconds
        default:
            false
        }
    }
}

protocol IntegrationFileOperating: Sendable {
    func snapshot(at url: URL) throws -> IntegrationFileSnapshot
    func createDirectory(at url: URL) throws
    func writeProtected(_ data: Data, to url: URL) throws
    func replace(
        from source: URL,
        to destination: URL,
        expecting snapshot: IntegrationFileSnapshot
    ) throws
    func remove(at url: URL) throws
    func remove(at url: URL, expecting snapshot: IntegrationFileSnapshot) throws
    func setMode(_ mode: mode_t, at url: URL) throws
    func syncDirectory(at url: URL) throws
}

protocol IntegrationArtifactInspecting: Sendable {
    func names(in directory: URL) throws -> [String]
}

struct FileManagerIntegrationArtifactInspector: IntegrationArtifactInspecting {
    func names(in directory: URL) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
                && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return []
        }
    }
}

protocol IntegrationAtomicRenaming: Sendable {
    func createExclusively(from source: URL, to destination: URL) throws
    func exchange(_ first: URL, with second: URL) throws
}

struct POSIXIntegrationAtomicRenamer: IntegrationAtomicRenaming {
    func createExclusively(from source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST || errno == ENOTEMPTY || errno == ENOENT {
                throw IntegrationError.destinationChanged(destination.path)
            }
            throw posixError("rename configuration exclusively")
        }
    }

    func exchange(_ first: URL, with second: URL) throws {
        guard renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else {
            if errno == ENOENT { throw IntegrationError.destinationChanged(second.path) }
            throw posixError("exchange configuration atomically")
        }
    }
}

private struct IntegrationAtomicRecoveryFailure: Error {
    let failures: [String]
}

struct POSIXIntegrationFileOperations: IntegrationFileOperating {
    private let atomicRenamer: any IntegrationAtomicRenaming

    init(atomicRenamer: any IntegrationAtomicRenaming = POSIXIntegrationAtomicRenamer()) {
        self.atomicRenamer = atomicRenamer
    }

    func snapshot(at url: URL) throws -> IntegrationFileSnapshot {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return .missing }
            if errno == ELOOP { throw IntegrationError.unsafeDestination(url.path) }
            throw posixError("open configuration snapshot")
        }
        defer { _ = close(descriptor) }

        let before = try metadata(for: descriptor, path: url.path)
        guard before.mode & S_IFMT == S_IFREG else {
            throw IntegrationError.unsafeDestination(url.path)
        }
        let data = try readAll(from: descriptor)
        let after = try metadata(for: descriptor, path: url.path)
        guard before == after else { throw IntegrationError.destinationChanged(url.path) }
        return .file(IntegrationFileRecord(data: data, identity: before))
    }

    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func writeProtected(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError("create protected temporary file") }
        var closeNeeded = true
        defer {
            if closeNeeded { _ = close(descriptor) }
        }

        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let address = rawBuffer.baseAddress?.advanced(by: offset)
                let written = Darwin.write(descriptor, address, rawBuffer.count - offset)
                guard written > 0 else { throw posixError("write protected temporary file") }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError("fsync protected temporary file") }
        guard close(descriptor) == 0 else { throw posixError("close protected temporary file") }
        closeNeeded = false
    }

    func replace(
        from source: URL,
        to destination: URL,
        expecting snapshot: IntegrationFileSnapshot
    ) throws {
        switch snapshot {
        case .missing:
            try atomicRenamer.createExclusively(from: source, to: destination)
        case .file:
            try atomicRenamer.exchange(source, with: destination)
            do {
                guard try self.snapshot(at: source).matchesDisplacedVersion(of: snapshot) else {
                    throw IntegrationError.destinationChanged(destination.path)
                }
            } catch {
                let comparisonError = error
                do {
                    try atomicRenamer.exchange(source, with: destination)
                } catch {
                    var failures = [
                        "atomic exchange comparison: \(comparisonError)",
                        "atomic exchange restoration: \(error)",
                        "preserved displaced file: \(source.path)"
                    ]
                    do {
                        try setMode(0o600, at: source)
                    } catch {
                        failures.append("protect displaced file: \(error)")
                    }
                    do {
                        try syncDirectory(at: destination.deletingLastPathComponent())
                    } catch {
                        failures.append("sync preserved exchange state: \(error)")
                    }
                    throw IntegrationAtomicRecoveryFailure(failures: failures)
                }
                throw comparisonError
            }
        }
    }

    func remove(at url: URL) throws {
        if unlink(url.path) != 0, errno != ENOENT {
            throw posixError("remove configuration artifact")
        }
    }

    func remove(at url: URL, expecting snapshot: IntegrationFileSnapshot) throws {
        let directory = url.deletingLastPathComponent()
        let quarantine = directory.appending(
            path: ".\(url.lastPathComponent).agent-light-removal-\(UUID().uuidString)"
        )
        do {
            try atomicRenamer.createExclusively(from: url, to: quarantine)
        } catch {
            throw IntegrationError.destinationChanged(url.path)
        }

        do {
            guard try self.snapshot(at: quarantine).matchesDisplacedVersion(of: snapshot) else {
                throw IntegrationError.destinationChanged(url.path)
            }
        } catch {
            let comparisonError = error
            do {
                try atomicRenamer.createExclusively(from: quarantine, to: url)
                try syncDirectory(at: directory)
            } catch {
                throw IntegrationAtomicRecoveryFailure(failures: [
                    "atomic removal comparison: \(comparisonError)",
                    "atomic removal restoration: \(error)",
                    "preserved recovery artifact: \(quarantine.path)"
                ])
            }
            throw comparisonError
        }

        try remove(at: quarantine)
        try syncDirectory(at: directory)
    }

    func setMode(_ mode: mode_t, at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError("open configuration for mode change") }
        defer { _ = close(descriptor) }
        guard fchmod(descriptor, mode) == 0 else { throw posixError("change configuration mode") }
        guard fsync(descriptor) == 0 else { throw posixError("fsync configuration mode") }
    }

    func syncDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError("open configuration directory") }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError("fsync configuration directory") }
    }

    private func metadata(for descriptor: Int32, path: String) throws -> IntegrationFileIdentity {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw posixError("fstat \(path)") }
        return IntegrationFileIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            size: value.st_size,
            mode: value.st_mode,
            modifiedSeconds: value.st_mtimespec.tv_sec,
            modifiedNanoseconds: value.st_mtimespec.tv_nsec,
            changedSeconds: value.st_ctimespec.tv_sec,
            changedNanoseconds: value.st_ctimespec.tv_nsec
        )
    }

    private func readAll(from descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { return result }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw posixError("read configuration snapshot")
            }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}

public struct IntegrationInstaller: IntegrationInstalling {
    public let relayPath: String
    public let paths: IntegrationConfigurationPaths
    private let fileOperations: any IntegrationFileOperating
    private let artifactInspector: any IntegrationArtifactInspecting

    public init(
        relayPath: String,
        paths: IntegrationConfigurationPaths = IntegrationConfigurationPaths()
    ) {
        self.relayPath = relayPath
        self.paths = paths
        fileOperations = POSIXIntegrationFileOperations()
        artifactInspector = FileManagerIntegrationArtifactInspector()
    }

    init(
        relayPath: String,
        paths: IntegrationConfigurationPaths,
        fileOperations: any IntegrationFileOperating,
        artifactInspector: any IntegrationArtifactInspecting = FileManagerIntegrationArtifactInspector()
    ) {
        self.relayPath = relayPath
        self.paths = paths
        self.fileOperations = fileOperations
        self.artifactInspector = artifactInspector
    }

    public init(relayPath: String, homeDirectory: URL) {
        self.init(relayPath: relayPath, paths: IntegrationConfigurationPaths(homeDirectory: homeDirectory))
    }

    public func preview() async throws -> [IntegrationPreview] {
        try paths.all.map { configuration in
            let before = try fileOperations.snapshot(at: configuration.url).data
            let editor = IntegrationConfigEditor(
                source: configuration.source,
                relayPath: relayPath
            )
            let after = try editor.install(into: before)
            return IntegrationPreview(
                source: configuration.source,
                path: configuration.url.path,
                before: String(decoding: before, as: UTF8.self),
                after: String(decoding: after, as: UTF8.self),
                hadOwnedEntries: try editor.hasOwnedEntries(in: before)
            )
        }
    }

    public func install() async throws {
        _ = try await installWithReceipt()
    }

    public func installWithReceipt() async throws -> IntegrationInstallReceipt {
        let prepared = try paths.all.map { configuration -> (AtomicConfigurationChange, IntegrationSourceReceipt) in
            let before = try fileOperations.snapshot(at: configuration.url)
            let editor = IntegrationConfigEditor(source: configuration.source, relayPath: relayPath)
            let after = try editor.install(into: before.data)
            if try editor.hasOwnedEntries(in: before.data),
               try JSONValue.decode(before.data) != JSONValue.decode(after) {
                throw IntegrationError.ownershipVerificationFailed
            }
            return (
                AtomicConfigurationChange(
                    destination: configuration.url,
                    before: before,
                    after: after
                ),
                IntegrationSourceReceipt(
                    source: configuration.source,
                    ownership: try editor.ownership(before: before.data, after: after),
                    marker: AppIdentity.integrationIdentifier,
                    installedContentFingerprint: try editor.installedContentFingerprint(in: after)
                )
            )
        }
        let receipt = IntegrationInstallReceipt(sources: prepared.map(\.1))
        let cleanupFailures = try AtomicConfigurationWriter(fileOperations: fileOperations)
            .apply(prepared.map(\.0))
        if !cleanupFailures.isEmpty {
            throw IntegrationError.committedWithReceiptCleanupFailure(
                receipt: receipt,
                failures: cleanupFailures
            )
        }
        return receipt
    }

    public func repair() async throws {
        throw IntegrationError.ownershipVerificationFailed
    }

    public func repair(using receipt: IntegrationInstallReceipt) async throws -> IntegrationInstallReceipt {
        let prepared = try verifiedChanges(using: receipt) { editor, data in
            try editor.install(into: data)
        }
        guard prepared.contains(where: { change, _ in
            change.before.data != change.after
        }) else {
            return receipt
        }
        let updatedReceipt = IntegrationInstallReceipt(
            sources: try prepared.map { change, sourceReceipt in
                let editor = IntegrationConfigEditor(source: sourceReceipt.source, relayPath: relayPath)
                return IntegrationSourceReceipt(
                    source: sourceReceipt.source,
                    ownership: sourceReceipt.ownership,
                    marker: AppIdentity.integrationIdentifier,
                    installedContentFingerprint: try editor.installedContentFingerprint(in: change.after)
                )
            }
        )
        let cleanupFailures = try AtomicConfigurationWriter(fileOperations: fileOperations)
            .apply(prepared.map(\.0))
        if !cleanupFailures.isEmpty {
            throw IntegrationError.committedWithReceiptCleanupFailure(
                receipt: updatedReceipt,
                failures: cleanupFailures
            )
        }
        return updatedReceipt
    }

    public func uninstall() async throws {
        throw IntegrationError.receiptRequired
    }

    public func uninstall(using receipt: IntegrationInstallReceipt) async throws {
        guard receipt.hasVerifiableFingerprints, receipt.overallOwnership == .fresh else {
            throw IntegrationError.ownershipVerificationFailed
        }
        let changes = try verifiedChanges(using: receipt) { editor, data in
            try editor.uninstall(from: data)
        }.map(\.0)
        let cleanupFailures = try AtomicConfigurationWriter(fileOperations: fileOperations).apply(changes)
        if !cleanupFailures.isEmpty {
            throw IntegrationError.artifactCleanupFailure(cleanupFailures)
        }
    }

    private func verifiedChanges(
        using receipt: IntegrationInstallReceipt,
        transform: (IntegrationConfigEditor, Data) throws -> Data
    ) throws -> [(AtomicConfigurationChange, IntegrationSourceReceipt)] {
        guard receipt.hasVerifiableFingerprints else {
            throw IntegrationError.ownershipVerificationFailed
        }
        let receipts = Dictionary(uniqueKeysWithValues: receipt.sources.map { ($0.source, $0) })
        return try paths.all.map { configuration in
            guard let sourceReceipt = receipts[configuration.source],
                  let expected = sourceReceipt.installedContentFingerprint else {
                throw IntegrationError.ownershipVerificationFailed
            }
            let before = try fileOperations.snapshot(at: configuration.url)
            guard case .file = before else { throw IntegrationError.ownershipVerificationFailed }
            let editor = IntegrationConfigEditor(source: configuration.source, relayPath: relayPath)
            guard try editor.installedContentFingerprint(in: before.data) == expected else {
                throw IntegrationError.ownershipVerificationFailed
            }
            return (
                AtomicConfigurationChange(
                    destination: configuration.url,
                    before: before,
                    after: try transform(editor, before.data)
                ),
                sourceReceipt
            )
        }
    }

    public func verifyArtifactCleanup() async throws -> Bool {
        for configuration in paths.all {
            let directory = configuration.url.deletingLastPathComponent()
            let base = configuration.url.lastPathComponent
            let prefixes = [
                ".\(base).agent-light-staged-",
                ".\(base).agent-light-rollback-"
            ]
            let names = try artifactInspector.names(in: directory)
            if names.contains(where: { name in prefixes.contains(where: name.hasPrefix) }) {
                return false
            }
        }
        return true
    }

}

private struct AtomicConfigurationChange {
    let destination: URL
    let before: IntegrationFileSnapshot
    let after: Data

    var intendedMode: mode_t {
        switch before {
        case .missing:
            0o600
        case let .file(record):
            record.mode & mode_t(0o777)
        }
    }
}

private struct PreparedConfigurationChange {
    let change: AtomicConfigurationChange
    let staged: URL
    let rollback: URL?
}

private struct AtomicConfigurationWriter {
    let fileOperations: any IntegrationFileOperating

    func apply(_ changes: [AtomicConfigurationChange]) throws -> [String] {
        var prepared: [PreparedConfigurationChange] = []
        var renamedCount = 0

        do {
            for change in changes {
                prepared.append(try prepare(change))
            }
            for item in prepared {
                try verifyUnchanged(item.change.before, at: item.change.destination)
                try fileOperations.replace(
                    from: item.staged,
                    to: item.change.destination,
                    expecting: item.change.before
                )
                renamedCount += 1
                if case .file = item.change.before {
                    try fileOperations.setMode(0o600, at: item.staged)
                }
                try fileOperations.syncDirectory(at: item.change.destination.deletingLastPathComponent())
                try verify(
                    item.change.after,
                    mode: item.change.intendedMode,
                    at: item.change.destination
                )
            }
        } catch {
            if let recoveryFailure = error as? IntegrationAtomicRecoveryFailure {
                throw IntegrationError.rollbackFailed(recoveryFailure.failures)
            }
            let failures = rollback(
                prepared: prepared,
                renamedCount: renamedCount,
                originalError: error
            )
            if failures.isEmpty { throw error }
            throw IntegrationError.rollbackFailed(failures)
        }

        return cleanupCommittedArtifacts(prepared)
    }

    private func prepare(_ change: AtomicConfigurationChange) throws -> PreparedConfigurationChange {
        let directory = change.destination.deletingLastPathComponent()
        try fileOperations.createDirectory(at: directory)
        let nonce = UUID().uuidString
        let base = change.destination.lastPathComponent
        let staged = directory.appending(path: ".\(base).agent-light-staged-\(nonce)")
        let rollback: URL?
        switch change.before {
        case .missing:
            rollback = nil
        case .file:
            rollback = directory.appending(path: ".\(base).agent-light-rollback-\(nonce)")
        }

        do {
            try fileOperations.writeProtected(change.after, to: staged)
            try fileOperations.setMode(change.intendedMode, at: staged)
            try verify(change.after, mode: change.intendedMode, at: staged)
            if let rollback {
                try fileOperations.writeProtected(change.before.data, to: rollback)
                try verify(change.before.data, mode: 0o600, at: rollback)
            }
            return PreparedConfigurationChange(change: change, staged: staged, rollback: rollback)
        } catch {
            var failures = ["original: \(error)"]
            failures.append(contentsOf: cleanupArtifacts([staged, rollback].compactMap { $0 }))
            if failures.count > 1 { throw IntegrationError.rollbackFailed(failures) }
            throw error
        }
    }

    private func verifyUnchanged(_ expected: IntegrationFileSnapshot, at url: URL) throws {
        let current = try fileOperations.snapshot(at: url)
        guard current == expected else { throw IntegrationError.destinationChanged(url.path) }
    }

    private func verify(_ expectedData: Data, mode: mode_t, at url: URL) throws {
        guard case let .file(record) = try fileOperations.snapshot(at: url) else {
            throw IntegrationError.verificationFailed(url.path)
        }
        guard
            record.data == expectedData,
            record.mode & mode_t(0o777) == mode,
            try JSONValue.decode(record.data) == JSONValue.decode(expectedData)
        else {
            throw IntegrationError.verificationFailed(url.path)
        }
    }

    private func rollback(
        prepared: [PreparedConfigurationChange],
        renamedCount: Int,
        originalError: Error
    ) -> [String] {
        var failures: [String] = []
        var failedRestorationArtifacts: Set<URL> = []

        for item in prepared.prefix(renamedCount).reversed() {
            do {
                try restore(item)
            } catch {
                failures.append("restore \(item.change.destination.path): \(error)")
                failedRestorationArtifacts.insert(item.staged)
                if let rollback = item.rollback {
                    failedRestorationArtifacts.insert(rollback)
                }
            }
        }

        var removable: [URL] = []
        for item in prepared {
            if !failedRestorationArtifacts.contains(item.staged) {
                removable.append(item.staged)
            }
            if let rollback = item.rollback, !failedRestorationArtifacts.contains(rollback) {
                removable.append(rollback)
            }
        }
        failures.append(contentsOf: cleanupArtifacts(removable))
        if !failures.isEmpty {
            failures.insert("original: \(originalError)", at: 0)
        }
        return failures
    }

    private func restore(_ item: PreparedConfigurationChange) throws {
        let installedSnapshot = try fileOperations.snapshot(at: item.change.destination)
        try verifySnapshot(
            installedSnapshot,
            expectedData: item.change.after,
            mode: item.change.intendedMode,
            path: item.change.destination.path
        )
        switch item.change.before {
        case .missing:
            try fileOperations.remove(at: item.change.destination, expecting: installedSnapshot)
        case let .file(record):
            guard let rollback = item.rollback else {
                throw IntegrationError.verificationFailed("missing rollback for \(item.change.destination.path)")
            }
            try fileOperations.replace(
                from: rollback,
                to: item.change.destination,
                expecting: installedSnapshot
            )
            try fileOperations.setMode(record.mode, at: item.change.destination)
            guard case let .file(restored) = try fileOperations.snapshot(at: item.change.destination),
                  restored.data == record.data,
                  restored.mode == record.mode
            else {
                throw IntegrationError.verificationFailed("restore \(item.change.destination.path)")
            }
        }
        try fileOperations.syncDirectory(at: item.change.destination.deletingLastPathComponent())
    }

    private func verifySnapshot(
        _ snapshot: IntegrationFileSnapshot,
        expectedData: Data,
        mode: mode_t,
        path: String
    ) throws {
        guard case let .file(record) = snapshot else {
            throw IntegrationError.verificationFailed(path)
        }
        guard
            record.data == expectedData,
            record.mode & mode_t(0o777) == mode,
            try JSONValue.decode(record.data) == JSONValue.decode(expectedData)
        else {
            throw IntegrationError.verificationFailed(path)
        }
    }

    private func cleanupCommittedArtifacts(_ prepared: [PreparedConfigurationChange]) -> [String] {
        cleanupArtifacts(prepared.flatMap { [$0.staged, $0.rollback].compactMap { $0 } })
    }

    private func cleanupArtifacts(_ artifacts: [URL]) -> [String] {
        var failures: [String] = []
        var changedDirectories: Set<URL> = []
        for artifact in artifacts {
            do {
                try fileOperations.remove(at: artifact)
                changedDirectories.insert(artifact.deletingLastPathComponent())
            } catch {
                failures.append("remove \(artifact.path): \(error)")
            }
        }
        for directory in changedDirectories {
            do {
                try fileOperations.syncDirectory(at: directory)
            } catch {
                failures.append("sync \(directory.path): \(error)")
            }
        }
        return failures
    }
}

private func posixError(_ operation: String) -> IntegrationError {
    let code = errno
    let message = String(cString: strerror(code))
    return .fileOperation("\(operation): \(message) (\(code))")
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func shellWords(_ command: String) -> [String]? {
    enum State {
        case normal
        case singleQuoted
        case doubleQuoted
    }

    var state = State.normal
    var words: [String] = []
    var current = ""
    var hasToken = false
    var index = command.startIndex

    func finishToken() {
        if hasToken {
            words.append(current)
            current = ""
            hasToken = false
        }
    }

    while index < command.endIndex {
        let character = command[index]
        switch state {
        case .normal:
            if character.isWhitespace {
                finishToken()
            } else if character == "'" {
                state = .singleQuoted
                hasToken = true
            } else if character == "\"" {
                state = .doubleQuoted
                hasToken = true
            } else if character == "\\" {
                index = command.index(after: index)
                guard index < command.endIndex else { return nil }
                current.append(command[index])
                hasToken = true
            } else {
                current.append(character)
                hasToken = true
            }
        case .singleQuoted:
            if character == "'" {
                state = .normal
            } else {
                current.append(character)
            }
        case .doubleQuoted:
            if character == "\"" {
                state = .normal
            } else if character == "\\" {
                index = command.index(after: index)
                guard index < command.endIndex else { return nil }
                current.append(command[index])
            } else {
                current.append(character)
            }
        }
        index = command.index(after: index)
    }
    guard state == .normal else { return nil }
    finishToken()
    return words
}
