import AgentLightProtocol

protocol SessionCoordinating: Sendable {
    func accept(_ event: AgentEvent) async
    func expireTerminalState(sessionID: String, sequence: UInt64) async
    func currentWinner() async -> AgentEvent?
    func snapshots() async -> [AgentEvent]
    func reset() async
}

public actor SessionCoordinator {
    private var sessions: [String: AgentEvent] = [:]

    public init() {}

    public func accept(_ event: AgentEvent) {
        guard event.sequence >= (sessions[event.sessionID]?.sequence ?? 0) else {
            return
        }

        if event.state == .idle {
            sessions.removeValue(forKey: event.sessionID)
        } else {
            sessions[event.sessionID] = event
        }
    }

    public func expireTerminalState(sessionID: String, sequence: UInt64) {
        guard let event = sessions[sessionID], event.sequence == sequence else {
            return
        }
        guard event.state == .completed || event.state == .error else {
            return
        }

        sessions.removeValue(forKey: sessionID)
    }

    public func currentWinner() -> AgentEvent? {
        sessions.values.max(by: isOrderedBefore)
    }

    public func snapshots() -> [AgentEvent] {
        sessions.values.sorted { left, right in
            isOrderedBefore(right, left)
        }
    }

    public func reset() {
        sessions.removeAll()
    }

    private func isOrderedBefore(_ left: AgentEvent, _ right: AgentEvent) -> Bool {
        if left.sequence != right.sequence {
            return left.sequence < right.sequence
        }
        if left.sessionID != right.sessionID {
            return left.sessionID < right.sessionID
        }
        return left.source.rawValue < right.source.rawValue
    }
}

extension SessionCoordinator: SessionCoordinating {}
