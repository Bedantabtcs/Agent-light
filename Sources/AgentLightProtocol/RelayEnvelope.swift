import Foundation

public struct RelayEnvelope: Codable, Equatable, Sendable {
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
    case unsupportedVersion
    case invalidIntegration
    case invalidEvent
    case invalidSession
    case invalidWorkspace
    case invalidStatus
}
