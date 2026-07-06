import Foundation
import AgentLightProtocol
@testable import AgentLightCore

enum TestLightError: Error, Sendable {
    case transient
    case permanent
}

actor ManualClock: AgentLightClock {
    private struct Sleeper {
        let id: UUID
        let deadline: Int64
        let continuation: CheckedContinuation<Void, Error>
    }

    private var nowNanoseconds: Int64 = 0
    private var sleepers: [UUID: Sleeper] = [:]
    private(set) var requestedSleeps: [Duration] = []
    private var sleepCountWaiters: [UUID: (Int, CheckedContinuation<Void, Never>)] = [:]
    private var shouldBlockNextSleepRegistration = false
    private var blockedSleepRegistration: CheckedContinuation<Void, Never>?
    private var sleepRegistrationBlockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var sleepRegistrationCompleted = false
    private var sleepRegistrationCompletedWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        let nanoseconds = duration.nanoseconds
        if shouldBlockNextSleepRegistration {
            shouldBlockNextSleepRegistration = false
            let waiters = sleepRegistrationBlockedWaiters
            sleepRegistrationBlockedWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                blockedSleepRegistration = continuation
            }
            defer {
                sleepRegistrationCompleted = true
                let waiters = sleepRegistrationCompletedWaiters
                sleepRegistrationCompletedWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
            try Task.checkCancellation()
        }
        requestedSleeps.append(duration)
        resumeSleepCountWaiters()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = Sleeper(
                    id: id,
                    deadline: nowNanoseconds + nanoseconds,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func advance(by duration: Duration) async {
        for _ in 0..<20 { await Task.yield() }
        nowNanoseconds += duration.nanoseconds
        let ready = sleepers.values.filter { $0.deadline <= nowNanoseconds }
        for sleeper in ready {
            sleepers.removeValue(forKey: sleeper.id)
            sleeper.continuation.resume()
        }
        for _ in 0..<20 { await Task.yield() }
    }

    func sleeperCount() -> Int {
        sleepers.count
    }

    func waitForSleepCount(_ count: Int) async {
        if requestedSleeps.count >= count { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            sleepCountWaiters[id] = (count, continuation)
        }
    }

    func blockNextSleepRegistration() {
        shouldBlockNextSleepRegistration = true
        sleepRegistrationCompleted = false
    }

    func waitUntilSleepRegistrationIsBlocked() async {
        if blockedSleepRegistration != nil { return }
        await withCheckedContinuation { continuation in
            sleepRegistrationBlockedWaiters.append(continuation)
        }
    }

    func releaseSleepRegistration() {
        blockedSleepRegistration?.resume()
        blockedSleepRegistration = nil
    }

    func waitUntilBlockedSleepRegistrationCompletes() async {
        if sleepRegistrationCompleted { return }
        await withCheckedContinuation { continuation in
            sleepRegistrationCompletedWaiters.append(continuation)
        }
    }

    private func cancel(id: UUID) {
        guard let sleeper = sleepers.removeValue(forKey: id) else { return }
        sleeper.continuation.resume(throwing: CancellationError())
    }


    private func resumeSleepCountWaiters() {
        let ready = sleepCountWaiters.filter { requestedSleeps.count >= $0.value.0 }
        for (id, waiter) in ready {
            sleepCountWaiters[id] = nil
            waiter.1.resume()
        }
    }
}

private extension Duration {
    var nanoseconds: Int64 {
        let components = self.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        precondition(!seconds.overflow)
        let attoseconds = components.attoseconds / 1_000_000_000
        return seconds.partialValue + attoseconds
    }
}

actor RecordingLightController: TuyaLightControlling {
    enum PhysicalPhase: Equatable, Sendable {
        case applyStarted(DesiredLightState)
        case applyFinished(DesiredLightState)
        case restoreStarted(BulbBaseline)
        case restoreFinished(BulbBaseline)
    }

    enum Operation: Equatable, Sendable {
        case capture
        case match(DesiredLightState)
        case apply(DesiredLightState)
        case restore(BulbBaseline)
    }

    private let baseline: BulbBaseline
    private var captureResults: [Result<BulbBaseline, TestLightError>]
    private var applyResults: [Result<Void, TestLightError>]
    private var restoreResults: [Result<Void, TestLightError>]
    private var matchResults: [Result<Bool, TestLightError>]
    private var blockedApply: [CheckedContinuation<Void, Never>] = []
    private var blockedRestore: [CheckedContinuation<Void, Never>] = []
    private var blockedCapture: [CheckedContinuation<Void, Never>] = []
    private var blockedMatch: [CheckedContinuation<Void, Never>] = []
    private var shouldBlockApply = false
    private var shouldBlockRestore = false
    private var shouldBlockCapture = false
    private var shouldBlockMatch = false
    private var captureErrors: [any Error] = []
    private var matchErrors: [any Error] = []
    private(set) var operations: [Operation] = []
    private(set) var physicalPhases: [PhysicalPhase] = []
    private var operationWaiters: [UUID: (Int, CheckedContinuation<Void, Never>)] = [:]

    init(
        baseline: BulbBaseline = .testBaseline,
        captureResults: [Result<BulbBaseline, TestLightError>] = [],
        applyResults: [Result<Void, TestLightError>] = [],
        restoreResults: [Result<Void, TestLightError>] = [],
        matchResults: [Result<Bool, TestLightError>] = []
    ) {
        self.baseline = baseline
        self.captureResults = captureResults
        self.applyResults = applyResults
        self.restoreResults = restoreResults
        self.matchResults = matchResults
    }

    func captureBaseline() async throws -> BulbBaseline {
        operations.append(.capture)
        resumeOperationWaiters()
        if shouldBlockCapture {
            await withCheckedContinuation { continuation in
                blockedCapture.append(continuation)
            }
        }
        if !captureErrors.isEmpty {
            throw captureErrors.removeFirst()
        }
        if !captureResults.isEmpty {
            return try captureResults.removeFirst().get()
        }
        return baseline
    }

    func apply(_ state: DesiredLightState) async throws {
        operations.append(.apply(state))
        physicalPhases.append(.applyStarted(state))
        resumeOperationWaiters()
        if shouldBlockApply {
            await withCheckedContinuation { continuation in
                blockedApply.append(continuation)
            }
        }
        if !applyResults.isEmpty {
            try applyResults.removeFirst().get()
        }
        physicalPhases.append(.applyFinished(state))
    }

    func currentStateMatches(_ state: DesiredLightState) async throws -> Bool {
        operations.append(.match(state))
        resumeOperationWaiters()
        if shouldBlockMatch {
            await withCheckedContinuation { continuation in
                blockedMatch.append(continuation)
            }
        }
        if !matchErrors.isEmpty {
            throw matchErrors.removeFirst()
        }
        if !matchResults.isEmpty {
            return try matchResults.removeFirst().get()
        }
        return true
    }

    func restore(_ baseline: BulbBaseline) async throws {
        operations.append(.restore(baseline))
        physicalPhases.append(.restoreStarted(baseline))
        resumeOperationWaiters()
        if shouldBlockRestore {
            await withCheckedContinuation { continuation in
                blockedRestore.append(continuation)
            }
        }
        if !restoreResults.isEmpty {
            try restoreResults.removeFirst().get()
        }
        physicalPhases.append(.restoreFinished(baseline))
    }

    func setApplyBlocked(_ blocked: Bool) {
        shouldBlockApply = blocked
    }

    func releaseApply() {
        shouldBlockApply = false
        let continuations = blockedApply
        blockedApply.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    func setRestoreBlocked(_ blocked: Bool) {
        shouldBlockRestore = blocked
    }

    func releaseRestore() {
        shouldBlockRestore = false
        let continuations = blockedRestore
        blockedRestore.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    func setCaptureBlocked(_ blocked: Bool) {
        shouldBlockCapture = blocked
    }

    func releaseCapture() {
        shouldBlockCapture = false
        let continuations = blockedCapture
        blockedCapture.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    func setMatchBlocked(_ blocked: Bool) {
        shouldBlockMatch = blocked
    }

    func releaseMatch() {
        shouldBlockMatch = false
        let continuations = blockedMatch
        blockedMatch.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    func enqueueCaptureErrors(_ errors: [any Error]) {
        captureErrors.append(contentsOf: errors)
    }

    func enqueueMatchErrors(_ errors: [any Error]) {
        matchErrors.append(contentsOf: errors)
    }

    func appliedStates() -> [DesiredLightState] {
        operations.compactMap {
            guard case let .apply(state) = $0 else { return nil }
            return state
        }
    }

    func restoreCount() -> Int {
        operations.filter {
            if case .restore = $0 { return true }
            return false
        }.count
    }

    func waitForOperationCount(_ count: Int) async {
        if operations.count >= count { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            operationWaiters[id] = (count, continuation)
        }
    }

    private func resumeOperationWaiters() {
        let ready = operationWaiters.filter { operations.count >= $0.value.0 }
        for (id, waiter) in ready {
            operationWaiters[id] = nil
            waiter.1.resume()
        }
    }
}

actor CompletionFlag {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func value() -> Bool {
        completed
    }
}

actor BlockingSessionCoordinator: SessionCoordinating {
    private let underlying = SessionCoordinator()
    private var shouldBlockNextAccept = false
    private var blockedAccept: CheckedContinuation<Void, Never>?
    private var acceptBlockedWaiters: [CheckedContinuation<Void, Never>] = []

    func blockNextAccept() {
        shouldBlockNextAccept = true
    }

    func releaseAccept() {
        blockedAccept?.resume()
        blockedAccept = nil
    }

    func waitUntilAcceptIsBlocked() async {
        if blockedAccept != nil { return }
        await withCheckedContinuation { continuation in
            acceptBlockedWaiters.append(continuation)
        }
    }

    func accept(_ event: AgentEvent) async {
        if shouldBlockNextAccept {
            shouldBlockNextAccept = false
            await withCheckedContinuation { continuation in
                blockedAccept = continuation
                let waiters = acceptBlockedWaiters
                acceptBlockedWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        await underlying.accept(event)
    }

    func expireTerminalState(sessionID: String, sequence: UInt64) async {
        await underlying.expireTerminalState(sessionID: sessionID, sequence: sequence)
    }

    func currentWinner() async -> AgentEvent? {
        await underlying.currentWinner()
    }

    func snapshots() async -> [AgentEvent] {
        await underlying.snapshots()
    }

    func reset() async {
        await underlying.reset()
    }
}

actor MemoryRecoveryStore: MonitoringRecoveryStoring {
    enum Operation: Equatable, Sendable {
        case load
        case save(MonitoringRecoveryRecord)
        case clear
    }

    private let revisionScope = UUID()
    private var nextRevisionGeneration: UInt64 = 0
    private var stored: StoredMonitoringRecovery?
    private var saveFailures: [TestLightError]
    private var saveFailureCalls: Set<Int>
    private var saveCallCount = 0
    private var clearFailures: [TestLightError]
    private(set) var operations: [Operation] = []
    private(set) var successfulSaveRevisions: [MonitoringRecoveryRevision] = []
    private(set) var clearExpectations: [StoredMonitoringRecovery] = []

    init(
        record: MonitoringRecoveryRecord? = nil,
        saveFailures: [TestLightError] = [],
        saveFailureCalls: Set<Int> = [],
        clearFailures: [TestLightError] = []
    ) {
        self.saveFailures = saveFailures
        self.saveFailureCalls = saveFailureCalls
        self.clearFailures = clearFailures
        if let record {
            nextRevisionGeneration = 1
            stored = StoredMonitoringRecovery(
                record: record,
                revision: MonitoringRecoveryRevision(
                    scope: revisionScope,
                    generation: nextRevisionGeneration
                )
            )
        }
    }

    func load() async throws -> StoredMonitoringRecovery? {
        operations.append(.load)
        return stored
    }

    func save(_ record: MonitoringRecoveryRecord) async throws -> MonitoringRecoveryRevision {
        operations.append(.save(record))
        saveCallCount += 1
        if saveFailureCalls.remove(saveCallCount) != nil {
            throw TestLightError.permanent
        }
        if !saveFailures.isEmpty {
            throw saveFailures.removeFirst()
        }
        nextRevisionGeneration &+= 1
        let revision = MonitoringRecoveryRevision(
            scope: revisionScope,
            generation: nextRevisionGeneration
        )
        stored = StoredMonitoringRecovery(record: record, revision: revision)
        successfulSaveRevisions.append(revision)
        return revision
    }

    func clear(expecting expected: StoredMonitoringRecovery) async throws {
        operations.append(.clear)
        clearExpectations.append(expected)
        if !clearFailures.isEmpty {
            throw clearFailures.removeFirst()
        }
        guard stored == expected else {
            throw MonitoringRecoveryStoreError.concurrentModification
        }
        stored = nil
    }

    func storedRecord() -> MonitoringRecoveryRecord? {
        stored?.record
    }

    func storedRecovery() -> StoredMonitoringRecovery? {
        stored
    }
}

extension BulbBaseline {
    static let testBaseline = BulbBaseline(values: [
        "switch_led": .bool(true),
        "work_mode": .string("white")
    ])
}

func makeEvent(
    source: AgentSource = .codex,
    session: String = "session",
    workspace: String? = nil,
    state: AgentState,
    externalSequence: UInt64 = 0
) -> AgentEvent {
    AgentEvent(
        source: source,
        sessionID: session,
        workspace: workspace,
        state: state,
        sequence: externalSequence
    )
}

func desired(_ state: AgentState) -> DesiredLightState {
    DesiredLightState(color: state.color!)
}

func eventually(
    attempts: Int = 200,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
