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

    func wait() async {
        if isFinished { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
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

private enum MonitoringLifecycleWaiterResult: Sendable {
    case success
    case failure
    case cancelled
}

private actor MonitoringLifecycleWaiterCompletion {
    private var result: MonitoringLifecycleWaiterResult?
    private var waiters: [CheckedContinuation<MonitoringLifecycleWaiterResult, Never>] = []

    func wait() async -> MonitoringLifecycleWaiterResult {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func finish(_ result: MonitoringLifecycleWaiterResult) {
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
        case physicallyAppliedButSuperseded(DesiredLightState)
        case superseded
        case failed(DesiredLightState?)
    }

    private enum ReconnectHealthOutcome: Sendable {
        case matching
        case mismatching
        case healthy
        case failed
    }

    private struct ReconnectOperation: Sendable {
        enum Phase: Equatable, Sendable {
            case health
            case commandWindow
            case applying
        }

        let id: UUID
        var phase: Phase
        var allowsDeduplication: Bool
        var waiters: [UUID: MonitoringOperationCompletion]
        let completion: MonitoringOperationCompletion
        var terminal: ReconnectTerminal?
        var driverTask: Task<Void, Never>?
    }

    private enum ReconnectTerminal: Sendable {
        case connected
        case disconnected
        case lifecycleCancelled
    }

    private struct LifecycleResolution: Sendable {
        let activeWaiters: [MonitoringLifecycleWaiterCompletion]
        let activeResult: MonitoringLifecycleWaiterResult
        let cancelledWaiters: [MonitoringLifecycleWaiterCompletion]
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
    private var currentTransitionID: UUID?
    private var lifecycleTransitionWaiters: [UUID: [UUID: MonitoringLifecycleWaiterCompletion]] = [:]
    private var lifecycleCancelledWaiters: [UUID: [MonitoringLifecycleWaiterCompletion]] = [:]
    private var lifecycleTransitionRequests: [UUID: UInt64] = [:]
    private var lifecycleTransitionKinds: [UUID: LifecycleOperation] = [:]
    private var lifecycleTransitionPriorModes: [UUID: Mode] = [:]
    private var lifecycleRollbackRequests: [UUID: (request: UInt64, mode: Mode)] = [:]
    private var lifecycleWaiterCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var nextSequence: UInt64 = 0
    private var latestSessionSequence: [String: UInt64] = [:]
    private var baseline: BulbBaseline?
    private var storedRecovery: StoredMonitoringRecovery?
    private var adoptedBaseline: BulbBaseline?
    private var clearPending = false
    private var restoreCompletion: MonitoringResultCompletion?
    private var restoreTaskID: UUID?
    private var throttleTask: Task<Void, Never>?
    private var throttleID: UUID?
    private var throttleOperationStarted = false
    private var throttleRescheduleRequested = false
    private var reconnectOperation: ReconnectOperation?
    private var reconnectWaiterCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var blockNextReconnectWaiterFinish = false
    private var reconnectWaiterFinishBlocked = MonitoringOperationCompletion()
    private var reconnectWaiterFinishRelease = MonitoringOperationCompletion()
    private var reconnectHealthTask: Task<ReconnectHealthOutcome, Never>?
    private var lifecycleRetryID: UUID?
    private var cancelLifecycleRetry: (@Sendable () -> Void)?
    private var terminalTasks: [String: TerminalTimer] = [:]
    private var lastApplied: DesiredLightState?
    private var lastAppliedWaiters: [(DesiredLightState, CheckedContinuation<Void, Never>)] = []
    private var connection: LightConnectionStatus = .connected
    private var connectionWaiters: [(LightConnectionStatus, CheckedContinuation<Void, Never>)] = []
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
        reconnectOperation?.driverTask?.cancel()
        reconnectHealthTask?.cancel()
        cancelLifecycleRetry?()
        for timer in terminalTasks.values {
            timer.task.cancel()
        }
        subscribers.finishAll()
    }

    public func start() async throws {
        if mode == .active, lifecycleTail == nil { return }
        try await awaitLifecycle(.activate)
    }

    public func resume() async throws {
        try await start()
    }

    public func pause() async {
        try? await awaitLifecycle(.pause)
    }

    public func stop() async {
        try? await awaitLifecycle(.stop)
    }

    public func recoverIfNeeded() async throws {
        guard mode == .inactive else { return }
        try await awaitLifecycle(.recover)
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
            let reconnectID = reconnectOperation?.id
            if let reconnectID {
                await cancelReconnectAndWait(id: reconnectID)
            }
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
        let waiterID = UUID()
        let waiterCompletion = MonitoringOperationCompletion()
        let operationID: UUID
        let startsOperation: Bool
        if var operation = reconnectOperation {
            operation.waiters[waiterID] = waiterCompletion
            reconnectOperation = operation
            operationID = operation.id
            startsOperation = false
        } else {
            operationID = UUID()
            reconnectOperation = ReconnectOperation(
                id: operationID,
                phase: .health,
                allowsDeduplication: true,
                waiters: [waiterID: waiterCompletion],
                completion: MonitoringOperationCompletion(),
                terminal: nil,
                driverTask: nil
            )
            startsOperation = true
        }
        resumeReconnectWaiterCountWaiters()

        if startsOperation {
            let driver = Task { [weak self] in
                await self?.performReconnect(id: operationID)
                do {
                    try await Task.sleep(for: .seconds(31_536_000))
                } catch {}
                await self?.finishReconnectFromDriver(id: operationID)
            }
            if reconnectOperation?.id == operationID {
                reconnectOperation?.driverTask = driver
            } else {
                driver.cancel()
            }
        }

        await withTaskCancellationHandler {
            await waiterCompletion.wait()
        } onCancel: { [weak self] in
            Task { [weak self] in
                await self?.cancelReconnectWaiter(
                    operationID: operationID,
                    waiterID: waiterID
                )
            }
        }
    }

    private func performReconnect(id: UUID) async {
        guard reconnectOperation?.id == id,
              mode == .active,
              connection == .disconnected else {
            await requestReconnectTerminal(id: id, terminal: .lifecycleCancelled)
            return
        }
        let token = generation
        if clearPending {
            guard await retryPendingClear() else {
                await requestReconnectTerminal(id: id, terminal: .disconnected)
                return
            }
            guard reconnectOperation?.id == id,
                  generation == token,
                  mode == .active else {
                await requestReconnectTerminal(id: id, terminal: .lifecycleCancelled)
                return
            }
        }

        let light = self.light
        let clock = self.clock
        let jitter = self.jitter
        let isTransient = self.isTransient
        let lastApplied = self.lastApplied
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
        let health = await healthTask.value
        if reconnectOperation?.id == id {
            reconnectHealthTask = nil
        }
        guard reconnectOperation?.id == id else { return }
        guard generation == token, mode == .active else {
            await requestReconnectTerminal(id: id, terminal: .lifecycleCancelled)
            return
        }

        switch health {
        case .matching, .healthy:
            await continueReconnectAfterHealth(id: id, generation: token, allowsDeduplication: true)
        case .mismatching:
            await continueReconnectAfterHealth(id: id, generation: token, allowsDeduplication: false)
        case .failed:
            await requestReconnectTerminal(id: id, terminal: .disconnected)
        }
    }

    private func continueReconnectAfterHealth(
        id: UUID,
        generation token: UInt64,
        allowsDeduplication: Bool
    ) async {
        let winner = await coordinator.currentWinner()
        guard reconnectOperation?.id == id,
              generation == token,
              mode == .active else {
            await requestReconnectTerminal(id: id, terminal: .lifecycleCancelled)
            return
        }
        guard let winner, let color = winner.state.color else {
            await requestReconnectTerminal(id: id, terminal: .connected)
            return
        }
        let desired = DesiredLightState(color: color)
        guard !allowsDeduplication || desired != lastApplied else {
            await requestReconnectTerminal(id: id, terminal: .connected)
            return
        }
        reconnectOperation?.allowsDeduplication = allowsDeduplication
        reconnectOperation?.phase = .commandWindow
        scheduleThrottleIfNeeded()
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

    func waitForLifecycleWaiterCount(_ count: Int) async {
        if lifecycleTransitionWaiters.values.contains(where: { $0.count >= count }) { return }
        await withCheckedContinuation { continuation in
            lifecycleWaiterCountWaiters.append((count, continuation))
        }
    }

    func waitForReconnectWaiterCount(_ count: Int) async {
        if let reconnectOperation, reconnectOperation.waiters.count >= count { return }
        await withCheckedContinuation { continuation in
            reconnectWaiterCountWaiters.append((count, continuation))
        }
    }

    func waitForLastApplied(_ state: DesiredLightState) async {
        if lastApplied == state { return }
        await withCheckedContinuation { continuation in
            lastAppliedWaiters.append((state, continuation))
        }
    }

    func waitForConnection(_ status: LightConnectionStatus) async {
        if connection == status { return }
        await withCheckedContinuation { continuation in
            connectionWaiters.append((status, continuation))
        }
    }

    func blockNextReconnectWaiterCompletion() {
        blockNextReconnectWaiterFinish = true
        reconnectWaiterFinishBlocked = MonitoringOperationCompletion()
        reconnectWaiterFinishRelease = MonitoringOperationCompletion()
    }

    func waitUntilReconnectWaiterCompletionIsBlocked() async {
        await reconnectWaiterFinishBlocked.wait()
    }

    func releaseReconnectWaiterCompletion() async {
        await reconnectWaiterFinishRelease.finish()
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

    private func awaitLifecycle(_ operation: LifecycleOperation) async throws {
        let waiterID = UUID()
        let waiterCompletion = MonitoringLifecycleWaiterCompletion()
        try await withTaskCancellationHandler {
            try await enqueueLifecycle(
                operation,
                waiterID: waiterID,
                waiterCompletion: waiterCompletion
            )
        } onCancel: { [weak self] in
            Task { [weak self] in
                await self?.cancelLifecycleWaiter(waiterID)
            }
        }
    }

    private func enqueueLifecycle(
        _ operation: LifecycleOperation,
        waiterID: UUID,
        waiterCompletion: MonitoringLifecycleWaiterCompletion
    ) async throws {
        if operation == .activate,
           currentTransitionKind == .activate,
           let currentTransitionID {
            lifecycleTransitionWaiters[currentTransitionID, default: [:]][waiterID] = waiterCompletion
            resumeLifecycleWaiterCountWaiters()
            try resolveLifecycleWaiterResult(await waiterCompletion.wait())
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
        let priorMode = mode
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
        currentTransitionID = id
        lifecycleTransitionWaiters[id] = [waiterID: waiterCompletion]
        lifecycleTransitionRequests[id] = request
        lifecycleTransitionKinds[id] = operation
        lifecycleTransitionPriorModes[id] = priorMode
        resumeLifecycleWaiterCountWaiters()

        Task { [weak self] in
            guard let resolution = await self?.runLifecycle(
                operation,
                request: request,
                id: id,
                predecessor: predecessor,
                completion: completion
            ) else {
                await waiterCompletion.finish(.failure)
                return
            }
            for waiter in resolution.activeWaiters {
                await waiter.finish(resolution.activeResult)
            }
            for waiter in resolution.cancelledWaiters {
                await waiter.finish(.cancelled)
            }
        }
        try resolveLifecycleWaiterResult(await waiterCompletion.wait())
    }

    private func runLifecycle(
        _ operation: LifecycleOperation,
        request: UInt64,
        id: UUID,
        predecessor: MonitoringResultCompletion?,
        completion: MonitoringResultCompletion
    ) async -> LifecycleResolution {
        _ = await predecessor?.wait()
        let result = await performLifecycle(operation, request: request)
        let succeeded: Bool
        switch result {
        case .success: succeeded = true
        case .failure: succeeded = false
        }
        await completion.finish(succeeded)
        let waiterResult: MonitoringLifecycleWaiterResult = succeeded ? .success : .failure
        let activeWaiters = lifecycleTransitionWaiters[id].map { Array($0.values) } ?? []
        let cancelledWaiters = lifecycleCancelledWaiters[id] ?? []
        if let rollback = lifecycleRollbackRequests[id], lifecycleRequest == rollback.request {
            mode = rollback.mode
            await refreshSnapshot()
            if mode == .active {
                scheduleThrottleIfNeeded()
            }
        }
        lifecycleTransitionWaiters[id] = nil
        lifecycleCancelledWaiters[id] = nil
        lifecycleTransitionRequests[id] = nil
        lifecycleTransitionKinds[id] = nil
        lifecycleTransitionPriorModes[id] = nil
        lifecycleRollbackRequests[id] = nil
        if currentTransitionID == id {
            currentTransitionKind = nil
            currentTransitionID = nil
        }
        if lifecycleTailID == id {
            lifecycleTail = nil
            lifecycleTailID = nil
        }
        return LifecycleResolution(
            activeWaiters: activeWaiters,
            activeResult: waiterResult,
            cancelledWaiters: cancelledWaiters
        )
    }

    private func cancelLifecycleWaiter(_ waiterID: UUID) async {
        guard let transition = lifecycleTransitionWaiters.first(where: {
            $0.value[waiterID] != nil
        }) else { return }
        var waiters = transition.value
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
        lifecycleTransitionWaiters[transition.key] = waiters
        let cancelsOperation = waiters.isEmpty
            && lifecycleTransitionRequests[transition.key] == lifecycleRequest
        guard cancelsOperation else {
            await waiter.finish(.cancelled)
            return
        }
        lifecycleCancelledWaiters[transition.key, default: []].append(waiter)
        if currentTransitionID == transition.key {
            currentTransitionKind = nil
            currentTransitionID = nil
        }

        cancelLifecycleRetry?()
        lifecycleRequest &+= 1
        generation &+= 1
        let cancellationRequest = lifecycleRequest
        if let priorMode = lifecycleTransitionPriorModes[transition.key] {
            switch lifecycleTransitionKinds[transition.key] {
            case .activate, .recover:
                mode = priorMode
            case .pause, .stop:
                lifecycleRollbackRequests[transition.key] = (cancellationRequest, priorMode)
            case nil:
                break
            }
        }
        let readyRequestWaiters = lifecycleRequestWaiters.filter { lifecycleRequest >= $0.0 }
        lifecycleRequestWaiters.removeAll { lifecycleRequest >= $0.0 }
        for waiter in readyRequestWaiters { waiter.1.resume() }
    }

    private func resumeLifecycleWaiterCountWaiters() {
        let maximum = lifecycleTransitionWaiters.values.map(\.count).max() ?? 0
        let ready = lifecycleWaiterCountWaiters.filter { maximum >= $0.0 }
        lifecycleWaiterCountWaiters.removeAll { maximum >= $0.0 }
        for waiter in ready { waiter.1.resume() }
    }

    private func resolveLifecycleWaiterResult(
        _ result: MonitoringLifecycleWaiterResult
    ) throws {
        switch result {
        case .success:
            return
        case .failure:
            throw MonitoringOrchestratorError.operationFailed
        case .cancelled:
            throw CancellationError()
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

        if baseline != nil, storedRecovery != nil {
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
        let revision = try await recoveryStore.save(record)
        let stored = StoredMonitoringRecovery(record: record, revision: revision)
        guard lifecycleRequest == request else {
            storedRecovery = stored
            clearPending = true
            throw CancellationError()
        }
        baseline = captured
        storedRecovery = stored
        connection = .connected
        mode = .active
        await refreshSnapshot()
    }

    private func performDeactivate(target: Mode, request: UInt64) async {
        await cancelReconnectAndWait()
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
        guard let stored = try await recoveryStore.load() else { return }
        guard lifecycleRequest == request else { throw CancellationError() }
        let record = stored.record
        let commands = [record.lastCommand, record.pendingCommand].compactMap { $0 }
        if commands.isEmpty {
            adoptedBaseline = record.baseline
            storedRecovery = stored
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
                storedRecovery = stored
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
        let revision = try await recoveryStore.save(replacement)
        adoptedBaseline = external
        storedRecovery = StoredMonitoringRecovery(record: replacement, revision: revision)
        clearPending = true
        guard await retryPendingClear(), lifecycleRequest == request else {
            throw MonitoringOrchestratorError.operationFailed
        }
    }

    private func scheduleThrottleIfNeeded() {
        let reconnectCanApply = reconnectOperation?.phase == .commandWindow
        guard mode == .active,
              connection == .connected || reconnectCanApply,
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
            guard !Task.isCancelled else {
                await self?.cancelledThrottle(id: id)
                return
            }
            await self?.fireThrottle(id: id, generation: token)
        }
    }

    private func fireThrottle(id: UUID, generation token: UInt64) async {
        let reconnectID = reconnectOperation?.phase == .commandWindow
            ? reconnectOperation?.id
            : nil
        guard throttleID == id,
              generation == token,
              mode == .active,
              connection == .connected || reconnectID != nil,
              restoreCompletion == nil,
              !clearPending else {
            finishThrottle(id: id)
            return
        }
        let winner = await coordinator.currentWinner()
        guard throttleID == id, generation == token, mode == .active else {
            finishThrottle(id: id)
            return
        }
        guard let winner, let color = winner.state.color else {
            finishThrottle(id: id)
            if let reconnectID {
                await requestReconnectTerminal(id: reconnectID, terminal: .connected)
            } else {
                _ = await restoreCurrentOwnership()
            }
            return
        }
        let desired = DesiredLightState(color: color)
        let canDeduplicate = reconnectID == nil
            || reconnectOperation?.allowsDeduplication == true
        if desired == lastApplied, canDeduplicate {
            finishThrottle(id: id)
            if let reconnectID {
                await requestReconnectTerminal(id: reconnectID, terminal: .connected)
            }
            return
        }

        if let reconnectID, reconnectOperation?.id == reconnectID {
            reconnectOperation?.phase = .applying
        }
        throttleOperationStarted = true
        let outcome = await apply(desired, winnerSequence: winner.sequence, generation: token)
        throttleOperationStarted = false
        finishThrottle(id: id)

        if let reconnectID, reconnectOperation?.id == reconnectID {
            await resolveReconnectApply(
                id: reconnectID,
                outcome: outcome,
                attemptedWinnerSequence: winner.sequence,
                appliedState: desired,
                generation: token
            )
            return
        }

        switch outcome {
        case let .applied(state):
            lastApplied = state
            resumeLastAppliedWaiters()
            connection = .connected
        case let .physicallyAppliedButSuperseded(state):
            lastApplied = state
            resumeLastAppliedWaiters()
        case .superseded:
            break
        case let .failed(physicalState):
            if let physicalState {
                lastApplied = physicalState
                resumeLastAppliedWaiters()
            }
            connection = .disconnected
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
        var physicallyApplied: DesiredLightState?
        do {
            try await ensureOwnership(generation: token)
            guard await isCurrent(desired, winnerSequence: winnerSequence, generation: token),
                  let currentRecord = storedRecovery?.record else {
                return .superseded
            }
            let pending = MonitoringRecoveryRecord(
                baseline: currentRecord.baseline,
                lastCommand: currentRecord.lastCommand,
                pendingCommand: desired
            )
            let pendingRevision = try await recoveryStore.save(pending)
            storedRecovery = StoredMonitoringRecovery(
                record: pending,
                revision: pendingRevision
            )
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
            physicallyApplied = desired
            let currentAfterApply = await isCurrent(
                desired,
                winnerSequence: winnerSequence,
                generation: token
            )
            let committed = MonitoringRecoveryRecord(
                baseline: pending.baseline,
                lastCommand: desired
            )
            let recoveryStore = self.recoveryStore
            let committedRevision = try await Task {
                try await recoveryStore.save(committed)
            }.value
            storedRecovery = StoredMonitoringRecovery(
                record: committed,
                revision: committedRevision
            )
            let currentAfterSave = await isCurrent(
                desired,
                winnerSequence: winnerSequence,
                generation: token
            )
            return currentAfterApply && currentAfterSave
                ? .applied(desired)
                : .physicallyAppliedButSuperseded(desired)
        } catch is CancellationError {
            return physicallyApplied.map(SendOutcome.failed) ?? .superseded
        } catch {
            return .failed(physicallyApplied)
        }
    }

    private func ensureOwnership(generation token: UInt64) async throws {
        if baseline != nil, storedRecovery != nil { return }
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
        let revision = try await recoveryStore.save(record)
        let stored = StoredMonitoringRecovery(record: record, revision: revision)
        guard generation == token, mode == .active else {
            storedRecovery = stored
            clearPending = true
            throw CancellationError()
        }
        baseline = captured
        storedRecovery = stored
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
                clearPending = storedRecovery != nil
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
            guard let expected = storedRecovery else { return true }
            try await recoveryStore.clear(expecting: expected)
            clearPending = false
            storedRecovery = nil
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
            let reconnectID = reconnectOperation?.id
            if let reconnectID {
                await cancelReconnectAndWait(id: reconnectID)
            }
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
        resumeConnectionWaiters()
        let sessions = await coordinator.snapshots()
        snapshot = MonitoringSnapshot(
            state: sessions.first?.state ?? .idle,
            sessions: sessions,
            connection: connection
        )
        subscribers.yield(snapshot)
    }

    private func resolveReconnectApply(
        id: UUID,
        outcome: SendOutcome,
        attemptedWinnerSequence: UInt64,
        appliedState: DesiredLightState,
        generation token: UInt64
    ) async {
        guard reconnectOperation?.id == id else { return }
        switch outcome {
        case let .applied(state):
            lastApplied = state
            resumeLastAppliedWaiters()
            await requestReconnectTerminal(id: id, terminal: .connected)
        case let .failed(physicalState):
            if let physicalState {
                lastApplied = physicalState
                resumeLastAppliedWaiters()
            }
            await requestReconnectTerminal(id: id, terminal: .disconnected)
        case let .physicallyAppliedButSuperseded(state):
            lastApplied = state
            resumeLastAppliedWaiters()
            await continueSupersededReconnect(
                id: id,
                attemptedWinnerSequence: attemptedWinnerSequence,
                appliedState: appliedState,
                generation: token
            )
        case .superseded:
            await continueSupersededReconnect(
                id: id,
                attemptedWinnerSequence: attemptedWinnerSequence,
                appliedState: appliedState,
                generation: token
            )
        }
    }

    private func continueSupersededReconnect(
        id: UUID,
        attemptedWinnerSequence: UInt64,
        appliedState: DesiredLightState,
        generation token: UInt64
    ) async {
        guard generation == token, mode == .active else {
            await requestReconnectTerminal(id: id, terminal: .lifecycleCancelled)
            return
        }
        if Task.isCancelled, !throttleRescheduleRequested {
            await requestReconnectTerminal(id: id, terminal: .lifecycleCancelled)
            return
        }
        let currentWinner = await coordinator.currentWinner()
        guard reconnectOperation?.id == id,
              generation == token,
              mode == .active else {
            await requestReconnectTerminal(id: id, terminal: .lifecycleCancelled)
            return
        }
        guard let currentWinner, let color = currentWinner.state.color else {
            await requestReconnectTerminal(id: id, terminal: .connected)
            return
        }
        let currentDesired = DesiredLightState(color: color)
        guard currentWinner.sequence != attemptedWinnerSequence || currentDesired != appliedState else {
            await requestReconnectTerminal(id: id, terminal: .disconnected)
            return
        }
        guard currentDesired != lastApplied else {
            await requestReconnectTerminal(id: id, terminal: .connected)
            return
        }
        throttleRescheduleRequested = false
        reconnectOperation?.allowsDeduplication = true
        reconnectOperation?.phase = .commandWindow
        scheduleThrottleIfNeeded()
    }

    private func requestReconnectTerminal(id: UUID, terminal: ReconnectTerminal) async {
        guard var operation = reconnectOperation, operation.id == id else { return }
        if operation.terminal == nil {
            operation.terminal = terminal
        }
        reconnectOperation = operation
        reconnectHealthTask?.cancel()
        throttleTask?.cancel()
        operation.driverTask?.cancel()
    }

    private func finishReconnectFromDriver(id: UUID) async {
        guard let operation = reconnectOperation, operation.id == id else { return }
        let healthTask = reconnectHealthTask
        healthTask?.cancel()
        _ = await healthTask?.value
        await cancelThrottleAndWait()
        guard let current = reconnectOperation, current.id == id else { return }
        let terminal = current.terminal ?? .disconnected
        reconnectOperation = nil
        reconnectHealthTask = nil
        switch terminal {
        case .connected:
            connection = .connected
        case .disconnected:
            connection = .disconnected
        case .lifecycleCancelled:
            break
        }
        await refreshSnapshot()
        for waiter in current.waiters.values {
            await waiter.finish()
        }
        await current.completion.finish()
    }

    private func resumeLastAppliedWaiters() {
        guard let lastApplied else { return }
        let ready = lastAppliedWaiters.filter { $0.0 == lastApplied }
        lastAppliedWaiters.removeAll { $0.0 == lastApplied }
        for waiter in ready { waiter.1.resume() }
    }

    private func resumeConnectionWaiters() {
        let ready = connectionWaiters.filter { $0.0 == connection }
        connectionWaiters.removeAll { $0.0 == connection }
        for waiter in ready { waiter.1.resume() }
    }

    private func cancelReconnectWaiter(operationID: UUID, waiterID: UUID) async {
        guard var operation = reconnectOperation,
              operation.id == operationID,
              let waiter = operation.waiters.removeValue(forKey: waiterID) else { return }
        reconnectOperation = operation
        if blockNextReconnectWaiterFinish {
            blockNextReconnectWaiterFinish = false
            await reconnectWaiterFinishBlocked.finish()
            await reconnectWaiterFinishRelease.wait()
        }
        await waiter.finish()
        guard reconnectOperation?.id == operationID,
              reconnectOperation?.waiters.isEmpty == true else { return }
        await cancelReconnectAndWait(id: operationID)
    }

    private func cancelReconnectAndWait() async {
        guard let id = reconnectOperation?.id else { return }
        await cancelReconnectAndWait(id: id)
    }

    private func cancelReconnectAndWait(id: UUID) async {
        guard let completion = reconnectOperation?.completion,
              reconnectOperation?.id == id else { return }
        await requestReconnectTerminal(id: id, terminal: .lifecycleCancelled)
        await completion.wait()
    }

    private func resumeReconnectWaiterCountWaiters() {
        let count = reconnectOperation?.waiters.count ?? 0
        let ready = reconnectWaiterCountWaiters.filter { count >= $0.0 }
        reconnectWaiterCountWaiters.removeAll { count >= $0.0 }
        for waiter in ready { waiter.1.resume() }
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
    }

    private func cancelThrottleAndWait() async {
        let task = throttleTask
        let id = throttleID
        task?.cancel()
        await task?.value
        if let id {
            finishThrottle(id: id)
        }
    }

    private func cancelTerminalTasks() {
        for timer in terminalTasks.values {
            timer.task.cancel()
        }
        terminalTasks.removeAll()
    }
}
