import AgentLightProtocol

public struct ClaudeCodeAdapter: AgentEventAdapter {
    public init() {}

    public func map(_ envelope: RelayEnvelope, sequence: UInt64) throws -> AgentEvent {
        guard envelope.source == .claudeCode else { throw AdapterError.wrongSource }
        let states: [String: AgentState] = [
            "UserPromptSubmit": .thinking,
            "PreToolUse": .working,
            "PostToolUse": .thinking,
            "PermissionRequest": .needsYou,
            "Stop": .completed,
            "StopFailure": .error,
            "SessionEnd": .idle
        ]
        let state: AgentState?
        if envelope.event == "Notification" {
            state = switch envelope.status {
            case "agent_needs_input": .needsYou
            case "agent_completed": .completed
            default: nil
            }
        } else {
            state = states[envelope.event]
        }
        guard let state else { throw AdapterError.unsupportedEvent(envelope.event) }
        return makeAgentEvent(from: envelope, state: state, sequence: sequence)
    }
}
