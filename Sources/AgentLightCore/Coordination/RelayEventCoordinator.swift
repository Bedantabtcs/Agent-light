import AgentLightProtocol
import Foundation

public actor RelayEventCoordinator {
    private let monitor: any MonitoringOrchestrating
    private var sequence: UInt64 = 0

    public init(monitor: any MonitoringOrchestrating) {
        self.monitor = monitor
    }

    public func accept(_ data: Data) async {
        guard let envelope = try? RelayEnvelope.decodeValidated(from: data) else { return }
        let next = sequence &+ 1
        guard let event = try? adapter(for: envelope.source).map(envelope, sequence: next) else { return }
        sequence = next
        await monitor.accept(event)
    }

    private func adapter(for source: AgentSource) -> any AgentEventAdapter {
        switch source {
        case .codex: CodexAdapter()
        case .claudeCode: ClaudeCodeAdapter()
        case .cursor: CursorAdapter()
        }
    }
}
