import Foundation

public enum LightConnectionStatus: Equatable, Sendable {
    case connected
    case disconnected
}

public struct MonitoringSnapshot: Equatable, Sendable {
    public let state: AgentState
    public let sessions: [AgentEvent]
    public let connection: LightConnectionStatus

    public init(
        state: AgentState,
        sessions: [AgentEvent],
        connection: LightConnectionStatus
    ) {
        self.state = state
        self.sessions = sessions
        self.connection = connection
    }
}

public protocol MonitoringOrchestrating: Sendable {
    func start() async throws
    func accept(_ event: AgentEvent) async
    func pause() async
    func resume() async throws
    func stop() async
    func recoverIfNeeded() async throws
    func updates() async -> AsyncStream<MonitoringSnapshot>
}

public actor MonitoringOrchestrator: MonitoringOrchestrating {
    public typealias Jitter = @Sendable (Duration) -> Duration
    public typealias TransientErrorClassifier = @Sendable (any Error) -> Bool

    private enum Mode: Sendable {
        case inactive
        case starting
        case active
        case paused
        case stopped
    }

    private struct OwnershipResult: Sendable {
        let baseline: BulbBaseline
        let record: MonitoringRecoveryRecord
    }

    private enum RecoveryOutcome: Sendable {
        case none
        case restored
        case adopted(BulbBaseline)
    }

    private enum SendOutcome: Sendable {
        case applied(DesiredLightState)
        case superseded
        case failed
    }

    private struct TerminalTimer: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let light: any TuyaLightControlling
    private let recoveryStore: any MonitoringRecoveryStoring
    private let coordinator: SessionCoordinator
    private let clock: any AgentLightClock
    private let jitter: Jitter
    private let isTransient: TransientErrorClassifier

    private var mode: Mode = .inactive
    private var generation: UInt64 = 0
    private var nextSequence: UInt64 = 0
    private var ownershipTask: Task<OwnershipResult, Error>?
    private var ownershipTaskID: UUID?
    private var recoveryTask: Task<RecoveryOutcome, Error>?
    private var recoveryTaskID: UUID?
    private var restoreTask: Task<Void, Error>?
    private var restoreTaskID: UUID?
    private var baseline: BulbBaseline?
    private var recoveryRecord: MonitoringRecoveryRecord?
    private var adoptedBaseline: BulbBaseline?
    private var throttleTask: Task<Void, Never>?
    private var throttleID: UUID?
    private var terminalTasks: [String: TerminalTimer] = [:]
    private var lastApplied: DesiredLightState?
    private var connection: LightConnectionStatus = .connected
    private var snapshot = MonitoringSnapshot(state: .idle, sessions: [], connection: .connected)
    private var subscribers: [UUID: AsyncStream<MonitoringSnapshot>.Continuation] = [:]

    public init(
        light: any TuyaLightControlling,
        recoveryStore: any MonitoringRecoveryStoring,
        coordinator: SessionCoordinator = SessionCoordinator(),
        clock: any AgentLightClock = ContinuousAgentLightClock(),
        jitter: @escaping Jitter = { _ in .zero },
        isTransient: @escaping TransientErrorClassifier = MonitoringOrchestrator.defaultTransientClassifier
    ) {
        self.light = light
        self.recoveryStore = recoveryStore
        self.coordinator = coordinator
        self.clock = clock
        self.jitter = jitter
        self.isTransient = isTransient
    }

    deinit {
        ownershipTask?.cancel()
        recoveryTask?.cancel()
        restoreTask?.cancel()
        throttleTask?.cancel()
        for timer in terminalTasks.values {
            timer.task.cancel()
        }
        for continuation in subscribers.values {
            continuation.finish()
        }
    }

    public func start() async throws {
        if mode == .active { return }
        if restoreTask != nil {
            await restoreCurrentOwnership()
        }
        if baseline != nil, recoveryRecord != nil {
            generation &+= 1
            mode = .active
            connection = .connected
            await refreshSnapshot()
            scheduleThrottleIfNeeded()
            return
        }
        if let recoveryTask {
            _ = try await resolveRecovery(recoveryTask, id: recoveryTaskID)
            try await start()
            return
        }
        if let ownershipTask {
            let token = generation
            try await resolveStart(ownershipTask, id: ownershipTaskID, token: token)
            return
        }

        generation &+= 1
        let token = generation
        mode = .starting
        let id = UUID()
        let seedBaseline = adoptedBaseline
        adoptedBaseline = nil
        let light = self.light
        let recoveryStore = self.recoveryStore
        let task = Task<OwnershipResult, Error> {
            let captured: BulbBaseline
            if let seedBaseline {
                captured = seedBaseline
            } else {
                captured = try await light.captureBaseline()
            }
            let record = MonitoringRecoveryRecord(baseline: captured)
            try await recoveryStore.save(record)
            return OwnershipResult(baseline: captured, record: record)
        }
        ownershipTask = task
        ownershipTaskID = id
        try await resolveStart(task, id: id, token: token)
    }

    public func resume() async throws {
        try await start()
    }

    public func accept(_ event: AgentEvent) async {
        guard mode == .active else { return }
        let token = generation
        nextSequence &+= 1
        let accepted = AgentEvent(
            source: event.source,
            sessionID: event.sessionID,
            workspace: event.workspace,
            state: event.state,
            sequence: nextSequence
        )
        terminalTasks[event.sessionID]?.task.cancel()
        terminalTasks[event.sessionID] = nil
        await coordinator.accept(accepted)
        guard mode == .active, generation == token else { return }

        if let hold = terminalHold(for: accepted.state) {
            scheduleTerminalExpiry(for: accepted, after: hold, generation: token)
        }
        await refreshSnapshot()
        if accepted.state == .idle, await coordinator.currentWinner() == nil {
            await cancelThrottleAndWait()
            if await coordinator.currentWinner() == nil {
                await restoreCurrentOwnership()
            } else {
                scheduleThrottleIfNeeded()
            }
        } else {
            scheduleThrottleIfNeeded()
        }
    }

    public func pause() async {
        await deactivate(to: .paused)
    }

    public func stop() async {
        await deactivate(to: .stopped)
    }

    public func reconnect() async {
        guard mode == .active else { return }
        connection = .connected
        await refreshSnapshot()
        scheduleThrottleIfNeeded()
    }

    public func recoverIfNeeded() async throws {
        guard mode == .inactive else { return }
        if let recoveryTask {
            _ = try await resolveRecovery(recoveryTask, id: recoveryTaskID)
            return
        }

        let id = UUID()
        let light = self.light
        let recoveryStore = self.recoveryStore
        let clock = self.clock
        let jitter = self.jitter
        let classifier = self.isTransient
        let task = Task<RecoveryOutcome, Error> {
            guard let record = try await recoveryStore.load() else {
                return .none
            }
            let commands = [record.lastCommand, record.pendingCommand].compactMap { $0 }
            if commands.isEmpty {
                try await recoveryStore.clear()
                return .adopted(record.baseline)
            }
            for command in commands {
                if try await light.currentStateMatches(command) {
                    try await Self.retry(
                        clock: clock,
                        jitter: jitter,
                        isTransient: classifier
                    ) {
                        try await light.restore(record.baseline)
                    }
                    try await recoveryStore.clear()
                    return .restored
                }
            }

            let external = try await light.captureBaseline()
            // Replacement is durable before old ownership is cleared. A crash at this
            // point leaves an unowned baseline record that the next recovery adopts.
            try await recoveryStore.save(MonitoringRecoveryRecord(baseline: external))
            try await recoveryStore.clear()
            return .adopted(external)
        }
        recoveryTask = task
        recoveryTaskID = id
        _ = try await resolveRecovery(task, id: id)
    }

    public func updates() -> AsyncStream<MonitoringSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    public func currentSnapshot() -> MonitoringSnapshot {
        snapshot
    }

    private func resolveStart(
        _ task: Task<OwnershipResult, Error>,
        id: UUID?,
        token: UInt64
    ) async throws {
        do {
            let result = try await task.value
            if ownershipTaskID == id {
                ownershipTask = nil
                ownershipTaskID = nil
            }
            if generation == token, mode == .active, baseline != nil {
                return
            }
            guard generation == token, mode == .starting else {
                throw CancellationError()
            }
            baseline = result.baseline
            recoveryRecord = result.record
            mode = .active
            connection = .connected
            await refreshSnapshot()
        } catch {
            if ownershipTaskID == id {
                ownershipTask = nil
                ownershipTaskID = nil
            }
            if generation == token, mode == .starting {
                mode = .inactive
            }
            throw error
        }
    }

    private func resolveRecovery(
        _ task: Task<RecoveryOutcome, Error>,
        id: UUID?
    ) async throws -> RecoveryOutcome {
        do {
            let outcome = try await task.value
            if recoveryTaskID == id {
                recoveryTask = nil
                recoveryTaskID = nil
                if case let .adopted(external) = outcome {
                    adoptedBaseline = external
                }
                connection = .connected
                await refreshSnapshot()
            }
            return outcome
        } catch {
            if recoveryTaskID == id {
                recoveryTask = nil
                recoveryTaskID = nil
                connection = .disconnected
                await refreshSnapshot()
            }
            throw error
        }
    }

    private func deactivate(to target: Mode) async {
        if mode == target, restoreTask == nil, baseline == nil, ownershipTask == nil {
            return
        }
        generation &+= 1
        mode = target
        await cancelThrottleAndWait()
        cancelTerminalTasks()
        await coordinator.reset()
        await refreshSnapshot()

        if let task = ownershipTask {
            do {
                let result = try await task.value
                baseline = result.baseline
                recoveryRecord = result.record
            } catch {
                ownershipTask = nil
                ownershipTaskID = nil
                return
            }
            ownershipTask = nil
            ownershipTaskID = nil
        }
        await restoreCurrentOwnership()
    }

    private func scheduleThrottleIfNeeded() {
        guard mode == .active,
              connection == .connected,
              throttleTask == nil else { return }
        let id = UUID()
        let token = generation
        throttleID = id
        throttleTask = Task { [clock, weak self] in
            do {
                try await clock.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.fireThrottle(id: id, generation: token)
        }
    }

    private func fireThrottle(id: UUID, generation token: UInt64) async {
        guard throttleID == id,
              generation == token,
              mode == .active,
              connection == .connected else { return }
        let winner = await coordinator.currentWinner()
        guard let winner, let color = winner.state.color else {
            finishThrottle(id: id)
            await restoreCurrentOwnership()
            return
        }
        let desired = DesiredLightState(color: color)
        if desired == lastApplied {
            finishThrottle(id: id)
            return
        }

        let outcome = await apply(
            desired,
            winnerSequence: winner.sequence,
            generation: token
        )
        finishThrottle(id: id)
        switch outcome {
        case let .applied(state):
            lastApplied = state
            connection = .connected
        case .superseded:
            break
        case .failed:
            connection = .disconnected
        }
        await refreshSnapshot()
        if case .failed = outcome {
            return
        } else {
            let current = await coordinator.currentWinner()
            if current?.sequence != winner.sequence {
                scheduleThrottleIfNeeded()
            }
        }
    }

    private func apply(
        _ desired: DesiredLightState,
        winnerSequence: UInt64,
        generation token: UInt64
    ) async -> SendOutcome {
        do {
            try await ensureOwnership(generation: token)
            guard try await isCurrent(
                desired,
                winnerSequence: winnerSequence,
                generation: token
            ) else { return .superseded }
            guard let currentRecord = recoveryRecord else { return .failed }

            // Commit point 1: persist pending before touching the bulb. Recovery
            // recognizes both last-known-applied and pending commands.
            let pending = MonitoringRecoveryRecord(
                baseline: currentRecord.baseline,
                lastCommand: currentRecord.lastCommand,
                pendingCommand: desired
            )
            try await recoveryStore.save(pending)
            recoveryRecord = pending
            guard try await isCurrent(
                desired,
                winnerSequence: winnerSequence,
                generation: token
            ) else { return .superseded }

            let delays: [Duration] = [.milliseconds(500), .seconds(1)]
            for attempt in 0...delays.count {
                guard try await isCurrent(
                    desired,
                    winnerSequence: winnerSequence,
                    generation: token
                ) else { return .superseded }
                do {
                    try await light.apply(desired)
                    // Commit point 2: only after apply succeeds does lastCommand
                    // advance and pending clear. A failed save leaves pending intact.
                    let committed = MonitoringRecoveryRecord(
                        baseline: pending.baseline,
                        lastCommand: desired
                    )
                    try await recoveryStore.save(committed)
                    recoveryRecord = committed
                    return .applied(desired)
                } catch {
                    guard attempt < delays.count, isTransient(error) else {
                        return .failed
                    }
                    let delay = delays[attempt] + boundedJitter(for: delays[attempt])
                    do {
                        try await clock.sleep(for: delay)
                    } catch {
                        return .superseded
                    }
                }
            }
            return .failed
        } catch {
            return .failed
        }
    }

    private func ensureOwnership(generation token: UInt64) async throws {
        if baseline != nil, recoveryRecord != nil { return }
        guard generation == token, mode == .active else {
            throw CancellationError()
        }
        let captured = try await light.captureBaseline()
        guard generation == token, mode == .active else {
            throw CancellationError()
        }
        let record = MonitoringRecoveryRecord(baseline: captured)
        try await recoveryStore.save(record)
        guard generation == token, mode == .active else {
            throw CancellationError()
        }
        baseline = captured
        recoveryRecord = record
    }

    private func isCurrent(
        _ desired: DesiredLightState,
        winnerSequence: UInt64,
        generation token: UInt64
    ) async throws -> Bool {
        guard !Task.isCancelled,
              generation == token,
              mode == .active,
              let winner = await coordinator.currentWinner(),
              winner.sequence == winnerSequence,
              winner.state.color == desired.color else {
            return false
        }
        return true
    }

    private func restoreCurrentOwnership() async {
        if let task = restoreTask, let id = restoreTaskID {
            await resolveRestore(task, id: id)
            return
        }
        guard let baseline else { return }
        let id = UUID()
        let light = self.light
        let store = recoveryStore
        let clock = self.clock
        let jitter = self.jitter
        let classifier = self.isTransient
        let task = Task<Void, Error> {
            try await Self.retry(
                clock: clock,
                jitter: jitter,
                isTransient: classifier
            ) {
                try await light.restore(baseline)
            }
            try await store.clear()
        }
        restoreTask = task
        restoreTaskID = id
        await resolveRestore(task, id: id)
    }

    private func resolveRestore(_ task: Task<Void, Error>, id: UUID) async {
        do {
            try await task.value
            if restoreTaskID == id {
                restoreTask = nil
                restoreTaskID = nil
                self.baseline = nil
                recoveryRecord = nil
                lastApplied = nil
                connection = .connected
                await refreshSnapshot()
            }
        } catch {
            if restoreTaskID == id {
                restoreTask = nil
                restoreTaskID = nil
                connection = .disconnected
                await refreshSnapshot()
            }
        }
    }

    private static func retry(
        clock: any AgentLightClock,
        jitter: Jitter,
        isTransient: TransientErrorClassifier,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let delays: [Duration] = [.milliseconds(500), .seconds(1)]
        for attempt in 0...delays.count {
            do {
                try await operation()
                return
            } catch {
                guard attempt < delays.count, isTransient(error) else { throw error }
                let raw = jitter(delays[attempt])
                let bounded = min(max(raw, .zero), .milliseconds(250))
                try await clock.sleep(for: delays[attempt] + bounded)
            }
        }
    }

    private func boundedJitter(for base: Duration) -> Duration {
        min(max(jitter(base), .zero), .milliseconds(250))
    }

    private func scheduleTerminalExpiry(
        for event: AgentEvent,
        after hold: Duration,
        generation token: UInt64
    ) {
        let sessionID = event.sessionID
        let id = UUID()
        let task = Task { [clock, weak self] in
            do {
                try await clock.sleep(for: hold)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.expireTerminal(
                sessionID: sessionID,
                sequence: event.sequence,
                timerID: id,
                generation: token
            )
        }
        terminalTasks[sessionID] = TerminalTimer(id: id, task: task)
    }

    private func expireTerminal(
        sessionID: String,
        sequence: UInt64,
        timerID: UUID,
        generation token: UInt64
    ) async {
        guard mode == .active, generation == token else { return }
        if terminalTasks[sessionID]?.id == timerID {
            terminalTasks[sessionID] = nil
        }
        await coordinator.expireTerminalState(sessionID: sessionID, sequence: sequence)
        await refreshSnapshot()
        if await coordinator.currentWinner() == nil {
            await cancelThrottleAndWait()
            if await coordinator.currentWinner() == nil {
                await restoreCurrentOwnership()
            } else {
                scheduleThrottleIfNeeded()
            }
        } else {
            scheduleThrottleIfNeeded()
        }
    }

    private func terminalHold(for state: AgentState) -> Duration? {
        switch state {
        case .completed: .seconds(8)
        case .error: .seconds(12)
        default: nil
        }
    }

    private func refreshSnapshot() async {
        let sessions = await coordinator.snapshots()
        snapshot = MonitoringSnapshot(
            state: sessions.first?.state ?? .idle,
            sessions: sessions,
            connection: connection
        )
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
    }

    private func finishThrottle(id: UUID) {
        guard throttleID == id else { return }
        throttleTask = nil
        throttleID = nil
    }

    private func cancelThrottleAndWait() async {
        let task = throttleTask
        task?.cancel()
        throttleID = nil
        await task?.value
        throttleTask = nil
    }

    private func cancelTerminalTasks() {
        for timer in terminalTasks.values {
            timer.task.cancel()
        }
        terminalTasks.removeAll()
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    public nonisolated static func defaultTransientClassifier(_ error: any Error) -> Bool {
        guard let error = error as? TuyaClientError else { return false }
        switch error {
        case .transport, .apiFailure:
            return true
        case let .httpStatus(status):
            return status == 408 || status == 429 || (500...599).contains(status)
        case .invalidEndpoint, .malformedResponse, .authenticationFailure:
            return false
        }
    }
}
