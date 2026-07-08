import AgentLightProtocol

public protocol AgentEventAdapter: Sendable {
    func map(_ envelope: RelayEnvelope, sequence: UInt64) throws -> AgentEvent
}

public enum AdapterError: Error, Equatable {
    case wrongSource
    case unsupportedEvent(String)
}

func agentState(for activity: RelayActivity?) -> AgentState {
    switch activity {
    case .reading: .reading
    case .editing: .editing
    case .testing: .testing
    case .working, nil: .working
    }
}

func makeAgentEvent(from envelope: RelayEnvelope, state: AgentState, sequence: UInt64) -> AgentEvent {
    AgentEvent(
        source: envelope.source,
        sessionID: envelope.sessionID,
        workspace: envelope.workspace,
        state: state,
        sequence: sequence
    )
}
