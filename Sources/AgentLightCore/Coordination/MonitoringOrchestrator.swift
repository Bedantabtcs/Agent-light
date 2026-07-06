import Foundation

public enum LightConnectionStatus: Equatable, Sendable {
    case connected
    case disconnected
}

public struct MonitoringSnapshot: Equatable, Sendable {
    public let state: AgentState
    public let sessions: [AgentEvent]
    public let connection: LightConnectionStatus

    public init(state: AgentState, sessions: [AgentEvent], connection: LightConnectionStatus) {
        self.state = state
        self.sessions = sessions
        self.connection = connection
    }
}

public enum MonitoringOrchestratorError: Error, Equatable, Sendable {
    case operationFailed
}

public protocol MonitoringOrchestrating: Sendable {
    func start() async throws
    func accept(_ event: AgentEvent) async
    func pause() async
    func resume() async throws
    func stop() async
    func reconnect() async
    func recoverIfNeeded() async throws
    func updates() async -> AsyncStream<MonitoringSnapshot>
    func currentSnapshot() async -> MonitoringSnapshot
}

private final class MonitoringSubscriberRegistry: @unchecked Sendable {
    typealias Continuation = AsyncStream<MonitoringSnapshot>.Continuation

    private let lock = NSLock()
    private var continuations: [UUID: Continuation] = [:]

    func insert(_ continuation: Continuation, id: UUID) {
        lock.lock()
        continuations[id] = continuation
        lock.unlock()
    }

    func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }

    func yield(_ snapshot: MonitoringSnapshot) {
        lock.lock()
        let current = Array(continuations.values)
        lock.unlock()
        for continuation in current {
            continuation.yield(snapshot)
        }
    }

    func finishAll() {
        lock.lock()
        let current = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in current {
            continuation.finish()
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }
}

public actor MonitoringOrchestrator: MonitoringOrchestrating {
    public typealias Jitter = @Sendable (Duration) -> Duration
    public typealias TransientErrorClassifier = @Sendable (any Error) -> Bool

    private enum Mode: Equatable, Sendable {
        case inactive
        case starting
        case active
        case paused
        case stopped
    }

    private enum LifecycleOperation: Equatable, Sendable {
        case activate
        case pause
        case stop
        case recover
    }

    private enum TransitionResult: Sendable {
        case success
        case failure
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
    private let coordinator: any SessionCoordinating
    private let clock: any AgentLightClock
    private let jitter: Jitter
    private let isTransient: TransientErrorClassifier
    private let subscribers = MonitoringSubscriberRegistry()

    private var mode: Mode = .inactive
    private var generation: UInt64 = 0
    private var lifecycleRequest: UInt64 = 0
    private var lifecycleTail: Task<Void, Never>?
    private var lifecycleTailID: UUID?
    private var currentTransitionKind: LifecycleOperation?
    private var currentTransitionTask: Task<TransitionResult, Never>?
    private var currentTransitionID: UUID?
    private var nextSequence: UInt64 = 0
    private var latestSessionSequence: [String: UInt64] = [:]
    private var baseline: BulbBaseline?
    private var recoveryRecord: MonitoringRecoveryRecord?
    private var adoptedBaseline: BulbBaseline?
    private var clearPending = false
    private var restoreTask: Task<Void, Error>?
    private var restoreTaskID: UUID?
    private var throttleTask: Task<Void, Never>?
    private var throttleID: UUID?
    private var terminalTasks: [String: TerminalTimer] = [:]
    private var lastApplied: DesiredLightState?
    private var connection: LightConnectionStatus = .connected
    private var snapshot = MonitoringSnapshot(state: .idle, sessions: [], connection: .connected)

    public init(
        light: any TuyaLightControlling,
        recoveryStore: any MonitoringRecoveryStoring,
        coordinator: any SessionCoordinating = SessionCoordinator(),
        clock: any AgentLightClock = ContinuousAgentLightClock(),
        jitter: @escaping Jitter = {
            MonitoringOrchestrator.productionJitter(
                for: $0,
                sample: Double.random(in: 0...1)
            )
        },
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
        lifecycleTail?.cancel()
        currentTransitionTask?.cancel()
        restoreTask?.cancel()
        throttleTask?.cancel()
        for timer in terminalTasks.values {
            timer.task.cancel()
        }
        subscribers.finishAll()
    }

    public func start() async throws {
        if mode == .active, lifecycleTail == nil { return }
        try await enqueueLifecycle(.activate)
    }

    public func resume() async throws {
        try await start()
    }

    public func pause() async {
        try? await enqueueLifecycle(.pause)
    }

    public func stop() async {
        try? await enqueueLifecycle(.stop)
    }

    public func recoverIfNeeded() async throws {
        guard mode == .inactive else { return }
        try await enqueueLifecycle(.recover)
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
        latestSessionSequence[accepted.sessionID] = accepted.sequence
        terminalTasks[accepted.sessionID]?.task.cancel()
        terminalTasks[accepted.sessionID] = nil

        await coordinator.accept(accepted)
        guard mode == .active,
              generation == token,
              latestSessionSequence[accepted.sessionID] == accepted.sequence else {
            return
        }

        if let hold = terminalHold(for: accepted.state) {
            scheduleTerminalExpiry(for: accepted, after: hold, generation: token)
        }
        await refreshSnapshot()
        guard mode == .active, generation == token else { return }

        if accepted.state == .idle, await coordinator.currentWinner() == nil {
            await cancelThrottleAndWait()
            guard mode == .active, generation == token else { return }
            if await coordinator.currentWinner() == nil {
                _ = await restoreCurrentOwnership()
            } else {
                scheduleThrottleIfNeeded()
            }
        } else {
            scheduleThrottleIfNeeded()
        }
    }

    public func reconnect() async {
        guard mode == .active, connection == .disconnected else { return }
        let token = generation
        if clearPending {
            guard await retryPendingClear(), generation == token, mode == .active else { return }
        }

        do {
            if let lastApplied {
                let matches = try await retryValue {
                    try await self.light.currentStateMatches(lastApplied)
                }
                guard generation == token, mode == .active else { return }
                if matches {
                    connection = .connected
                    await refreshSnapshot()
                    scheduleThrottleIfNeeded()
                    return
                }
            } else {
                _ = try await retryValue { try await self.light.captureBaseline() }
                guard generation == token, mode == .active else { return }
                connection = .connected
                await refreshSnapshot()
                scheduleThrottleIfNeeded()
                return
            }

            guard let winner = await coordinator.currentWinner(),
                  let color = winner.state.color,
                  generation == token,
                  mode == .active else {
                return
            }
            let outcome = await apply(
                DesiredLightState(color: color),
                winnerSequence: winner.sequence,
                generation: token
            )
            if case .applied = outcome {
                connection = .connected
            }
            await refreshSnapshot()
        } catch {
            guard generation == token, mode == .active else { return }
            connection = .disconnected
            await refreshSnapshot()
        }
    }

    public func updates() -> AsyncStream<MonitoringSnapshot> {
        let id = UUID()
        let registry = subscribers
        let current = snapshot
        return AsyncStream { continuation in
            registry.insert(continuation, id: id)
            continuation.yield(current)
            continuation.onTermination = { _ in
                registry.remove(id)
            }
        }
    }

    public func currentSnapshot() -> MonitoringSnapshot {
        snapshot
    }

    func subscriberCount() -> Int {
        subscribers.count
    }

    func lifecycleRequestNumber() -> UInt64 {
        lifecycleRequest
    }

    public nonisolated static func productionJitter(for base: Duration, sample: Double) -> Duration {
        _ = base
        let bounded = min(max(sample, 0), 1)
        let milliseconds = 1 + Int((bounded * 249).rounded(.down))
        return .milliseconds(milliseconds)
    }

    public nonisolated static func defaultTransientClassifier(_ error: any Error) -> Bool {
        if let error = error as? URLError {
            return [
                .timedOut,
                .cannotFindHost,
                .cannotConnectToHost,
                .dnsLookupFailed,
                .networkConnectionLost,
                .notConnectedToInternet
            ].contains(error.code)
        }
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

    private func enqueueLifecycle(_ operation: LifecycleOperation) async throws {
        if operation == .activate,
           currentTransitionKind == .activate,
           let currentTransitionTask {
            try await resolveTransition(currentTransitionTask)
            return
        }

        lifecycleRequest &+= 1
        generation &+= 1
        let request = lifecycleRequest
        let predecessor = lifecycleTail
        let id = UUID()
        switch operation {
        case .activate:
            mode = .starting
        case .pause:
            mode = .paused
        case .stop:
            mode = .stopped
        case .recover:
            mode = .inactive
        }

        let resultTask = Task<TransitionResult, Never> { [weak self] in
            await predecessor?.value
            guard let self else { return .failure }
            return await self.performLifecycle(operation, request: request)
        }
        let tail = Task<Void, Never> {
            _ = await resultTask.value
        }
        lifecycleTail = tail
        lifecycleTailID = id
        currentTransitionKind = operation
        currentTransitionTask = resultTask
        currentTransitionID = id

        let result = await resultTask.value
        if currentTransitionID == id {
            currentTransitionKind = nil
            currentTransitionTask = nil
            currentTransitionID = nil
        }
        if lifecycleTailID == id {
            lifecycleTail = nil
            lifecycleTailID = nil
        }
        try resolveTransitionResult(result)
    }

    private func resolveTransition(_ task: Task<TransitionResult, Never>) async throws {
        try resolveTransitionResult(await task.value)
    }

    private func resolveTransitionResult(_ result: TransitionResult) throws {
        if case .failure = result {
            throw MonitoringOrchestratorError.operationFailed
        }
    }

    private func performLifecycle(
        _ operation: LifecycleOperation,
        request: UInt64
    ) async -> TransitionResult {
        do {
            switch operation {
            case .activate:
                try await performActivate(request: request)
            case .pause:
                await performDeactivate(target: .paused, request: request)
            case .stop:
                await performDeactivate(target: .stopped, request: request)
            case .recover:
                try await performRecovery(request: request)
            }
            return .success
        } catch {
            if lifecycleRequest == request, operation == .activate {
                mode = .inactive
            }
            return .failure
        }
    }

    private func performActivate(request: UInt64) async throws {
        if restoreTask != nil || clearPending {
            guard await restoreCurrentOwnership(), lifecycleRequest == request else {
                throw CancellationError()
            }
        }
        guard lifecycleRequest == request else { throw CancellationError() }

        if baseline != nil, recoveryRecord != nil {
            mode = .active
            await refreshSnapshot()
            guard lifecycleRequest == request else { throw CancellationError() }
            scheduleThrottleIfNeeded()
            return
        }

        let captured: BulbBaseline
        if let adoptedBaseline {
            captured = adoptedBaseline
            self.adoptedBaseline = nil
        } else {
            captured = try await retryValue { try await self.light.captureBaseline() }
        }
        guard lifecycleRequest == request else { throw CancellationError() }
        let record = MonitoringRecoveryRecord(baseline: captured)
        try await recoveryStore.save(record)
        guard lifecycleRequest == request else {
            recoveryRecord = record
            clearPending = true
            throw CancellationError()
        }
        baseline = captured
        recoveryRecord = record
        connection = .connected
        mode = .active
        await refreshSnapshot()
    }

    private func performDeactivate(target: Mode, request: UInt64) async {
        await cancelThrottleAndWait()
        guard lifecycleRequest == request else { return }
        cancelTerminalTasks()
        await coordinator.reset()
        guard lifecycleRequest == request else { return }
        latestSessionSequence.removeAll()
        await refreshSnapshot()
        guard lifecycleRequest == request else { return }
        _ = await restoreCurrentOwnership()
        guard lifecycleRequest == request else { return }
        mode = target
    }

    private func performRecovery(request: UInt64) async throws {
        if clearPending {
            guard await retryPendingClear(), lifecycleRequest == request else {
                throw CancellationError()
            }
            return
        }
        guard let record = try await recoveryStore.load() else { return }
        guard lifecycleRequest == request else { throw CancellationError() }
        let commands = [record.lastCommand, record.pendingCommand].compactMap { $0 }
        if commands.isEmpty {
            adoptedBaseline = record.baseline
            recoveryRecord = record
            clearPending = true
            guard await retryPendingClear(), lifecycleRequest == request else {
                throw CancellationError()
            }
            return
        }

        for command in commands {
            let matches = try await retryValue {
                try await self.light.currentStateMatches(command)
            }
            guard lifecycleRequest == request else { throw CancellationError() }
            if matches {
                baseline = record.baseline
                recoveryRecord = record
                guard await restoreCurrentOwnership(), lifecycleRequest == request else {
                    throw MonitoringOrchestratorError.operationFailed
                }
                return
            }
        }

        let external = try await retryValue { try await self.light.captureBaseline() }
        guard lifecycleRequest == request else { throw CancellationError() }
        let replacement = MonitoringRecoveryRecord(baseline: external)
        try await recoveryStore.save(replacement)
        adoptedBaseline = external
        recoveryRecord = replacement
        clearPending = true
        guard await retryPendingClear(), lifecycleRequest == request else {
            throw MonitoringOrchestratorError.operationFailed
        }
    }

    private func scheduleThrottleIfNeeded() {
        guard mode == .active,
              connection == .connected,
              restoreTask == nil,
              !clearPending,
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
              connection == .connected,
              restoreTask == nil,
              !clearPending else { return }
        let winner = await coordinator.currentWinner()
        guard generation == token, mode == .active else { return }
        guard let winner, let color = winner.state.color else {
            finishThrottle(id: id)
            _ = await restoreCurrentOwnership()
            return
        }
        let desired = DesiredLightState(color: color)
        if desired == lastApplied {
            finishThrottle(id: id)
            return
        }

        let outcome = await apply(desired, winnerSequence: winner.sequence, generation: token)
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
        guard generation == token, mode == .active else { return }
        if case .failed = outcome { return }
        if (await coordinator.currentWinner())?.sequence != winner.sequence {
            scheduleThrottleIfNeeded()
        }
    }

    private func apply(
        _ desired: DesiredLightState,
        winnerSequence: UInt64,
        generation token: UInt64
    ) async -> SendOutcome {
        do {
            try await ensureOwnership(generation: token)
            guard await isCurrent(desired, winnerSequence: winnerSequence, generation: token),
                  let currentRecord = recoveryRecord else {
                return .superseded
            }
            let pending = MonitoringRecoveryRecord(
                baseline: currentRecord.baseline,
                lastCommand: currentRecord.lastCommand,
                pendingCommand: desired
            )
            try await recoveryStore.save(pending)
            recoveryRecord = pending
            guard await isCurrent(desired, winnerSequence: winnerSequence, generation: token) else {
                return .superseded
            }

            try await retryValue(
                isStillCurrent: {
                    await self.isCurrent(desired, winnerSequence: winnerSequence, generation: token)
                }
            ) {
                try await self.light.apply(desired)
            }
            guard await isCurrent(desired, winnerSequence: winnerSequence, generation: token) else {
                return .superseded
            }
            let committed = MonitoringRecoveryRecord(
                baseline: pending.baseline,
                lastCommand: desired
            )
            try await recoveryStore.save(committed)
            recoveryRecord = committed
            return .applied(desired)
        } catch is CancellationError {
            return .superseded
        } catch {
            return .failed
        }
    }

    private func ensureOwnership(generation token: UInt64) async throws {
        if baseline != nil, recoveryRecord != nil { return }
        guard generation == token, mode == .active, !clearPending, restoreTask == nil else {
            throw CancellationError()
        }
        let captured = try await retryValue(
            isStillCurrent: { await self.isGenerationActive(token) }
        ) {
            try await self.light.captureBaseline()
        }
        guard generation == token, mode == .active else { throw CancellationError() }
        let record = MonitoringRecoveryRecord(baseline: captured)
        try await recoveryStore.save(record)
        guard generation == token, mode == .active else {
            recoveryRecord = record
            clearPending = true
            throw CancellationError()
        }
        baseline = captured
        recoveryRecord = record
    }

    private func isCurrent(
        _ desired: DesiredLightState,
        winnerSequence: UInt64,
        generation token: UInt64
    ) async -> Bool {
        guard !Task.isCancelled,
              generation == token,
              mode == .active,
              restoreTask == nil,
              !clearPending,
              let winner = await coordinator.currentWinner(),
              winner.sequence == winnerSequence,
              winner.state.color == desired.color else {
            return false
        }
        return true
    }

    private func isGenerationActive(_ token: UInt64) -> Bool {
        generation == token && mode == .active
    }

    private func restoreCurrentOwnership() async -> Bool {
        if clearPending {
            return await retryPendingClear()
        }
        if let task = restoreTask, let id = restoreTaskID {
            return await resolveRestore(task, id: id)
        }
        guard let baseline else { return true }
        let id = UUID()
        let task = Task<Void, Error> {
            try await self.retryValue {
                try await self.light.restore(baseline)
            }
        }
        restoreTask = task
        restoreTaskID = id
        return await resolveRestore(task, id: id)
    }

    private func resolveRestore(_ task: Task<Void, Error>, id: UUID) async -> Bool {
        do {
            try await task.value
            if restoreTaskID == id {
                restoreTask = nil
                restoreTaskID = nil
                baseline = nil
                lastApplied = nil
                clearPending = recoveryRecord != nil
            }
            let cleared = await retryPendingClear()
            if cleared, mode == .active {
                connection = .connected
                await refreshSnapshot()
                scheduleThrottleIfNeeded()
            }
            return cleared
        } catch {
            if restoreTaskID == id {
                restoreTask = nil
                restoreTaskID = nil
                connection = .disconnected
                await refreshSnapshot()
            }
            return false
        }
    }

    private func retryPendingClear() async -> Bool {
        guard clearPending else { return true }
        do {
            try Task.checkCancellation()
            try await recoveryStore.clear()
            clearPending = false
            recoveryRecord = nil
            return true
        } catch {
            connection = .disconnected
            await refreshSnapshot()
            return false
        }
    }

    private func retryValue<T: Sendable>(
        isStillCurrent: @escaping @Sendable () async -> Bool = { true },
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let delays: [Duration] = [.milliseconds(500), .seconds(1)]
        for attempt in 0...delays.count {
            guard await isStillCurrent() else { throw CancellationError() }
            do {
                return try await operation()
            } catch {
                guard attempt < delays.count, isTransient(error) else { throw error }
                let delay = delays[attempt] + boundedJitter(for: delays[attempt])
                try await clock.sleep(for: delay)
            }
        }
        throw MonitoringOrchestratorError.operationFailed
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
        guard mode == .active,
              generation == token,
              latestSessionSequence[sessionID] == sequence else { return }
        if terminalTasks[sessionID]?.id == timerID {
            terminalTasks[sessionID] = nil
        }
        await coordinator.expireTerminalState(sessionID: sessionID, sequence: sequence)
        guard mode == .active, generation == token else { return }
        await refreshSnapshot()
        if await coordinator.currentWinner() == nil {
            await cancelThrottleAndWait()
            guard mode == .active, generation == token else { return }
            if await coordinator.currentWinner() == nil {
                _ = await restoreCurrentOwnership()
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
        subscribers.yield(snapshot)
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
}
