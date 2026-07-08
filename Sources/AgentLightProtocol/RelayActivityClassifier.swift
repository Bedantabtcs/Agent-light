import Foundation

enum RelayActivityClassifier {
    static let maximumToolNameBytes = 256
    static let maximumCommandBytes = 4_096

    private static let readingTools: Set<String> = [
        "read", "grep", "glob", "webfetch", "websearch", "read_file",
        "list_directory", "search_files", "search", "find", "fetch", "get", "inspect", "view"
    ]

    private static let editingTools: Set<String> = [
        "edit", "write", "apply_patch", "notebookedit", "write_file", "edit_file"
    ]

    private static let commandTools: Set<String> = [
        "bash", "exec_command", "shell", "terminal"
    ]

    private static let validationCommandPrefixes = [
        "swift test", "swift build", "xcodebuild",
        "npm test", "npm run test", "npm run build", "npm run lint", "npm run typecheck",
        "pnpm test", "pnpm build", "pnpm lint", "pnpm typecheck",
        "yarn test", "yarn build", "yarn lint", "yarn typecheck",
        "pytest", "python -m pytest", "python3 -m pytest",
        "go test", "cargo test", "cargo build", "dotnet test",
        "make test", "./gradlew test", "gradle test", "mvn test"
    ]

    static func classify(
        source: AgentSource,
        event: String,
        object: [String: Any]?
    ) -> RelayActivity? {
        guard isToolStart(source: source, event: event) else { return nil }
        guard let object else { return .working }

        let toolName = uniqueBoundedString(
            in: object,
            paths: toolNamePaths(for: source),
            maximumBytes: maximumToolNameBytes
        )
        let command = uniqueBoundedString(
            in: object,
            paths: commandPaths(for: source),
            maximumBytes: maximumCommandBytes
        )

        if let toolName, isReadingTool(toolName) { return .reading }
        if let toolName, isEditingTool(toolName) { return .editing }
        if isCommandTool(toolName, source: source, event: event),
           let command,
           isRecognizedValidationCommand(command) {
            return .testing
        }
        return .working
    }

    private static func isToolStart(source: AgentSource, event: String) -> Bool {
        switch source {
        case .codex, .claudeCode: event == "PreToolUse"
        case .cursor: event == "preToolUse" || event == "beforeShellExecution"
        }
    }

    private static func toolNamePaths(for source: AgentSource) -> [[String]] {
        switch source {
        case .codex, .claudeCode:
            [["tool_name"]]
        case .cursor:
            [["toolName"], ["tool_name"]]
        }
    }

    private static func commandPaths(for source: AgentSource) -> [[String]] {
        switch source {
        case .codex, .claudeCode:
            [["tool_input", "command"]]
        case .cursor:
            [["command"], ["toolInput", "command"], ["tool_input", "command"]]
        }
    }

    private static func uniqueBoundedString(
        in object: [String: Any],
        paths: [[String]],
        maximumBytes: Int
    ) -> String? {
        let values = paths.compactMap { path -> String? in
            guard
                let value = value(in: object, path: path) as? String,
                !value.isEmpty,
                value.utf8.count <= maximumBytes
            else {
                return nil
            }
            return value
        }
        guard values.count == 1 else { return nil }
        return values[0]
    }

    private static func value(in object: [String: Any], path: [String]) -> Any? {
        var current: Any = object
        for component in path {
            guard let dictionary = current as? [String: Any], let next = dictionary[component] else {
                return nil
            }
            current = next
        }
        return current
    }

    private static func isReadingTool(_ toolName: String) -> Bool {
        matches(toolName: toolName, tools: readingTools)
    }

    private static func isEditingTool(_ toolName: String) -> Bool {
        matches(toolName: toolName, tools: editingTools)
    }

    private static func matches(toolName: String, tools: Set<String>) -> Bool {
        let normalized = toolName.lowercased()
        if tools.contains(normalized) { return true }
        guard normalized.contains("__"), let operation = normalized.components(separatedBy: "__").last else {
            return false
        }
        return tools.contains(operation)
    }

    private static func isCommandTool(
        _ toolName: String?,
        source: AgentSource,
        event: String
    ) -> Bool {
        if let toolName {
            return commandTools.contains(toolName.lowercased())
        }
        return source == .cursor && event == "beforeShellExecution"
    }

    private static func isRecognizedValidationCommand(_ command: String) -> Bool {
        let unsafeBytes: Set<UInt8> = [10, 13, 59, 38, 124, 60, 62, 36, 96]
        guard !command.utf8.contains(where: unsafeBytes.contains) else { return false }

        let asciiWhitespace = CharacterSet(charactersIn: " \t\u{000B}\u{000C}")
        let trimmed = command.trimmingCharacters(in: asciiWhitespace)
        return validationCommandPrefixes.contains { prefix in
            trimmed == prefix || trimmed.hasPrefix(prefix + " ")
        }
    }
}
