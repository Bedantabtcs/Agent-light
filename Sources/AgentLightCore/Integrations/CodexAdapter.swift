import AgentLightProtocol

public struct CodexAdapter: AgentEventAdapter {
    public init() {}

    public func map(_ envelope: RelayEnvelope, sequence: UInt64) throws -> AgentEvent {
        guard envelope.source == .codex else { throw AdapterError.wrongSource }
        let states: [String: AgentState] = [
            "UserPromptSubmit": .thinking,
            "PostToolUse": .thinking,
            "PermissionRequest": .needsYou,
            "Stop": .completed
        ]
        let state = if envelope.event == "PreToolUse" {
            agentState(for: envelope.activity)
        } else {
            states[envelope.event]
        }
        guard let state else {
            throw AdapterError.unsupportedEvent(envelope.event)
        }
        return makeAgentEvent(from: envelope, state: state, sequence: sequence)
    }
}
