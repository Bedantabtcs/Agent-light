public protocol AgentLightClock: Sendable {
    func sleep(for duration: Duration) async throws
    func now() async -> Duration
}

public struct ContinuousAgentLightClock: AgentLightClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() {
        origin = clock.now
    }

    public func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }

    public func now() -> Duration {
        origin.duration(to: clock.now)
    }
}
