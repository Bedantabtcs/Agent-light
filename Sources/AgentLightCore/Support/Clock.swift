public protocol AgentLightClock: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousAgentLightClock: AgentLightClock {
    private let clock = ContinuousClock()

    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}
