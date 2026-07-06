import AgentLightProtocol

public struct CursorAdapter: AgentEventAdapter {
    public init() {}

    public func map(_ envelope: RelayEnvelope, sequence: UInt64) throws -> AgentEvent {
        guard envelope.source == .cursor else { throw AdapterError.wrongSource }
        let states: [String: AgentState] = [
            "beforeSubmitPrompt": .thinking,
            "preToolUse": .working,
            "beforeShellExecution": .working,
            "postToolUse": .thinking,
            "afterShellExecution": .thinking,
            "sessionEnd": .idle
        ]
        let state: AgentState?
        if envelope.event == "stop" {
            state = switch envelope.status {
            case "completed": .completed
            case "aborted", "error": .error
            default: nil
            }
        } else {
            state = states[envelope.event]
        }
        guard let state else { throw AdapterError.unsupportedEvent(envelope.event) }
        return makeAgentEvent(from: envelope, state: state, sequence: sequence)
    }
}
