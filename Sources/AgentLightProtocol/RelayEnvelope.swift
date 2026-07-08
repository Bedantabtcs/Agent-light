import Foundation

public struct RelayEnvelope: Codable, Equatable, Sendable {
    public static let maximumEncodedBytes = 2_048

    public let version: Int
    public let integrationID: String
    public let source: AgentSource
    public let event: String
    public let sessionID: String
    public let workspace: String?
    public let status: String?
    public let emittedAtMilliseconds: Int64

    public init(
        version: Int,
        integrationID: String,
        source: AgentSource,
        event: String,
        sessionID: String,
        workspace: String?,
        status: String?,
        emittedAtMilliseconds: Int64
    ) {
        self.version = version
        self.integrationID = integrationID
        self.source = source
        self.event = event
        self.sessionID = sessionID
        self.workspace = workspace
        self.status = status
        self.emittedAtMilliseconds = emittedAtMilliseconds
    }

    public static func decodeValidated(from data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else {
            throw RelayValidationError.payloadTooLarge
        }
        do {
            return try JSONDecoder().decode(Self.self, from: data).validated()
        } catch let error as RelayValidationError {
            throw error
        } catch let error as DecodingError where isSourceDecodingError(error) {
            throw RelayValidationError.invalidSource
        } catch {
            throw RelayValidationError.invalidPayload
        }
    }

    private static func isSourceDecodingError(_ error: DecodingError) -> Bool {
        let codingPath: [any CodingKey]
        switch error {
        case let .dataCorrupted(context),
             let .typeMismatch(_, context),
             let .valueNotFound(_, context):
            codingPath = context.codingPath
        case let .keyNotFound(key, context):
            if key.stringValue == "source" { return true }
            codingPath = context.codingPath
        @unknown default:
            return false
        }
        return codingPath.contains { $0.stringValue == "source" }
    }

    public func validated() throws -> Self {
        guard version == 1 else { throw RelayValidationError.unsupportedVersion }
        guard integrationID == AppIdentity.integrationIdentifier else { throw RelayValidationError.invalidIntegration }
        guard !event.isEmpty, event.utf8.count <= 128 else { throw RelayValidationError.invalidEvent }
        guard !sessionID.isEmpty, sessionID.utf8.count <= 256 else { throw RelayValidationError.invalidSession }
        guard workspace?.utf8.count ?? 0 <= 512 else { throw RelayValidationError.invalidWorkspace }
        guard status?.utf8.count ?? 0 <= 64 else { throw RelayValidationError.invalidStatus }
        return self
    }
}

public enum RelayValidationError: Error, Equatable {
    case payloadTooLarge
    case invalidPayload
    case unsupportedVersion
    case invalidIntegration
    case invalidSource
    case invalidEvent
    case invalidSession
    case invalidWorkspace
    case invalidStatus
}
