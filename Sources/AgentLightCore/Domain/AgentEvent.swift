import AgentLightProtocol

public struct AgentEvent: Equatable, Sendable {
    public let source: AgentSource
    public let sessionID: String
    public let workspace: String?
    public let state: AgentState
    public let sequence: UInt64

    public init(source: AgentSource, sessionID: String, workspace: String?, state: AgentState, sequence: UInt64) {
        self.source = source
        self.sessionID = sessionID
        self.workspace = workspace
        self.state = state
        self.sequence = sequence
    }
}
