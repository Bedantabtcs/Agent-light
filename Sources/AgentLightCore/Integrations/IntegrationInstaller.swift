import AgentLightProtocol
import Darwin
import Foundation

public struct IntegrationPreview: Equatable, Sendable {
    public let source: AgentSource
    public let path: String
    public let before: String
    public let after: String

    public init(source: AgentSource, path: String, before: String, after: String) {
        self.source = source
        self.path = path
        self.before = before
        self.after = after
    }
}

public protocol IntegrationInstalling: Sendable {
    func preview() async throws -> [IntegrationPreview]
    func install() async throws
    func repair() async throws
    func uninstall() async throws
}

public enum IntegrationError: Error, Equatable {
    case topLevelMustBeObject
    case hooksMustBeObject
    case eventMustBeArray(String)
    case unsupportedCursorVersion
    case unsafeDestination(String)
    case fileOperation(String)
    case verificationFailed(String)
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

public struct IntegrationInstaller: IntegrationInstalling {
    public let relayPath: String
    public let paths: IntegrationConfigurationPaths

    public init(
        relayPath: String,
        paths: IntegrationConfigurationPaths = IntegrationConfigurationPaths()
    ) {
        self.relayPath = relayPath
        self.paths = paths
    }

    public init(relayPath: String, homeDirectory: URL) {
        self.init(relayPath: relayPath, paths: IntegrationConfigurationPaths(homeDirectory: homeDirectory))
    }

    public func preview() async throws -> [IntegrationPreview] {
        try paths.all.map { configuration in
            let before = try existingData(at: configuration.url)
            let after = try IntegrationConfigEditor(
                source: configuration.source,
                relayPath: relayPath
            ).install(into: before)
            return IntegrationPreview(
                source: configuration.source,
                path: configuration.url.path,
                before: String(decoding: before, as: UTF8.self),
                after: String(decoding: after, as: UTF8.self)
            )
        }
    }

    public func install() async throws {
        try apply { editor, data in try editor.install(into: data) }
    }

    public func repair() async throws {
        try apply { editor, data in try editor.install(into: data) }
    }

    public func uninstall() async throws {
        let existingConfigurations = paths.all.filter {
            FileManager.default.fileExists(atPath: $0.url.path)
        }
        try apply(configurations: existingConfigurations) { editor, data in
            try editor.uninstall(from: data)
        }
    }

    private func apply(
        configurations: [IntegrationConfiguration]? = nil,
        transform: (IntegrationConfigEditor, Data) throws -> Data
    ) throws {
        let selected = configurations ?? paths.all
        let changes = try selected.map { configuration in
            let before = try existingData(at: configuration.url)
            let editor = IntegrationConfigEditor(source: configuration.source, relayPath: relayPath)
            return AtomicConfigurationChange(
                destination: configuration.url,
                before: before,
                destinationExisted: FileManager.default.fileExists(atPath: configuration.url.path),
                after: try transform(editor, before)
            )
        }
        try AtomicConfigurationWriter().apply(changes)
    }

    private func existingData(at url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else { return Data() }
        try validateRegularFile(at: url)
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}

private struct AtomicConfigurationChange {
    let destination: URL
    let before: Data
    let destinationExisted: Bool
    let after: Data
}

private struct PreparedConfigurationChange {
    let change: AtomicConfigurationChange
    let staged: URL
    let rollback: URL?
    let originalMode: mode_t?
}

private struct AtomicConfigurationWriter {
    func apply(_ changes: [AtomicConfigurationChange]) throws {
        var prepared: [PreparedConfigurationChange] = []
        var committedCount = 0

        do {
            for change in changes {
                prepared.append(try prepare(change))
            }
            for item in prepared {
                guard rename(item.staged.path, item.change.destination.path) == 0 else {
                    throw posixError("rename staged configuration")
                }
                committedCount += 1
                try syncDirectory(item.change.destination.deletingLastPathComponent())
                try verify(item.change.after, at: item.change.destination)
            }
            for item in prepared {
                if let rollback = item.rollback {
                    try removeIfPresent(rollback)
                }
            }
        } catch {
            for item in prepared.prefix(committedCount).reversed() {
                try? restore(item)
            }
            for item in prepared {
                try? removeIfPresent(item.staged)
                if let rollback = item.rollback {
                    try? removeIfPresent(rollback)
                }
            }
            throw error
        }
    }

    private func prepare(_ change: AtomicConfigurationChange) throws -> PreparedConfigurationChange {
        let directory = change.destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if change.destinationExisted {
            try validateRegularFile(at: change.destination)
        }

        let nonce = UUID().uuidString
        let base = change.destination.lastPathComponent
        let staged = directory.appending(path: ".\(base).agent-light-staged-\(nonce)")
        let rollback = change.destinationExisted
            ? directory.appending(path: ".\(base).agent-light-rollback-\(nonce)")
            : nil
        let originalMode = change.destinationExisted ? try fileMode(at: change.destination) : nil

        do {
            try writeProtected(change.after, to: staged)
            try verify(change.after, at: staged)
            if let rollback {
                try writeProtected(change.before, to: rollback)
                try verify(change.before, at: rollback)
            }
            return PreparedConfigurationChange(
                change: change,
                staged: staged,
                rollback: rollback,
                originalMode: originalMode
            )
        } catch {
            try? removeIfPresent(staged)
            if let rollback { try? removeIfPresent(rollback) }
            throw error
        }
    }

    private func restore(_ item: PreparedConfigurationChange) throws {
        if let rollback = item.rollback {
            guard rename(rollback.path, item.change.destination.path) == 0 else {
                throw posixError("restore configuration")
            }
            if let originalMode = item.originalMode,
               chmod(item.change.destination.path, originalMode) != 0 {
                throw posixError("restore configuration mode")
            }
        } else if unlink(item.change.destination.path) != 0, errno != ENOENT {
            throw posixError("remove new configuration during rollback")
        }
        try syncDirectory(item.change.destination.deletingLastPathComponent())
    }

    private func verify(_ expectedData: Data, at url: URL) throws {
        try validateRegularFile(at: url)
        let actualData = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard
            try JSONValue.decode(actualData) == JSONValue.decode(expectedData),
            try fileMode(at: url) & mode_t(0o777) == mode_t(0o600)
        else {
            throw IntegrationError.verificationFailed(url.path)
        }
    }
}

private func validateRegularFile(at url: URL) throws {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { throw posixError("inspect \(url.path)") }
    guard metadata.st_mode & S_IFMT == S_IFREG else {
        throw IntegrationError.unsafeDestination(url.path)
    }
}

private func fileMode(at url: URL) throws -> mode_t {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { throw posixError("inspect mode for \(url.path)") }
    return metadata.st_mode & mode_t(0o7777)
}

private func writeProtected(_ data: Data, to url: URL) throws {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
    guard descriptor >= 0 else { throw posixError("create protected temporary file") }
    var closeNeeded = true
    defer {
        if closeNeeded { _ = close(descriptor) }
    }

    try data.withUnsafeBytes { rawBuffer in
        var offset = 0
        while offset < rawBuffer.count {
            let baseAddress = rawBuffer.baseAddress?.advanced(by: offset)
            let written = Darwin.write(descriptor, baseAddress, rawBuffer.count - offset)
            guard written > 0 else { throw posixError("write protected temporary file") }
            offset += written
        }
    }
    guard fsync(descriptor) == 0 else { throw posixError("fsync protected temporary file") }
    guard close(descriptor) == 0 else { throw posixError("close protected temporary file") }
    closeNeeded = false
}

private func syncDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
    guard descriptor >= 0 else { throw posixError("open configuration directory") }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else { throw posixError("fsync configuration directory") }
}

private func removeIfPresent(_ url: URL) throws {
    if unlink(url.path) != 0, errno != ENOENT {
        throw posixError("remove temporary configuration")
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
