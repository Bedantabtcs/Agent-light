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
        nowNanoseconds += duration.nanoseconds
        let ready = sleepers.values.filter { $0.deadline <= nowNanoseconds }
        for sleeper in ready {
            sleepers.removeValue(forKey: sleeper.id)
            sleeper.continuation.resume()
        }
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
    private var blockedCapture: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var blockedMatch: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var blockedIgnoringMatch: [CheckedContinuation<Void, Never>] = []
    private var shouldBlockApply = false
    private var shouldBlockRestore = false
    private var shouldBlockCapture = false
    private var shouldBlockMatch = false
    private var shouldIgnoreMatchCancellation = false
    private var captureErrors: [any Error] = []
    private var matchErrors: [any Error] = []
    private var captureCancellationCount = 0
    private var matchCancellationCount = 0
    private var captureCancellationWaiters: [UUID: (Int, CheckedContinuation<Void, Never>)] = [:]
    private var matchCancellationWaiters: [UUID: (Int, CheckedContinuation<Void, Never>)] = [:]
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
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    blockedCapture[id] = continuation
                }
            } onCancel: {
                Task { await self.cancelBlockedCapture(id: id) }
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
            if shouldIgnoreMatchCancellation {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        blockedIgnoringMatch.append(continuation)
                    }
                } onCancel: {
                    Task { await self.observeBlockedMatchCancellation() }
                }
            } else {
                let id = UUID()
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        blockedMatch[id] = continuation
                    }
                } onCancel: {
                    Task { await self.cancelBlockedMatch(id: id) }
                }
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
        let continuations = blockedCapture.values
        blockedCapture.removeAll()
        for continuation in continuations { continuation.resume(returning: ()) }
    }

    func setMatchBlocked(_ blocked: Bool) {
        shouldBlockMatch = blocked
    }

    func setMatchCancellationIgnored(_ ignored: Bool) {
        shouldIgnoreMatchCancellation = ignored
    }

    func releaseMatch() {
        shouldBlockMatch = false
        let continuations = blockedMatch.values
        blockedMatch.removeAll()
        for continuation in continuations { continuation.resume(returning: ()) }
        let ignoringContinuations = blockedIgnoringMatch
        blockedIgnoringMatch.removeAll()
        for continuation in ignoringContinuations { continuation.resume() }
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

    func waitForCaptureCancellationCount(_ count: Int) async {
        if captureCancellationCount >= count { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            captureCancellationWaiters[id] = (count, continuation)
        }
    }

    func waitForMatchCancellationCount(_ count: Int) async {
        if matchCancellationCount >= count { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            matchCancellationWaiters[id] = (count, continuation)
        }
    }

    func captureCancellations() -> Int {
        captureCancellationCount
    }

    func matchCancellations() -> Int {
        matchCancellationCount
    }

    private func resumeOperationWaiters() {
        let ready = operationWaiters.filter { operations.count >= $0.value.0 }
        for (id, waiter) in ready {
            operationWaiters[id] = nil
            waiter.1.resume()
        }
    }

    private func cancelBlockedCapture(id: UUID) {
        guard let continuation = blockedCapture.removeValue(forKey: id) else { return }
        captureCancellationCount += 1
        continuation.resume(throwing: CancellationError())
        resumeCancellationWaiters(
            count: captureCancellationCount,
            waiters: &captureCancellationWaiters
        )
    }

    private func cancelBlockedMatch(id: UUID) {
        guard let continuation = blockedMatch.removeValue(forKey: id) else { return }
        matchCancellationCount += 1
        continuation.resume(throwing: CancellationError())
        resumeCancellationWaiters(
            count: matchCancellationCount,
            waiters: &matchCancellationWaiters
        )
    }

    private func observeBlockedMatchCancellation() {
        matchCancellationCount += 1
        resumeCancellationWaiters(
            count: matchCancellationCount,
            waiters: &matchCancellationWaiters
        )
    }

    private func resumeCancellationWaiters(
        count: Int,
        waiters: inout [UUID: (Int, CheckedContinuation<Void, Never>)]
    ) {
        let ready = waiters.filter { count >= $0.value.0 }
        for (id, waiter) in ready {
            waiters[id] = nil
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

actor CompletionCounter {
    private var count = 0
    private var waiters: [UUID: (Int, CheckedContinuation<Void, Never>)] = [:]

    func increment() {
        count += 1
        let ready = waiters.filter { count >= $0.value.0 }
        for (id, waiter) in ready {
            waiters[id] = nil
            waiter.1.resume()
        }
    }

    func value() -> Int {
        count
    }

    func waitForCount(_ target: Int) async {
        if count >= target { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            waiters[id] = (target, continuation)
        }
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

actor SnapshotBlockingSessionCoordinator: SessionCoordinating {
    private let underlying = SessionCoordinator()
    private var callsUntilBlock: Int?
    private var blockedWinner: AgentEvent?
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    func blockCurrentWinner(afterCalls calls: Int) {
        precondition(calls > 0)
        callsUntilBlock = calls
    }

    func waitUntilCurrentWinnerIsBlocked() async {
        if blockedContinuation != nil { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func releaseCurrentWinner() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }

    func accept(_ event: AgentEvent) async {
        await underlying.accept(event)
    }

    func expireTerminalState(sessionID: String, sequence: UInt64) async {
        await underlying.expireTerminalState(sessionID: sessionID, sequence: sequence)
    }

    func currentWinner() async -> AgentEvent? {
        if let remaining = callsUntilBlock {
            if remaining == 1 {
                callsUntilBlock = nil
                blockedWinner = await underlying.currentWinner()
                let waiters = blockedWaiters
                blockedWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
                await withCheckedContinuation { continuation in
                    blockedContinuation = continuation
                }
                defer { blockedWinner = nil }
                return blockedWinner
            }
            callsUntilBlock = remaining - 1
        }
        return await underlying.currentWinner()
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
    private var blockedSaveCalls: Set<Int> = []
    private var blockedSaves: [Int: CheckedContinuation<Void, Never>] = [:]
    private var blockedSaveWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var shouldBlockNextClear = false
    private var shouldIgnoreNextClearCancellation = false
    private var blockedClear: CheckedContinuation<Void, Error>?
    private var blockedIgnoringClear: CheckedContinuation<Void, Never>?
    private var blockedClearWaiters: [CheckedContinuation<Void, Never>] = []
    private var clearCancellationCount = 0
    private var clearCancellationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
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
        let call = saveCallCount
        if blockedSaveCalls.remove(call) != nil {
            let waiters = blockedSaveWaiters.removeValue(forKey: call) ?? []
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                blockedSaves[call] = continuation
            }
        }
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
        if shouldBlockNextClear {
            shouldBlockNextClear = false
            let waiters = blockedClearWaiters
            blockedClearWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if shouldIgnoreNextClearCancellation {
                shouldIgnoreNextClearCancellation = false
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        blockedIgnoringClear = continuation
                    }
                } onCancel: {
                    Task { await self.observeBlockedClearCancellation() }
                }
                try Task.checkCancellation()
            } else {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        blockedClear = continuation
                    }
                } onCancel: {
                    Task { await self.cancelBlockedClear() }
                }
            }
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

    func blockSaveCall(_ call: Int) {
        blockedSaveCalls.insert(call)
    }

    func waitUntilSaveCallIsBlocked(_ call: Int) async {
        if blockedSaves[call] != nil { return }
        await withCheckedContinuation { continuation in
            blockedSaveWaiters[call, default: []].append(continuation)
        }
    }

    func releaseSaveCall(_ call: Int) {
        blockedSaves.removeValue(forKey: call)?.resume()
    }

    func blockNextClear() {
        shouldBlockNextClear = true
    }

    func blockNextClearIgnoringCancellation() {
        shouldBlockNextClear = true
        shouldIgnoreNextClearCancellation = true
    }

    func waitUntilClearIsBlocked() async {
        if blockedClear != nil || blockedIgnoringClear != nil { return }
        await withCheckedContinuation { continuation in
            blockedClearWaiters.append(continuation)
        }
    }

    func waitForClearCancellationCount(_ count: Int) async {
        if clearCancellationCount >= count { return }
        await withCheckedContinuation { continuation in
            clearCancellationWaiters.append((count, continuation))
        }
    }

    func releaseBlockedClear() {
        blockedIgnoringClear?.resume()
        blockedIgnoringClear = nil
    }

    private func cancelBlockedClear() {
        guard let blockedClear else { return }
        self.blockedClear = nil
        clearCancellationCount += 1
        blockedClear.resume(throwing: CancellationError())
        let ready = clearCancellationWaiters.filter { clearCancellationCount >= $0.0 }
        clearCancellationWaiters.removeAll { clearCancellationCount >= $0.0 }
        for waiter in ready { waiter.1.resume() }
    }

    private func observeBlockedClearCancellation() {
        clearCancellationCount += 1
        let ready = clearCancellationWaiters.filter { clearCancellationCount >= $0.0 }
        clearCancellationWaiters.removeAll { clearCancellationCount >= $0.0 }
        for waiter in ready { waiter.1.resume() }
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
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}
