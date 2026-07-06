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

private actor MonitoringOperationCompletion {
    private var isFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var waiterCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func wait() async {
        if isFinished { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            resumeWaiterCountWaiters()
        }
    }

    func waitUntilWaiterCount(_ count: Int) async {
        if waiters.count >= count { return }
        await withCheckedContinuation { continuation in
            waiterCountWaiters.append((count, continuation))
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }

    private func resumeWaiterCountWaiters() {
        let ready = waiterCountWaiters.filter { waiters.count >= $0.0 }
        waiterCountWaiters.removeAll { waiters.count >= $0.0 }
        for waiter in ready { waiter.1.resume() }
    }
}

private actor MonitoringResultCompletion {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func finish(_ result: Bool) {
        guard self.result == nil else { return }
        self.result = result
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume(returning: result) }
    }
}

public actor MonitoringOrchestrator: MonitoringOrchestrating {
    typealias Jitter = @Sendable (Duration) -> Duration
    typealias TransientErrorClassifier = @Sendable (any Error) -> Bool

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

    private enum ReconnectHealthOutcome: Sendable {
        case matching
        case mismatching
        case healthy
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
    private var lifecycleRequestWaiters: [(UInt64, CheckedContinuation<Void, Never>)] = []
    private var lifecycleTail: MonitoringResultCompletion?
    private var lifecycleTailID: UUID?
    private var currentTransitionKind: LifecycleOperation?
    private var currentTransitionCompletion: MonitoringResultCompletion?
    private var currentTransitionID: UUID?
    private var nextSequence: UInt64 = 0
    private var latestSessionSequence: [String: UInt64] = [:]
    private var baseline: BulbBaseline?
    private var recoveryRecord: MonitoringRecoveryRecord?
    private var adoptedBaseline: BulbBaseline?
    private var clearPending = false
    private var restoreCompletion: MonitoringResultCompletion?
    private var restoreTaskID: UUID?
    private var throttleTask: Task<Void, Never>?
    private var throttleID: UUID?
    private var throttleOperationStarted = false
    private var throttleRescheduleRequested = false
    private var reconnectCompletion: MonitoringOperationCompletion?
    private var reconnectApplyCompletion: MonitoringOperationCompletion?
    private var reconnectApplyPending = false
    private var reconnectHealthTask: Task<ReconnectHealthOutcome, Never>?
    private var reconnectHealthID: UUID?
    private var lifecycleRetryID: UUID?
    private var cancelLifecycleRetry: (@Sendable () -> Void)?
    private var terminalTasks: [String: TerminalTimer] = [:]
    private var lastApplied: DesiredLightState?
    private var connection: LightConnectionStatus = .connected
    private var snapshot = MonitoringSnapshot(state: .idle, sessions: [], connection: .connected)

    public init(
        light: any TuyaLightControlling,
        recoveryStore: any MonitoringRecoveryStoring
    ) {
        self.init(
            light: light,
            recoveryStore: recoveryStore,
            coordinator: SessionCoordinator(),
            clock: ContinuousAgentLightClock(),
            jitter: {
                MonitoringOrchestrator.productionJitter(
                    for: $0,
                    sample: Double.random(in: 0...1)
                )
            },
            isTransient: MonitoringOrchestrator.defaultTransientClassifier
        )
    }

    init(
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
        throttleTask?.cancel()
        reconnectHealthTask?.cancel()
        cancelLifecycleRetry?()
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

        if throttleOperationStarted {
            throttleRescheduleRequested = true
            throttleTask?.cancel()
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
        if let reconnectCompletion {
            await reconnectCompletion.wait()
            return
        }
        let completion = MonitoringOperationCompletion()
        reconnectCompletion = completion
        await performReconnect()
        if reconnectCompletion === completion {
            reconnectCompletion = nil
        }
        await completion.finish()
    }

    private func performReconnect() async {
        guard mode == .active, connection == .disconnected else { return }
        let token = generation
        if clearPending {
            guard await retryPendingClear(), generation == token, mode == .active else { return }
        }

        let light = self.light
        let clock = self.clock
        let jitter = self.jitter
        let isTransient = self.isTransient
        let lastApplied = self.lastApplied
        let healthID = UUID()
        let healthTask = Task<ReconnectHealthOutcome, Never> {
            do {
                try await clock.sleep(for: .seconds(1))
                try Task.checkCancellation()
                if let lastApplied {
                    let matches = try await Self.retryExternal(
                        clock: clock,
                        jitter: jitter,
                        isTransient: isTransient
                    ) {
                        try await light.currentStateMatches(lastApplied)
                    }
                    return matches ? .matching : .mismatching
                }
                _ = try await Self.retryExternal(
                    clock: clock,
                    jitter: jitter,
                    isTransient: isTransient
                ) {
                    try await light.captureBaseline()
                }
                return .healthy
            } catch {
                return .failed
            }
        }
        reconnectHealthTask = healthTask
        reconnectHealthID = healthID
        let health = await healthTask.value
        if reconnectHealthID == healthID {
            reconnectHealthTask = nil
            reconnectHealthID = nil
        }
        guard generation == token, mode == .active else { return }

        switch health {
        case .matching, .healthy:
            connection = .connected
            await refreshSnapshot()
            scheduleThrottleIfNeeded()
        case .mismatching:
            guard let winner = await coordinator.currentWinner(),
                  winner.state.color != nil,
                  generation == token,
                  mode == .active else {
                return
            }
            let applyCompletion = MonitoringOperationCompletion()
            reconnectApplyCompletion = applyCompletion
            reconnectApplyPending = true
            scheduleThrottleIfNeeded()
            await applyCompletion.wait()
        case .failed:
            if generation == token, mode == .active {
                connection = .disconnected
                await refreshSnapshot()
            }
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

    func waitForLifecycleRequestNumber(_ number: UInt64) async {
        if lifecycleRequest >= number { return }
        await withCheckedContinuation { continuation in
            lifecycleRequestWaiters.append((number, continuation))
        }
    }

    func waitForReconnectWaiterCount(_ count: Int) async {
        await reconnectCompletion?.waitUntilWaiterCount(count)
    }

    nonisolated static func productionJitter(for base: Duration, sample: Double) -> Duration {
        _ = base
        let bounded = min(max(sample, 0), 1)
        let milliseconds = 1 + Int((bounded * 249).rounded(.down))
        return .milliseconds(milliseconds)
    }

    nonisolated static func defaultTransientClassifier(_ error: any Error) -> Bool {
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
        case .transport:
            return true
        case let .httpStatus(status):
            return status == 408 || status == 429 || (500...599).contains(status)
        case .invalidEndpoint, .malformedResponse, .apiFailure, .authenticationFailure:
            return false
        }
    }

    private func enqueueLifecycle(_ operation: LifecycleOperation) async throws {
        if operation == .activate,
           currentTransitionKind == .activate,
           let currentTransitionCompletion {
            try resolveTransitionResult(await currentTransitionCompletion.wait() ? .success : .failure)
            return
        }

        lifecycleRequest &+= 1
        reconnectHealthTask?.cancel()
        cancelLifecycleRetry?()
        let readyRequestWaiters = lifecycleRequestWaiters.filter { lifecycleRequest >= $0.0 }
        lifecycleRequestWaiters.removeAll { lifecycleRequest >= $0.0 }
        for waiter in readyRequestWaiters { waiter.1.resume() }
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

        let completion = MonitoringResultCompletion()
        lifecycleTail = completion
        lifecycleTailID = id
        currentTransitionKind = operation
        currentTransitionCompletion = completion
        currentTransitionID = id

        _ = await predecessor?.wait()
        let result = await performLifecycle(operation, request: request)
        let succeeded: Bool
        switch result {
        case .success: succeeded = true
        case .failure: succeeded = false
        }
        await completion.finish(succeeded)
        if currentTransitionID == id {
            currentTransitionKind = nil
            currentTransitionCompletion = nil
            currentTransitionID = nil
        }
        if lifecycleTailID == id {
            lifecycleTail = nil
            lifecycleTailID = nil
        }
        try resolveTransitionResult(result)
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
        if restoreCompletion != nil || clearPending {
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
            let light = self.light
            captured = try await retryLifecycle(request: request) {
                try await light.captureBaseline()
            }
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
        if let reconnectCompletion {
            await reconnectCompletion.wait()
        }
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
            let light = self.light
            let matches = try await retryLifecycle(request: request) {
                try await light.currentStateMatches(command)
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

        let light = self.light
        let external = try await retryLifecycle(request: request) {
            try await light.captureBaseline()
        }
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
              connection == .connected || reconnectApplyPending,
              restoreCompletion == nil,
              !clearPending,
              throttleTask == nil else { return }
        let id = UUID()
        let token = generation
        throttleID = id
        throttleTask = Task { [clock, weak self] in
            do {
                try await clock.sleep(for: .seconds(1))
            } catch {
                await self?.cancelledThrottle(id: id)
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
              connection == .connected || reconnectApplyPending,
              restoreCompletion == nil,
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

        throttleOperationStarted = true
        let outcome = await apply(desired, winnerSequence: winner.sequence, generation: token)
        throttleOperationStarted = false
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
        if reconnectApplyPending {
            reconnectApplyPending = false
            let completion = reconnectApplyCompletion
            reconnectApplyCompletion = nil
            await completion?.finish()
        }
        await refreshSnapshot()
        guard generation == token, mode == .active else { return }
        if case .failed = outcome { return }
        let currentWinner = await coordinator.currentWinner()
        if throttleRescheduleRequested || currentWinner?.sequence != winner.sequence {
            throttleRescheduleRequested = false
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
        guard generation == token, mode == .active, !clearPending, restoreCompletion == nil else {
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
              restoreCompletion == nil,
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
        if let restoreCompletion {
            return await restoreCompletion.wait()
        }
        guard let expectedBaseline = baseline else { return true }
        let id = UUID()
        let completion = MonitoringResultCompletion()
        restoreCompletion = completion
        restoreTaskID = id
        do {
            try await retryValue { try await self.light.restore(expectedBaseline) }
            if restoreTaskID == id {
                restoreCompletion = nil
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
            await completion.finish(cleared)
            return cleared
        } catch {
            if restoreTaskID == id {
                restoreCompletion = nil
                restoreTaskID = nil
                connection = .disconnected
                await refreshSnapshot()
            }
            await completion.finish(false)
            return false
        }
    }

    private func retryPendingClear() async -> Bool {
        guard clearPending else { return true }
        do {
            try Task.checkCancellation()
            guard let expectedRecord = recoveryRecord else { return true }
            try await recoveryStore.clear(expecting: expectedRecord)
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
                guard await isStillCurrent() else { throw CancellationError() }
                let delay = delays[attempt] + boundedJitter(for: delays[attempt])
                try await clock.sleep(for: delay)
                guard await isStillCurrent() else { throw CancellationError() }
            }
        }
        throw MonitoringOrchestratorError.operationFailed
    }

    private func retryLifecycle<T: Sendable>(
        request: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let id = UUID()
        let clock = self.clock
        let jitter = self.jitter
        let isTransient = self.isTransient
        let task = Task<T, Error> {
            try await Self.retryExternal(
                clock: clock,
                jitter: jitter,
                isTransient: isTransient,
                operation: operation
            )
        }
        lifecycleRetryID = id
        cancelLifecycleRetry = { task.cancel() }
        do {
            let value = try await task.value
            if lifecycleRetryID == id {
                lifecycleRetryID = nil
                cancelLifecycleRetry = nil
            }
            guard lifecycleRequest == request else { throw CancellationError() }
            return value
        } catch {
            if lifecycleRetryID == id {
                lifecycleRetryID = nil
                cancelLifecycleRetry = nil
            }
            throw error
        }
    }

    private nonisolated static func retryExternal<T: Sendable>(
        clock: any AgentLightClock,
        jitter: @escaping Jitter,
        isTransient: @escaping TransientErrorClassifier,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let delays: [Duration] = [.milliseconds(500), .seconds(1)]
        for attempt in 0...delays.count {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch {
                try Task.checkCancellation()
                guard attempt < delays.count, isTransient(error) else { throw error }
                let bounded = min(max(jitter(delays[attempt]), .zero), .milliseconds(250))
                try await clock.sleep(for: delays[attempt] + bounded)
                try Task.checkCancellation()
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
        throttleOperationStarted = false
    }

    private func cancelledThrottle(id: UUID) async {
        guard throttleID == id else { return }
        finishThrottle(id: id)
        if reconnectApplyPending {
            reconnectApplyPending = false
            let completion = reconnectApplyCompletion
            reconnectApplyCompletion = nil
            await completion?.finish()
        }
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
