import AgentLightProtocol

public struct CodexAdapter: AgentEventAdapter {
    public init() {}

    public func map(_ envelope: RelayEnvelope, sequence: UInt64) throws -> AgentEvent {
        guard envelope.source == .codex else { throw AdapterError.wrongSource }
        let states: [String: AgentState] = [
            "UserPromptSubmit": .thinking,
            "PreToolUse": .working,
            "PostToolUse": .thinking,
            "PermissionRequest": .needsYou,
            "Stop": .completed
        ]
        guard let state = states[envelope.event] else {
            throw AdapterError.unsupportedEvent(envelope.event)
        }
        return makeAgentEvent(from: envelope, state: state, sequence: sequence)
    }
}
