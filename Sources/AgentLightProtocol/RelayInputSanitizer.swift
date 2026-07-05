import Foundation

public enum RelayInputSanitizer {
    public static let maximumInputBytes = 1_048_576

    public static func makeEnvelope(
        arguments: [String],
        input: Data,
        nowMilliseconds: Int64
    ) throws -> RelayEnvelope {
        guard input.count <= maximumInputBytes else {
            throw RelayInputError.inputTooLarge
        }

        let options = try RelayArguments(arguments: arguments)
        let object = try JSONSerialization.jsonObject(with: input) as? [String: Any]
        let session = string(
            in: object,
            keys: ["session_id", "conversation_id", "thread_id"]
        ) ?? options.sessionID
        guard let session else {
            throw RelayInputError.missingSession
        }

        let workspace = string(in: object, keys: ["cwd", "workspace_root", "workspace"])
            .map { URL(fileURLWithPath: $0).lastPathComponent }
        let status = string(in: object, keys: ["status", "reason", "notification_type"])

        return try RelayEnvelope(
            version: 1,
            integrationID: AppIdentity.integrationIdentifier,
            source: options.source,
            event: options.event,
            sessionID: session,
            workspace: workspace,
            status: status,
            emittedAtMilliseconds: nowMilliseconds
        ).validated()
    }

    private static func string(in object: [String: Any]?, keys: [String]) -> String? {
        for key in keys {
            if let value = object?[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

struct RelayArguments {
    let source: AgentSource
    let event: String
    let sessionID: String?

    init(arguments: [String]) throws {
        func value(after flag: String) -> String? {
            guard
                let index = arguments.firstIndex(of: flag),
                arguments.indices.contains(index + 1)
            else {
                return nil
            }
            return arguments[index + 1]
        }

        guard
            value(after: "--integration-id") == AppIdentity.integrationIdentifier,
            let rawSource = value(after: "--source"),
            let source = AgentSource(rawValue: rawSource),
            let event = value(after: "--event"),
            !event.isEmpty
        else {
            throw RelayInputError.invalidArguments
        }

        self.source = source
        self.event = event
        sessionID = value(after: "--session-id")
    }
}

enum RelayInputError: Error, Equatable {
    case inputTooLarge
    case missingSession
    case invalidArguments
}
