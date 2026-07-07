import Darwin
import Foundation
import XCTest
@testable import AgentLightCore

final class MonitoringOrchestratorTests: XCTestCase {
    func testConcurrentStartsShareOneOwnershipCaptureAndBothSucceed() async {
        let light = RecordingLightController()
        await light.setCaptureBlocked(true)
        let orchestrator = makeOrchestrator(light: light)
        let first = Task { try await orchestrator.start() }
        await light.waitForOperationCount(1)
        let second = Task { try await orchestrator.start() }
        await light.releaseCapture()
        let firstResult = await first.result
        let secondResult = await second.result
        let results = [firstResult, secondResult].map { result in
            if case .success = result { return true }
            return false
        }

        XCTAssertEqual(results, [true, true])
        await XCTAssertAsyncEqual(await light.operations.filter { $0 == .capture }.count, 1)
    }

    func testStartCapturesAndPersistsBaselineBeforeFirstApply() async throws {
        let light = RecordingLightController()
        let store = MemoryRecoveryStore()
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, store: store, clock: clock)

        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))
        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 1 })

        let storeOperations = await store.operations
        let firstSave = try XCTUnwrap(storeOperations.firstSave)
        XCTAssertEqual(firstSave.baseline, .testBaseline)
        XCTAssertNil(firstSave.lastCommand)
        XCTAssertNil(firstSave.pendingCommand)
        await XCTAssertAsyncEqual(await light.operations.first, .capture)
    }

    func testInitialPersistenceFailurePreventsMonitoringAndPhysicalApply() async {
        let light = RecordingLightController()
        let store = MemoryRecoveryStore(saveFailureCalls: [1])
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, store: store, clock: clock)

        await XCTAssertThrowsErrorAsync { try await orchestrator.start() }
        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.advance(by: .seconds(5))

        await XCTAssertAsyncEqual(await light.appliedStates(), [])
        await XCTAssertAsyncNil(await store.storedRecord())
    }

    func testPendingPersistenceFailurePreventsPhysicalApply() async throws {
        let light = RecordingLightController()
        let store = MemoryRecoveryStore(saveFailureCalls: [2])
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, store: store, clock: clock)
        try await orchestrator.start()
        let baselineOwnership = await store.storedRecovery()

        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))

        await XCTAssertAsyncTrue(await eventually {
            (await orchestrator.currentSnapshot()).connection == .disconnected
        })
        await XCTAssertAsyncEqual(await light.appliedStates(), [])
        await XCTAssertAsyncEqual(
            await store.storedRecord(),
            MonitoringRecoveryRecord(baseline: .testBaseline)
        )
        await XCTAssertAsyncEqual(await store.storedRecovery(), baselineOwnership)
        await XCTAssertAsyncEqual(await store.successfulSaveRevisions.count, 1)
    }

    func testCommittedPersistenceFailureLeavesPendingCommandRecoverable() async throws {
        let light = RecordingLightController()
        let store = MemoryRecoveryStore(saveFailureCalls: [3])
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, store: store, clock: clock)
        try await orchestrator.start()

        await orchestrator.accept(makeEvent(state: .working))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))

        await XCTAssertAsyncTrue(await eventually {
            (await orchestrator.currentSnapshot()).connection == .disconnected
        })
        await XCTAssertAsyncEqual(await light.appliedStates(), [desired(.working)])
        await XCTAssertAsyncEqual((await store.storedRecord())?.pendingCommand, desired(.working))
        await XCTAssertAsyncNil((await store.storedRecord())?.lastCommand)
        let stored = await store.storedRecovery()
        let revisions = await store.successfulSaveRevisions
        XCTAssertEqual(revisions.count, 2)
        XCTAssertEqual(stored?.revision, revisions.last)
    }

    func testRapidCrossAgentEventsUseLocalAcceptanceOrderAndNewestWins() async throws {
        let light = RecordingLightController()
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()

        await orchestrator.accept(makeEvent(source: .codex, session: "a", state: .thinking, externalSequence: 999))
        await orchestrator.accept(makeEvent(source: .cursor, session: "b", state: .working, externalSequence: 1))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))

        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 1 })
        await XCTAssertAsyncEqual(await light.appliedStates(), [desired(.working)])
        let snapshot = await orchestrator.currentSnapshot()
        XCTAssertEqual(snapshot.sessions.map(\.sequence), [2, 1])
    }

    func testThrottleDoesNotApplyBeforeBoundaryAndAppliesExactlyOnceAtBoundary() async throws {
        let light = RecordingLightController()
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.waitForSleepCount(1)

        await clock.advance(by: .milliseconds(999))
        await XCTAssertAsyncEqual(await light.appliedStates(), [])
        await clock.advance(by: .milliseconds(1))
        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 1 })
        await clock.advance(by: .seconds(5))

        await XCTAssertAsyncEqual(await light.appliedStates(), [desired(.thinking)])
    }

    func testEventInsideOpenWindowReplacesPendingWinnerWithoutAnotherApply() async throws {
        let light = RecordingLightController()
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .milliseconds(999))
        await orchestrator.accept(makeEvent(state: .needsYou))
        await clock.advance(by: .milliseconds(1))

        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 1 })
        await XCTAssertAsyncEqual(await light.appliedStates(), [desired(.needsYou)])
    }

    func testCompletedExpiresEightSecondsAfterAcceptanceAndRestoresOnce() async throws {
        let light = RecordingLightController()
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .completed))
        await clock.waitForSleepCount(2)

        await clock.advance(by: .seconds(7))
        await XCTAssertAsyncEqual(await light.restoreCount(), 0)
        await clock.advance(by: .seconds(1))
        await XCTAssertAsyncTrue(await eventually { await light.restoreCount() == 1 })
        await clock.advance(by: .seconds(30))

        await XCTAssertAsyncEqual(await light.restoreCount(), 1)
        await XCTAssertAsyncEqual((await orchestrator.currentSnapshot()).state, .idle)
    }

    func testErrorExpiresTwelveSecondsAfterAcceptance() async throws {
        let light = RecordingLightController()
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .error))
        await clock.waitForSleepCount(2)

        await clock.advance(by: .seconds(11))
        await XCTAssertAsyncEqual(await light.restoreCount(), 0)
        await clock.advance(by: .seconds(1))

        await XCTAssertAsyncTrue(await eventually { await light.restoreCount() == 1 })
    }

    func testNewerSameSessionEventCancelsObsoleteTerminalExpiry() async throws {
        let light = RecordingLightController()
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .completed))
        await orchestrator.accept(makeEvent(state: .working))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(12))

        await XCTAssertAsyncEqual(await light.restoreCount(), 0)
        await XCTAssertAsyncEqual((await orchestrator.currentSnapshot()).state, .working)
    }

    func testTerminalExpiryFallsBackToCurrentOtherSessionWinner() async throws {
        let light = RecordingLightController()
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(source: .codex, session: "active", state: .working))
        await orchestrator.accept(makeEvent(source: .cursor, session: "done", state: .completed))
        await clock.waitForSleepCount(2)
        await clock.advance(by: .seconds(8))
        await XCTAssertAsyncTrue(await eventually { (await orchestrator.currentSnapshot()).state == .working })

        await XCTAssertAsyncEqual(await light.restoreCount(), 0)
    }

    func testPauseAndStopAreIdempotentAndRestoreOncePerOwnershipEpoch() async throws {
        let light = RecordingLightController()
        let orchestrator = makeOrchestrator(light: light)
        try await orchestrator.start()

        await orchestrator.pause()
        await orchestrator.pause()
        await orchestrator.stop()

        await XCTAssertAsyncEqual(await light.restoreCount(), 1)
    }

    func testPauseWaitsForInFlightApplyThenRestoresSoApplyCannotWinRace() async throws {
        let light = RecordingLightController()
        await light.setApplyBlocked(true)
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .working))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))
        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 1 })

        let pause = Task { await orchestrator.pause() }
        await orchestrator.waitForLifecycleRequestNumber(2)
        await XCTAssertAsyncEqual(await light.restoreCount(), 0)
        await light.releaseApply()
        await pause.value

        let operations = await light.operations
        XCTAssertEqual(operations.suffix(2), [.apply(desired(.working)), .restore(.testBaseline)])
    }

    func testConcurrentPausesShareInFlightDrainBeforeSingleRestore() async throws {
        let light = RecordingLightController()
        await light.setApplyBlocked(true)
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .working))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))
        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 1 })

        let first = Task { await orchestrator.pause() }
        let second = Task { await orchestrator.pause() }
        await orchestrator.waitForLifecycleRequestNumber(3)
        await XCTAssertAsyncEqual(await light.restoreCount(), 0)
        await light.releaseApply()
        await first.value
        await second.value

        await XCTAssertAsyncEqual(await light.restoreCount(), 1)
    }

    func testNewWinnerArrivingWhileIdleDrainsOldApplyPreventsRestore() async throws {
        let light = RecordingLightController()
        await light.setApplyBlocked(true)
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(session: "old", state: .working))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))
        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 1 })

        let idle = Task {
            await orchestrator.accept(makeEvent(session: "old", state: .idle))
        }
        await XCTAssertAsyncTrue(await eventually { (await orchestrator.currentSnapshot()).state == .idle })
        await orchestrator.accept(makeEvent(session: "new", state: .thinking))
        await light.releaseApply()
        await idle.value

        await XCTAssertAsyncEqual(await light.restoreCount(), 0)
        await XCTAssertAsyncEqual((await orchestrator.currentSnapshot()).state, .thinking)
    }

    func testResumeWaitsForInFlightPauseRestoreBeforeAcceptingCommands() async throws {
        let light = RecordingLightController()
        await light.setRestoreBlocked(true)
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()

        let pause = Task { await orchestrator.pause() }
        await XCTAssertAsyncTrue(await eventually { await light.restoreCount() == 1 })
        let resume = Task { try await orchestrator.resume() }
        await orchestrator.waitForLifecycleRequestNumber(3)
        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.advance(by: .seconds(1))
        await XCTAssertAsyncEqual(await light.appliedStates(), [])

        await light.releaseRestore()
        await pause.value
        try await resume.value
        await orchestrator.accept(makeEvent(state: .working))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))

        await XCTAssertAsyncTrue(await eventually { await light.appliedStates() == [desired(.working)] })
    }


    func testAcceptAfterPauseOrStopCannotScheduleCommand() async throws {
        let light = RecordingLightController()
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.pause()
        await orchestrator.accept(makeEvent(state: .thinking))
        try await orchestrator.resume()
        await orchestrator.stop()
        await orchestrator.accept(makeEvent(state: .working))
        await clock.advance(by: .seconds(20))

        await XCTAssertAsyncEqual(await light.appliedStates(), [])
    }

    func testFailedRestoreKeepsRecoveryRecordAndRepeatedPauseRetries() async throws {
        let light = RecordingLightController(restoreResults: [.failure(.transient), .failure(.transient), .failure(.transient), .success(())])
        let store = MemoryRecoveryStore()
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, store: store, clock: clock)
        try await orchestrator.start()

        let firstPause = Task { await orchestrator.pause() }
        await light.waitForOperationCount(2)
        await clock.waitForSleepCount(1)
        await clock.advance(by: .milliseconds(500))
        await clock.waitForSleepCount(2)
        await clock.advance(by: .seconds(1))
        await firstPause.value
        await XCTAssertAsyncNotNil(await store.storedRecord())

        await orchestrator.pause()
        await XCTAssertAsyncEqual(await light.restoreCount(), 4)
        await XCTAssertAsyncNil(await store.storedRecord())
    }

    func testApplyUsesThreeTotalAttemptsWithExactRetryDelays() async throws {
        let light = RecordingLightController(applyResults: [.failure(.transient), .failure(.transient), .success(())])
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))
        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 1 })
        await clock.waitForSleepCount(2)
        await clock.advance(by: .milliseconds(500))
        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 2 })
        await clock.waitForSleepCount(3)
        await clock.advance(by: .seconds(1))

        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 3 })
        await XCTAssertAsyncEqual(await clock.requestedSleeps.prefix(3), [.seconds(1), .milliseconds(500), .seconds(1)])
        await XCTAssertAsyncEqual((await orchestrator.currentSnapshot()).connection, .connected)
    }

    func testPermanentApplyFailureDoesNotRetryAndSnapshotIsSanitizedDisconnected() async throws {
        let light = RecordingLightController(applyResults: [.failure(.permanent)])
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))

        await XCTAssertAsyncTrue(await eventually { (await orchestrator.currentSnapshot()).connection == .disconnected })
        await XCTAssertAsyncEqual(await light.appliedStates().count, 1)
    }

    func testSupersededDesiredStateCancelsStaleRetry() async throws {
        let light = RecordingLightController(applyResults: [.failure(.transient), .success(())])
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))
        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 1 })

        await orchestrator.accept(makeEvent(state: .working))
        await clock.waitForSleepCount(3)
        await clock.advance(by: .seconds(1))

        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 2 })
        await XCTAssertAsyncEqual(await light.appliedStates(), [desired(.thinking), desired(.working)])
    }

    func testNewEventCancelsRetryBeforeBlockedSleepRegistration() async throws {
        let light = RecordingLightController(applyResults: [.failure(.transient), .success(())])
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.waitForSleepCount(1)
        await clock.blockNextSleepRegistration()
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(2)
        await clock.waitUntilSleepRegistrationIsBlocked()

        await orchestrator.accept(makeEvent(state: .working))
        await clock.releaseSleepRegistration()
        await clock.waitUntilBlockedSleepRegistrationCompletes()
        await clock.waitForSleepCount(2)

        await XCTAssertAsyncEqual(await clock.requestedSleeps, [.seconds(1), .seconds(1)])
        await XCTAssertAsyncEqual(await light.appliedStates(), [desired(.thinking)])
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(3)
        await XCTAssertAsyncEqual(await light.appliedStates(), [desired(.thinking), desired(.working)])
    }

    func testRecoveryMatchRestoresStoredBaselineAndClearsOnlyAfterSuccess() async throws {
        let record = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let light = RecordingLightController(matchResults: [.success(true)])
        let store = MemoryRecoveryStore(record: record)
        let orchestrator = makeOrchestrator(light: light, store: store)

        try await orchestrator.recoverIfNeeded()

        await XCTAssertAsyncEqual(await light.restoreCount(), 1)
        await XCTAssertAsyncNil(await store.storedRecord())
        await XCTAssertAsyncEqual(await store.operations.suffix(1), [.clear])
    }

    func testRecoveryRestoreFailureRetainsRecordAndIsRetryable() async throws {
        let record = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let light = RecordingLightController(restoreResults: [.failure(.permanent), .success(())], matchResults: [.success(true), .success(true)])
        let store = MemoryRecoveryStore(record: record)
        let orchestrator = makeOrchestrator(light: light, store: store)

        await XCTAssertThrowsErrorAsync { try await orchestrator.recoverIfNeeded() }
        await XCTAssertAsyncEqual(await store.storedRecord(), record)
        try await orchestrator.recoverIfNeeded()

        await XCTAssertAsyncNil(await store.storedRecord())
        await XCTAssertAsyncEqual(await light.restoreCount(), 2)
    }

    func testRecoveryMismatchCapturesExternalStateWithoutRestoringAndIsIdempotent() async throws {
        let old = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let external = BulbBaseline(values: ["switch_led": .bool(false)])
        let light = RecordingLightController(baseline: external, matchResults: [.success(false)])
        let store = MemoryRecoveryStore(record: old)
        let orchestrator = makeOrchestrator(light: light, store: store)

        try await orchestrator.recoverIfNeeded()
        try await orchestrator.recoverIfNeeded()

        await XCTAssertAsyncEqual(await light.restoreCount(), 0)
        await XCTAssertAsyncEqual(await light.operations.filter { $0 == .capture }.count, 1)
        await XCTAssertAsyncNil(await store.storedRecord())
        try await orchestrator.start()
        await XCTAssertAsyncEqual((await store.storedRecord())?.baseline, external)
    }

    func testRecoveryRecognizesPendingCommitPointAsOwnedCommand() async throws {
        let record = MonitoringRecoveryRecord(
            baseline: .testBaseline,
            lastCommand: desired(.thinking),
            pendingCommand: desired(.working)
        )
        let light = RecordingLightController(matchResults: [.success(false), .success(true)])
        let store = MemoryRecoveryStore(record: record)
        let orchestrator = makeOrchestrator(light: light, store: store)

        try await orchestrator.recoverIfNeeded()

        await XCTAssertAsyncEqual(await light.restoreCount(), 1)
        await XCTAssertAsyncNil(await store.storedRecord())
    }

    func testApplyPersistsPendingThenCommittedCommandAroundPhysicalApply() async throws {
        let light = RecordingLightController()
        let store = MemoryRecoveryStore()
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, store: store, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .working))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))
        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 1 })
        await XCTAssertAsyncTrue(await eventually { await store.operations.saveRecords.count == 3 })

        let records = await store.operations.saveRecords
        guard records.count == 3 else {
            XCTFail("Expected three persistence commit points, got \(records.count)")
            return
        }
        XCTAssertEqual(records[0], MonitoringRecoveryRecord(baseline: .testBaseline))
        XCTAssertEqual(records[1].pendingCommand, desired(.working))
        XCTAssertNil(records[1].lastCommand)
        XCTAssertEqual(records[2].lastCommand, desired(.working))
        XCTAssertNil(records[2].pendingCommand)
    }

    func testRecoveryRevisionFlowsThroughPendingCommittedAndClear() async throws {
        let light = RecordingLightController()
        let store = MemoryRecoveryStore()
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, store: store, clock: clock)

        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .working))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))
        await XCTAssertAsyncTrue(await eventually { await store.successfulSaveRevisions.count == 3 })
        await orchestrator.pause()

        let revisions = await store.successfulSaveRevisions
        let clearExpectations = await store.clearExpectations
        XCTAssertEqual(revisions.count, 3)
        XCTAssertEqual(Set(revisions).count, 3)
        XCTAssertEqual(clearExpectations.count, 1)
        XCTAssertEqual(clearExpectations.first?.revision, revisions.last)
        XCTAssertEqual(clearExpectations.first?.record.lastCommand, desired(.working))
        XCTAssertNil(clearExpectations.first?.record.pendingCommand)
    }

    func testRecoveryRetainsLoadedRevisionAcrossClearRetry() async throws {
        let record = MonitoringRecoveryRecord(
            baseline: .testBaseline,
            lastCommand: desired(.thinking)
        )
        let light = RecordingLightController(matchResults: [.success(true)])
        let store = MemoryRecoveryStore(record: record, clearFailures: [.permanent])
        let loadedValue = await store.storedRecovery()
        let loaded = try XCTUnwrap(loadedValue)
        let orchestrator = makeOrchestrator(light: light, store: store)

        await XCTAssertThrowsErrorAsync { try await orchestrator.recoverIfNeeded() }
        try await orchestrator.recoverIfNeeded()

        let clearExpectations = await store.clearExpectations
        XCTAssertEqual(clearExpectations, [loaded, loaded])
        await XCTAssertAsyncNil(await store.storedRecovery())
        await XCTAssertAsyncEqual(await light.restoreCount(), 1)
    }

    func testMultipleUpdateSubscribersReceiveInitialAndCurrentSnapshots() async throws {
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(clock: clock)
        let streamA = await orchestrator.updates()
        let streamB = await orchestrator.updates()
        var iteratorA = streamA.makeAsyncIterator()
        var iteratorB = streamB.makeAsyncIterator()

        await XCTAssertAsyncEqual(await iteratorA.next()?.state, .idle)
        await XCTAssertAsyncEqual(await iteratorB.next()?.state, .idle)
        try await orchestrator.start()
        await XCTAssertAsyncEqual(await iteratorA.next()?.state, .idle)
        await XCTAssertAsyncEqual(await iteratorB.next()?.state, .idle)
        await orchestrator.accept(makeEvent(session: "new", state: .needsYou))

        await XCTAssertAsyncEqual(await iteratorA.next()?.state, .needsYou)
        await XCTAssertAsyncEqual(await iteratorB.next()?.sessions.first?.sessionID, "new")
    }

    func testResumeAfterDisconnectedAppliesOnlyCurrentWinner() async throws {
        let light = RecordingLightController(applyResults: [.failure(.permanent), .success(())])
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))
        await XCTAssertAsyncTrue(await eventually { (await orchestrator.currentSnapshot()).connection == .disconnected })
        await orchestrator.accept(makeEvent(state: .working))

        let reconnect = Task { await orchestrator.reconnect() }
        await clock.waitForSleepCount(2)
        await clock.advance(by: .seconds(1))
        await clock.waitForSleepCount(3)
        await clock.advance(by: .seconds(1))
        await reconnect.value

        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 2 })
        await XCTAssertAsyncEqual(await light.appliedStates().last, desired(.working))
        await XCTAssertAsyncEqual((await orchestrator.currentSnapshot()).connection, .connected)
    }

    func testDeinitCancelsPendingThrottleAndTerminalTasks() async throws {
        let clock = ManualClock()
        var orchestrator: MonitoringOrchestrator? = makeOrchestrator(clock: clock)
        weak var weakOrchestrator = orchestrator
        try await orchestrator?.start()
        await orchestrator?.accept(makeEvent(state: .completed))
        await XCTAssertAsyncTrue(await eventually { await clock.sleeperCount() == 2 })

        orchestrator = nil
        for _ in 0..<200 where weakOrchestrator != nil {
            try? await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertNil(weakOrchestrator)
        await XCTAssertAsyncTrue(await eventually { await clock.sleeperCount() == 0 })
    }

    func testBlockedStartReleasesOrchestratorAfterDependencyUnblocks() async {
        let light = RecordingLightController()
        await light.setCaptureBlocked(true)
        var orchestrator: MonitoringOrchestrator? = makeOrchestrator(light: light)
        weak var weakOrchestrator = orchestrator
        let start = Task { [weak orchestrator] in
            try? await orchestrator?.start()
        }
        await light.waitForOperationCount(1)

        orchestrator = nil
        start.cancel()
        await light.releaseCapture()
        await start.value

        XCTAssertNil(weakOrchestrator)
    }

    func testBlockedRestoreReleasesOrchestratorAfterDependencyUnblocks() async throws {
        let light = RecordingLightController()
        var orchestrator: MonitoringOrchestrator? = makeOrchestrator(light: light)
        weak var weakOrchestrator = orchestrator
        try await orchestrator?.start()
        await light.setRestoreBlocked(true)
        let pause = Task { [weak orchestrator] in
            await orchestrator?.pause()
        }
        await light.waitForOperationCount(2)

        orchestrator = nil
        pause.cancel()
        await light.releaseRestore()
        await pause.value

        XCTAssertNil(weakOrchestrator)
    }

    func testEventAcceptedDuringRestoreWaitsThenAppliesCurrentWinner() async throws {
        let light = RecordingLightController()
        await light.setRestoreBlocked(true)
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()

        let idle = Task { await orchestrator.accept(makeEvent(session: "old", state: .idle)) }
        await XCTAssertAsyncTrue(await eventually { await light.restoreCount() == 1 })
        await orchestrator.accept(makeEvent(session: "new", state: .working))
        await clock.advance(by: .seconds(1))
        await XCTAssertAsyncEqual(await light.appliedStates(), [])

        await light.releaseRestore()
        await idle.value
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))

        await XCTAssertAsyncTrue(await eventually { await light.appliedStates() == [desired(.working)] })
        await XCTAssertAsyncEqual((await orchestrator.currentSnapshot()).state, .working)
    }

    func testResumeDuringPauseDrainCannotBeOvertakenByOlderDeactivate() async throws {
        let light = RecordingLightController()
        await light.setApplyBlocked(true)
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(2)

        let pause = Task { await orchestrator.pause() }
        await orchestrator.waitForLifecycleRequestNumber(2)
        let resumed = CompletionFlag()
        let resume = Task {
            try await orchestrator.resume()
            await resumed.markCompleted()
        }
        await orchestrator.waitForLifecycleRequestNumber(3)
        await XCTAssertAsyncEqual(await resumed.value(), false)

        await light.releaseApply()
        await pause.value
        try await resume.value
        let restoreCountAtActivation = await light.restoreCount()
        await orchestrator.accept(makeEvent(session: "latest", state: .working))
        await clock.advance(by: .seconds(1))

        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().last == desired(.working) })
        await XCTAssertAsyncEqual(await light.restoreCount(), restoreCountAtActivation)
        await XCTAssertAsyncEqual((await orchestrator.currentSnapshot()).state, .working)
    }

    func testLatestResumeWinsWhileInitialStartCaptureIsSuspended() async throws {
        let light = RecordingLightController()
        await light.setCaptureBlocked(true)
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        let initialStart = Task { try? await orchestrator.start() }
        await light.waitForOperationCount(1)

        let pause = Task { await orchestrator.pause() }
        await XCTAssertAsyncTrue(await eventually {
            await orchestrator.lifecycleRequestNumber() >= 2
        })
        let resume = Task { try await orchestrator.resume() }
        await light.releaseCapture()
        _ = await initialStart.value
        await pause.value
        try await resume.value
        await orchestrator.accept(makeEvent(state: .needsYou))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))

        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().last == desired(.needsYou) })
        await XCTAssertAsyncEqual((await orchestrator.currentSnapshot()).state, .needsYou)
    }

    func testClearFailureRetriesClearWithoutRepeatingPhysicalRestore() async throws {
        let light = RecordingLightController()
        let store = MemoryRecoveryStore(clearFailures: [.permanent])
        let orchestrator = makeOrchestrator(light: light, store: store)
        try await orchestrator.start()

        await orchestrator.pause()
        await XCTAssertAsyncEqual(await light.restoreCount(), 1)
        await XCTAssertAsyncNotNil(await store.storedRecord())
        await orchestrator.pause()

        await XCTAssertAsyncEqual(await light.restoreCount(), 1)
        await XCTAssertAsyncNil(await store.storedRecord())
    }

    func testReconnectRetriesPendingClearWithoutRepeatingPhysicalRestore() async throws {
        let light = RecordingLightController()
        let store = MemoryRecoveryStore(clearFailures: [.permanent])
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, store: store, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .idle))
        await XCTAssertAsyncEqual(await light.restoreCount(), 1)
        await XCTAssertAsyncEqual((await orchestrator.currentSnapshot()).connection, .disconnected)

        let reconnect = Task { await orchestrator.reconnect() }
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))
        await reconnect.value

        await XCTAssertAsyncEqual(await light.restoreCount(), 1)
        await XCTAssertAsyncNil(await store.storedRecord())
        await XCTAssertAsyncEqual((await orchestrator.currentSnapshot()).connection, .connected)
    }

    func testProductionJitterIsNonzeroBoundedAndVariesWithDeterministicSample() {
        let minimum = MonitoringOrchestrator.productionJitter(for: .milliseconds(500), sample: 0)
        let lower = MonitoringOrchestrator.productionJitter(for: .milliseconds(500), sample: 0.25)
        let upper = MonitoringOrchestrator.productionJitter(for: .milliseconds(500), sample: 0.75)
        let maximum = MonitoringOrchestrator.productionJitter(for: .milliseconds(500), sample: 1)

        XCTAssertGreaterThan(minimum, .zero)
        XCTAssertLessThanOrEqual(maximum, .milliseconds(250))
        XCTAssertNotEqual(lower, upper)
    }

    func testBaselineCaptureRetriesURLErrorWithProductionClassifier() async throws {
        let light = RecordingLightController()
        await light.enqueueCaptureErrors([URLError(.timedOut), URLError(.networkConnectionLost)])
        let clock = ManualClock()
        let orchestrator = MonitoringOrchestrator(
            light: light,
            recoveryStore: MemoryRecoveryStore(),
            clock: clock,
            jitter: { _ in .zero }
        )
        let start = Task { try await orchestrator.start() }
        await clock.waitForSleepCount(1)
        await clock.advance(by: .milliseconds(500))
        await clock.waitForSleepCount(2)
        await clock.advance(by: .seconds(1))
        try await start.value

        await XCTAssertAsyncEqual(await light.operations.filter { $0 == .capture }.count, 3)
    }

    func testPauseCancelsBaselineRetryBeforeSleepRegistration() async {
        let light = RecordingLightController()
        await light.enqueueCaptureErrors([URLError(.timedOut)])
        let clock = ManualClock()
        await clock.blockNextSleepRegistration()
        let orchestrator = MonitoringOrchestrator(
            light: light,
            recoveryStore: MemoryRecoveryStore(),
            clock: clock,
            jitter: { _ in .zero }
        )
        let start = Task { try? await orchestrator.start() }
        await light.waitForOperationCount(1)
        await clock.waitUntilSleepRegistrationIsBlocked()

        let pause = Task { await orchestrator.pause() }
        await orchestrator.waitForLifecycleRequestNumber(2)
        await clock.releaseSleepRegistration()
        await clock.waitUntilBlockedSleepRegistrationCompletes()
        _ = await start.value
        await pause.value

        await XCTAssertAsyncEqual(await clock.requestedSleeps, [])
        await XCTAssertAsyncEqual(await light.operations.captureCount, 1)
    }

    func testRecoveryMatchRetriesURLErrorWithProductionClassifier() async throws {
        let record = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let light = RecordingLightController(matchResults: [.success(true)])
        await light.enqueueMatchErrors([URLError(.cannotConnectToHost), URLError(.timedOut)])
        let clock = ManualClock()
        let orchestrator = MonitoringOrchestrator(
            light: light,
            recoveryStore: MemoryRecoveryStore(record: record),
            clock: clock,
            jitter: { _ in .zero }
        )

        let recovery = Task { try await orchestrator.recoverIfNeeded() }
        await clock.waitForSleepCount(1)
        await clock.advance(by: .milliseconds(500))
        await clock.waitForSleepCount(2)
        await clock.advance(by: .seconds(1))
        try await recovery.value

        await XCTAssertAsyncEqual(await light.operations.matchCount, 3)
    }

    func testRecoveryMismatchCaptureRetriesURLErrorWithProductionClassifier() async throws {
        let record = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let external = BulbBaseline(values: ["switch_led": .bool(false)])
        let light = RecordingLightController(
            baseline: external,
            matchResults: [.success(false)]
        )
        await light.enqueueCaptureErrors([URLError(.timedOut), URLError(.networkConnectionLost)])
        let clock = ManualClock()
        let store = MemoryRecoveryStore(record: record)
        let orchestrator = MonitoringOrchestrator(
            light: light,
            recoveryStore: store,
            clock: clock,
            jitter: { _ in .zero }
        )

        let recovery = Task { try await orchestrator.recoverIfNeeded() }
        await clock.waitForSleepCount(1)
        await clock.advance(by: .milliseconds(500))
        await clock.waitForSleepCount(2)
        await clock.advance(by: .seconds(1))
        try await recovery.value

        await XCTAssertAsyncEqual(await light.operations.captureCount, 3)
        await XCTAssertAsyncNil(await store.storedRecord())
    }

    func testOwnershipRecaptureRetriesURLErrorBeforeApplying() async throws {
        let light = RecordingLightController()
        let clock = ManualClock()
        let orchestrator = MonitoringOrchestrator(
            light: light,
            recoveryStore: MemoryRecoveryStore(),
            clock: clock,
            jitter: { _ in .zero }
        )
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .idle))
        await light.enqueueCaptureErrors([URLError(.notConnectedToInternet), URLError(.timedOut)])

        await orchestrator.accept(makeEvent(state: .working))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(3)
        await clock.waitForSleepCount(2)
        await clock.advance(by: .milliseconds(500))
        await clock.waitForSleepCount(3)
        await clock.advance(by: .seconds(1))

        await XCTAssertAsyncTrue(await eventually { await light.appliedStates() == [desired(.working)] })
        await XCTAssertAsyncEqual(await light.operations.captureCount, 4)
    }

    func testReconnectRemainsDisconnectedUntilBlockedHealthMatchSucceeds() async throws {
        let light = RecordingLightController(applyResults: [.success(()), .failure(.permanent)])
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))
        await orchestrator.waitForLastApplied(desired(.thinking))
        await orchestrator.accept(makeEvent(state: .working))
        await clock.waitForSleepCount(2)
        await clock.advance(by: .seconds(1))
        await orchestrator.waitForConnection(.disconnected)
        await XCTAssertAsyncEqual(
            await light.appliedStates(),
            [desired(.thinking), desired(.working)]
        )
        await light.setMatchBlocked(true)

        let reconnect = Task { await orchestrator.reconnect() }
        await clock.waitForSleepCount(3)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(4)
        await XCTAssertAsyncEqual((await orchestrator.currentSnapshot()).connection, .disconnected)
        await light.releaseMatch()
        await clock.waitForSleepCount(4)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(5)
        await reconnect.value

        await XCTAssertAsyncEqual((await orchestrator.currentSnapshot()).connection, .connected)
    }

    func testConcurrentReconnectsShareOneHealthOperation() async throws {
        let light = RecordingLightController(applyResults: [.success(()), .failure(.permanent)])
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(2)
        await orchestrator.accept(makeEvent(state: .working))
        await clock.waitForSleepCount(2)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(3)
        await light.setMatchBlocked(true)

        let first = Task { await orchestrator.reconnect() }
        await clock.waitForSleepCount(3)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(4)
        let second = Task { await orchestrator.reconnect() }
        await orchestrator.waitForReconnectWaiterCount(2)

        await XCTAssertAsyncEqual(await light.operations.matchCount, 1)
        await light.releaseMatch()
        await clock.waitForSleepCount(4)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(5)
        await first.value
        await second.value
    }

    func testPauseCancelsReconnectHealthDelayWithoutAdvancingClock() async throws {
        let light = RecordingLightController(applyResults: [.failure(.permanent)])
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(2)

        let reconnect = Task { await orchestrator.reconnect() }
        await clock.waitForSleepCount(2)
        await orchestrator.pause()
        await reconnect.value

        await XCTAssertAsyncEqual(await light.operations.matchCount, 0)
        await XCTAssertAsyncEqual(await clock.sleeperCount(), 0)
    }

    func testStopCancelsReconnectHealthDelayWithoutAdvancingClock() async throws {
        let setup = try await makeDisconnectedOrchestrator()
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)

        await setup.orchestrator.stop()
        await reconnect.value

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(await setup.light.operations.matchCount, 0)
        await XCTAssertAsyncEqual(await setup.clock.sleeperCount(), 0)
    }

    func testPauseDuringReconnectApplyDelayCancelsAndCompletesReconnect() async throws {
        let setup = try await makeDisconnectedOrchestrator(matchResults: [.success(false)])
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        await setup.clock.waitForSleepCount(4)

        await setup.orchestrator.pause()
        await reconnect.value

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(await setup.light.appliedStates().count, 2)
        await XCTAssertAsyncEqual(await setup.light.restoreCount(), 1)
        await XCTAssertAsyncEqual(await setup.clock.sleeperCount(), 0)
    }

    func testStopDuringReconnectApplyDelayCancelsAndCompletesReconnect() async throws {
        let setup = try await makeDisconnectedOrchestrator(matchResults: [.success(false)])
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        await setup.clock.waitForSleepCount(4)

        await setup.orchestrator.stop()
        await reconnect.value

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(await setup.light.appliedStates().count, 2)
        await XCTAssertAsyncEqual(await setup.light.restoreCount(), 1)
        await XCTAssertAsyncEqual(await setup.clock.sleeperCount(), 0)
    }

    func testReconnectNoWinnerCompletesExactlyOnce() async throws {
        let coordinator = SessionCoordinator()
        let setup = try await makeDisconnectedOrchestrator(
            matchResults: [.success(true)],
            coordinator: coordinator
        )
        await setup.light.setMatchBlocked(true)
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)

        await coordinator.reset()
        await setup.light.releaseMatch()
        await reconnect.value

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(
            (await setup.orchestrator.currentSnapshot()).connection,
            .connected
        )
    }

    func testReconnectDeduplicatedWinnerCompletesExactlyOnce() async throws {
        let coordinator = SessionCoordinator()
        let setup = try await makeDisconnectedOrchestrator(
            matchResults: [.success(true)],
            coordinator: coordinator
        )
        await setup.light.setMatchBlocked(true)
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)

        await coordinator.accept(
            makeEvent(session: "deduplicated", state: .thinking, externalSequence: 999)
        )
        await setup.light.releaseMatch()
        await reconnect.value

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(await setup.light.appliedStates().count, 2)
        await XCTAssertAsyncEqual(
            (await setup.orchestrator.currentSnapshot()).connection,
            .connected
        )
    }

    func testReconnectHealthFailureCompletesExactlyOnce() async throws {
        let setup = try await makeDisconnectedOrchestrator(
            matchResults: [.failure(.permanent)]
        )
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await reconnect.value

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(
            (await setup.orchestrator.currentSnapshot()).connection,
            .disconnected
        )
    }

    func testReconnectHealthSuccessRemainsPendingUntilCurrentWinnerApplies() async throws {
        let setup = try await makeDisconnectedOrchestrator()
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        await setup.clock.waitForSleepCount(4)

        await XCTAssertAsyncEqual(await completions.value(), 0)
        await XCTAssertAsyncEqual(
            (await setup.orchestrator.currentSnapshot()).connection,
            .disconnected
        )
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(5)
        await reconnect.value

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(await setup.light.appliedStates().last, desired(.working))
        await XCTAssertAsyncEqual(
            (await setup.orchestrator.currentSnapshot()).connection,
            .connected
        )
    }

    func testNoWinnerCancellingReconnectApplyDelayCompletesExactlyOnce() async throws {
        let setup = try await makeDisconnectedOrchestrator(matchResults: [.success(false)])
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        await setup.clock.waitForSleepCount(4)

        await setup.orchestrator.accept(makeEvent(state: .idle))
        await reconnect.value

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(await setup.light.restoreCount(), 1)
        await XCTAssertAsyncEqual(
            (await setup.orchestrator.currentSnapshot()).connection,
            .connected
        )
    }

    func testNewWinnerDuringBlockedReconnectApplyRemainsPendingUntilNewestApplies() async throws {
        let setup = try await makeDisconnectedOrchestrator(matchResults: [.success(false)])
        await setup.light.setApplyBlocked(true)
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        await setup.clock.waitForSleepCount(4)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(5)

        await setup.orchestrator.accept(makeEvent(session: "newest", state: .needsYou))
        await setup.light.releaseApply()
        await setup.clock.waitForSleepCount(5)

        await XCTAssertAsyncEqual(await completions.value(), 0)
        await XCTAssertAsyncEqual(
            (await setup.orchestrator.currentSnapshot()).connection,
            .disconnected
        )
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(6)
        await reconnect.value

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(await setup.light.appliedStates().last, desired(.needsYou))
        await XCTAssertAsyncEqual(
            (await setup.orchestrator.currentSnapshot()).connection,
            .connected
        )
    }

    func testWinnerAfterPhysicalReconnectApplyBeforeCommittedSaveKeepsReconnectPending() async throws {
        let store = MemoryRecoveryStore()
        await store.blockSaveCall(6)
        let setup = try await makeDisconnectedOrchestrator(
            matchResults: [.success(false)],
            store: store
        )
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        await setup.clock.waitForSleepCount(4)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(5)
        await store.waitUntilSaveCallIsBlocked(6)

        await setup.orchestrator.accept(makeEvent(session: "post-write", state: .needsYou))
        await store.releaseSaveCall(6)
        await setup.orchestrator.waitForLastApplied(desired(.working))
        await setup.clock.waitForSleepCount(5)

        await XCTAssertAsyncEqual(await completions.value(), 0)
        await XCTAssertAsyncEqual((await store.storedRecord())?.lastCommand, desired(.working))
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(6)
        await reconnect.value

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(await setup.light.appliedStates().last, desired(.needsYou))
        await XCTAssertAsyncEqual((await store.storedRecord())?.lastCommand, desired(.needsYou))
    }

    func testPostWriteWinnerEqualToPreviousLogicalStateIsNotDeduplicated() async throws {
        let store = MemoryRecoveryStore()
        await store.blockSaveCall(6)
        let setup = try await makeDisconnectedOrchestrator(
            matchResults: [.success(false)],
            store: store
        )
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        await setup.clock.waitForSleepCount(4)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(5)
        await store.waitUntilSaveCallIsBlocked(6)

        await setup.orchestrator.accept(makeEvent(session: "return", state: .thinking))
        await store.releaseSaveCall(6)
        await setup.orchestrator.waitForLastApplied(desired(.working))
        await setup.clock.waitForSleepCount(5)

        await XCTAssertAsyncEqual(await completions.value(), 0)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(6)
        await reconnect.value

        await XCTAssertAsyncEqual(await setup.light.appliedStates().last, desired(.thinking))
        await XCTAssertAsyncEqual((await store.storedRecord())?.lastCommand, desired(.thinking))
    }

    func testMismatchingHealthForcesApplyWhenWinnerEqualsLastApplied() async throws {
        let setup = try await makeDisconnectedOrchestrator(
            matchResults: [.success(false)]
        )
        await setup.orchestrator.accept(
            makeEvent(session: "physical-mismatch", state: .thinking)
        )

        let reconnect = Task { await setup.orchestrator.reconnect() }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        await setup.clock.waitForSleepCount(4)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(5)
        await reconnect.value

        await XCTAssertAsyncEqual(await setup.light.appliedStates().last, desired(.thinking))
        await XCTAssertAsyncEqual(
            await setup.light.appliedStates().filter { $0 == desired(.thinking) }.count,
            2
        )
    }

    func testMismatchingHealthRemainsForcedWhenAttemptIsSupersededBeforePhysicalWrite() async throws {
        let store = MemoryRecoveryStore()
        await store.blockSaveCall(5)
        let setup = try await makeDisconnectedOrchestrator(
            matchResults: [.success(false)],
            store: store
        )
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        await setup.clock.waitForSleepCount(4)
        await setup.clock.advance(by: .seconds(1))
        await store.waitUntilSaveCallIsBlocked(5)

        await setup.orchestrator.accept(makeEvent(session: "reverted", state: .thinking))
        await store.releaseSaveCall(5)
        await setup.clock.waitForSleepCount(5)

        await XCTAssertAsyncEqual(await completions.value(), 0)
        await XCTAssertAsyncEqual(await setup.light.appliedStates().count, 2)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(5)
        await reconnect.value

        await XCTAssertAsyncEqual(await setup.light.appliedStates().last, desired(.thinking))
        await XCTAssertAsyncEqual(
            await setup.light.appliedStates().filter { $0 == desired(.thinking) }.count,
            2
        )
    }

    func testNewerWinnerAcceptedWhileCurrentSnapshotIsSuspendedPreventsStalePhysicalWrite() async throws {
        let coordinator = SnapshotBlockingSessionCoordinator()
        let setup = try await makeDisconnectedOrchestrator(coordinator: coordinator)
        await coordinator.blockCurrentWinner(afterCalls: 4)
        let reconnect = Task { await setup.orchestrator.reconnect() }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        await setup.clock.waitForSleepCount(4)
        await setup.clock.advance(by: .seconds(1))
        await coordinator.waitUntilCurrentWinnerIsBlocked()

        await setup.orchestrator.accept(makeEvent(session: "newer", state: .needsYou))
        await coordinator.releaseCurrentWinner()
        await setup.clock.waitForSleepCount(5)

        await XCTAssertAsyncEqual(await setup.light.appliedStates().count, 2)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(5)
        await reconnect.value
        await XCTAssertAsyncEqual(await setup.light.appliedStates().last, desired(.needsYou))
    }

    func testPostHealthStaleNoWinnerSnapshotDoesNotConnectOverNewerAccept() async throws {
        let coordinator = SnapshotBlockingSessionCoordinator()
        let setup = try await makeDisconnectedOrchestrator(coordinator: coordinator)
        await coordinator.reset()
        await coordinator.blockCurrentWinner(afterCalls: 1)
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        await coordinator.waitUntilCurrentWinnerIsBlocked()

        await setup.orchestrator.accept(makeEvent(session: "newer", state: .needsYou))
        await coordinator.releaseCurrentWinner()
        await XCTAssertAsyncTrue(await eventually {
            let completionCount = await completions.value()
            let sleepCount = await setup.clock.sleepRequestCount()
            return completionCount > 0 || sleepCount >= 4
        })

        guard await completions.value() == 0 else {
            XCTFail("Stale no-winner snapshot connected reconnect")
            await reconnect.value
            return
        }
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(5)
        await reconnect.value
        await XCTAssertAsyncEqual(await setup.light.appliedStates().last, desired(.needsYou))
    }

    func testPostHealthStaleDedupSnapshotDoesNotConnectOverNewerAccept() async throws {
        let coordinator = SnapshotBlockingSessionCoordinator()
        let setup = try await makeDisconnectedOrchestrator(coordinator: coordinator)
        await setup.orchestrator.accept(makeEvent(session: "dedup", state: .thinking))
        await coordinator.blockCurrentWinner(afterCalls: 1)
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        await coordinator.waitUntilCurrentWinnerIsBlocked()

        await setup.orchestrator.accept(makeEvent(session: "newer", state: .needsYou))
        await coordinator.releaseCurrentWinner()
        await XCTAssertAsyncTrue(await eventually {
            let completionCount = await completions.value()
            let sleepCount = await setup.clock.sleepRequestCount()
            return completionCount > 0 || sleepCount >= 4
        })

        guard await completions.value() == 0 else {
            XCTFail("Stale dedup snapshot connected reconnect")
            await reconnect.value
            return
        }
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(5)
        await reconnect.value
        await XCTAssertAsyncEqual(await setup.light.appliedStates().last, desired(.needsYou))
    }

    func testFireThrottleStaleNoWinnerSnapshotDoesNotConnectOverNewerAccept() async throws {
        let coordinator = SnapshotBlockingSessionCoordinator()
        let setup = try await makeDisconnectedOrchestrator(coordinator: coordinator)
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        await setup.clock.waitForSleepCount(4)
        await coordinator.reset()
        await coordinator.blockCurrentWinner(afterCalls: 1)
        await setup.clock.advance(by: .seconds(1))
        await coordinator.waitUntilCurrentWinnerIsBlocked()

        await setup.orchestrator.accept(makeEvent(session: "newer", state: .needsYou))
        await coordinator.releaseCurrentWinner()
        await XCTAssertAsyncTrue(await eventually {
            let completionCount = await completions.value()
            let sleepCount = await setup.clock.sleepRequestCount()
            return completionCount > 0 || sleepCount >= 5
        })

        guard await completions.value() == 0 else {
            XCTFail("Stale throttle no-winner snapshot connected reconnect")
            await reconnect.value
            return
        }
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(5)
        await reconnect.value
        await XCTAssertAsyncEqual(await setup.light.appliedStates().last, desired(.needsYou))
    }

    func testFireThrottleStaleDedupSnapshotDoesNotConnectOverNewerAccept() async throws {
        let coordinator = SnapshotBlockingSessionCoordinator()
        let setup = try await makeDisconnectedOrchestrator(coordinator: coordinator)
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        await setup.clock.waitForSleepCount(4)
        await coordinator.accept(
            makeEvent(session: "zzzz-dedup", state: .thinking, externalSequence: 2)
        )
        await coordinator.blockCurrentWinner(afterCalls: 1)
        await setup.clock.advance(by: .seconds(1))
        await coordinator.waitUntilCurrentWinnerIsBlocked()

        await setup.orchestrator.accept(makeEvent(session: "newer", state: .needsYou))
        await coordinator.releaseCurrentWinner()
        await XCTAssertAsyncTrue(await eventually {
            let completionCount = await completions.value()
            let sleepCount = await setup.clock.sleepRequestCount()
            return completionCount > 0 || sleepCount >= 5
        })

        guard await completions.value() == 0 else {
            XCTFail("Stale throttle dedup snapshot connected reconnect")
            await reconnect.value
            return
        }
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(5)
        await reconnect.value
        await XCTAssertAsyncEqual(await setup.light.appliedStates().last, desired(.needsYou))
    }

    func testSupersessionResolverStaleNoWinnerSnapshotDoesNotDropNewerAccept() async throws {
        let coordinator = SnapshotBlockingSessionCoordinator()
        let store = MemoryRecoveryStore()
        await store.blockSaveCall(5)
        let setup = try await makeDisconnectedOrchestrator(
            matchResults: [.success(false)],
            coordinator: coordinator,
            store: store
        )
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        await setup.clock.waitForSleepCount(4)
        await setup.clock.advance(by: .seconds(1))
        await store.waitUntilSaveCallIsBlocked(5)

        await setup.orchestrator.accept(makeEvent(session: "superseding", state: .needsYou))
        await coordinator.reset()
        await coordinator.blockCurrentWinner(afterCalls: 1)
        await store.releaseSaveCall(5)
        await coordinator.waitUntilCurrentWinnerIsBlocked()
        await setup.orchestrator.accept(makeEvent(session: "newer", state: .thinking))
        await coordinator.releaseCurrentWinner()
        await XCTAssertAsyncTrue(await eventually {
            let completionCount = await completions.value()
            let sleepCount = await setup.clock.sleepRequestCount()
            return completionCount > 0 || sleepCount >= 5
        })

        guard await completions.value() == 0 else {
            XCTFail("Stale supersession snapshot connected reconnect")
            await reconnect.value
            return
        }
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(5)
        await reconnect.value
        await XCTAssertAsyncEqual(await setup.light.appliedStates().last, desired(.thinking))
    }

    func testPostHealthSnapshotRejectsTwoOverlappingInFlightAccepts() async throws {
        let coordinator = SnapshotBlockingSessionCoordinator()
        let setup = try await makeDisconnectedOrchestrator(coordinator: coordinator)
        await setup.orchestrator.accept(makeEvent(session: "dedup", state: .thinking))
        await coordinator.blockNextAccepts(2)
        let firstAccept = Task {
            await setup.orchestrator.accept(makeEvent(session: "first", state: .needsYou))
        }
        await coordinator.waitForBlockedAcceptCount(1)
        let secondAccept = Task {
            await setup.orchestrator.accept(makeEvent(session: "second", state: .working))
        }
        await coordinator.waitForBlockedAcceptCount(2)
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        await XCTAssertAsyncTrue(await eventually {
            let completionCount = await completions.value()
            let sleepCount = await setup.clock.sleepRequestCount()
            return completionCount > 0 || sleepCount >= 4
        })

        if await completions.value() > 0 {
            XCTFail("Snapshot connected while accepts remained in flight")
        }
        await coordinator.releaseBlockedAccepts()
        await firstAccept.value
        await secondAccept.value
        guard await completions.value() == 0 else {
            await reconnect.value
            return
        }
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(5)
        await reconnect.value
        await XCTAssertAsyncEqual(await setup.light.appliedStates().last, desired(.working))
    }

    func testCancellingSoleStartCallerCancelsBlockedCaptureAndNeverActivates() async {
        let light = RecordingLightController()
        await light.setCaptureBlocked(true)
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        let completions = CompletionCounter()
        let start = Task {
            try? await orchestrator.start()
            await completions.increment()
        }
        await light.waitForOperationCount(1)

        start.cancel()
        await light.waitForCaptureCancellationCount(1)
        await start.value
        await light.releaseCapture()
        await orchestrator.accept(makeEvent(state: .working))

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(await light.captureCancellations(), 1)
        await XCTAssertAsyncEqual(await light.appliedStates(), [])
        await XCTAssertAsyncEqual((await orchestrator.currentSnapshot()).state, .idle)
        await XCTAssertAsyncEqual(await clock.sleeperCount(), 0)
    }

    func testCancellingOneOfTwoStartWaitersDoesNotCancelSharedOperation() async {
        let light = RecordingLightController()
        await light.setCaptureBlocked(true)
        let orchestrator = makeOrchestrator(light: light)
        let first = Task { try await orchestrator.start() }
        await light.waitForOperationCount(1)
        let second = Task {
            do {
                try await orchestrator.start()
                return true
            } catch {
                return false
            }
        }
        await orchestrator.waitForLifecycleWaiterCount(2)

        first.cancel()
        let firstResult = await first.result
        guard case let .failure(error) = firstResult else {
            XCTFail("Expected cancelled shared start waiter to fail")
            return
        }
        XCTAssertTrue(error is CancellationError)
        await XCTAssertAsyncEqual(await light.captureCancellations(), 0)
        await XCTAssertAsyncEqual(await light.operations.captureCount, 1)
        await light.releaseCapture()
        let secondSucceeded = await second.value

        XCTAssertTrue(secondSucceeded)
        await XCTAssertAsyncEqual(await light.captureCancellations(), 0)
        await XCTAssertAsyncEqual(await light.operations.captureCount, 1)
    }

    func testNewStartDuringCancelledInitiatingStartDrainCreatesFreshRequest() async throws {
        let light = RecordingLightController()
        let store = MemoryRecoveryStore()
        await store.blockSaveCall(1)
        let orchestrator = makeOrchestrator(light: light, store: store)
        let first = Task { try await orchestrator.start() }
        await store.waitUntilSaveCallIsBlocked(1)

        first.cancel()
        await orchestrator.waitForLifecycleRequestNumber(2)
        let second = Task { try await orchestrator.start() }
        await orchestrator.waitForLifecycleRequestNumber(3)
        await store.releaseSaveCall(1)

        let firstResult = await first.result
        guard case let .failure(error) = firstResult else {
            XCTFail("Expected cancelled initiating start to fail")
            return
        }
        XCTAssertTrue(error is CancellationError)
        try await second.value
        await XCTAssertAsyncEqual(await light.operations.captureCount, 2)
    }

    func testNewStartDuringCancelledNonInitiatingFinalWaiterDrainCreatesFreshRequest() async throws {
        let light = RecordingLightController()
        let store = MemoryRecoveryStore()
        await store.blockSaveCall(1)
        let orchestrator = makeOrchestrator(light: light, store: store)
        let first = Task { try await orchestrator.start() }
        await store.waitUntilSaveCallIsBlocked(1)
        let second = Task { try await orchestrator.start() }
        await orchestrator.waitForLifecycleWaiterCount(2)

        first.cancel()
        _ = await first.result
        second.cancel()
        await orchestrator.waitForLifecycleRequestNumber(2)
        let third = Task { try await orchestrator.start() }
        await orchestrator.waitForLifecycleRequestNumber(3)
        await store.releaseSaveCall(1)

        let secondResult = await second.result
        guard case let .failure(error) = secondResult else {
            XCTFail("Expected cancelled final shared start waiter to fail")
            return
        }
        XCTAssertTrue(error is CancellationError)
        try await third.value
        await XCTAssertAsyncEqual(await light.operations.captureCount, 2)
    }

    func testCancellingSolePauseStillCompletesSafeDeactivation() async throws {
        let light = RecordingLightController()
        let store = MemoryRecoveryStore()
        await light.setRestoreBlocked(true)
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, store: store, clock: clock)
        try await orchestrator.start()
        let completions = CompletionCounter()
        let pause = Task {
            await orchestrator.pause()
            await completions.increment()
        }
        await light.waitForOperationCount(2)

        pause.cancel()
        await XCTAssertAsyncEqual(await completions.value(), 0)
        await light.releaseRestore()
        await pause.value
        await orchestrator.accept(makeEvent(state: .working))
        await clock.advance(by: .seconds(1))

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(await light.appliedStates(), [])
        await XCTAssertAsyncNil(await store.storedRecord())
        await XCTAssertAsyncEqual((await orchestrator.currentSnapshot()).state, .idle)
    }

    func testCancellingSoleStopStillCompletesSafeDeactivation() async throws {
        let light = RecordingLightController()
        let store = MemoryRecoveryStore()
        await light.setRestoreBlocked(true)
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, store: store, clock: clock)
        try await orchestrator.start()
        let completions = CompletionCounter()
        let stop = Task {
            await orchestrator.stop()
            await completions.increment()
        }
        await light.waitForOperationCount(2)

        stop.cancel()
        await XCTAssertAsyncEqual(await completions.value(), 0)
        await light.releaseRestore()
        await stop.value
        await orchestrator.accept(makeEvent(state: .needsYou))
        await clock.advance(by: .seconds(1))

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(await light.appliedStates(), [])
        await XCTAssertAsyncNil(await store.storedRecord())
        await XCTAssertAsyncEqual((await orchestrator.currentSnapshot()).state, .idle)
    }

    func testCancellingSoleReconnectWaiterCancelsHealthAndCompletesExactlyOnce() async throws {
        let setup = try await makeDisconnectedOrchestrator()
        await setup.light.setMatchBlocked(true)
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)

        reconnect.cancel()
        await setup.light.waitForMatchCancellationCount(1)
        await reconnect.value

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(await setup.light.matchCancellations(), 1)
        await XCTAssertAsyncEqual(
            (await setup.orchestrator.currentSnapshot()).connection,
            .disconnected
        )
    }

    func testCancellingOneOfTwoReconnectWaitersDoesNotCancelSharedOperation() async throws {
        let setup = try await makeDisconnectedOrchestrator()
        await setup.light.setMatchBlocked(true)
        let firstCompletions = CompletionCounter()
        let secondCompletions = CompletionCounter()
        let first = Task {
            await setup.orchestrator.reconnect()
            await firstCompletions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        let second = Task {
            await setup.orchestrator.reconnect()
            await secondCompletions.increment()
        }
        await setup.orchestrator.waitForReconnectWaiterCount(2)

        first.cancel()
        await first.value
        await XCTAssertAsyncEqual(await firstCompletions.value(), 1)
        await XCTAssertAsyncEqual(await secondCompletions.value(), 0)
        await XCTAssertAsyncEqual(await setup.light.matchCancellations(), 0)
        await setup.light.releaseMatch()
        await setup.clock.waitForSleepCount(4)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(5)
        await second.value

        await XCTAssertAsyncEqual(await firstCompletions.value(), 1)
        await XCTAssertAsyncEqual(await secondCompletions.value(), 1)
        await XCTAssertAsyncEqual(await setup.light.operations.matchCount, 1)
        await XCTAssertAsyncEqual(await setup.light.matchCancellations(), 0)
        await XCTAssertAsyncEqual(
            (await setup.orchestrator.currentSnapshot()).connection,
            .connected
        )
    }

    func testCancellingNonInitiatingReconnectWaiterDoesNotCancelSharedOperation() async throws {
        let setup = try await makeDisconnectedOrchestrator()
        await setup.light.setMatchBlocked(true)
        let firstCompletions = CompletionCounter()
        let secondCompletions = CompletionCounter()
        let first = Task {
            await setup.orchestrator.reconnect()
            await firstCompletions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        let second = Task {
            await setup.orchestrator.reconnect()
            await secondCompletions.increment()
        }
        await setup.orchestrator.waitForReconnectWaiterCount(2)

        second.cancel()
        await second.value

        await XCTAssertAsyncEqual(await secondCompletions.value(), 1)
        await XCTAssertAsyncEqual(await firstCompletions.value(), 0)
        await XCTAssertAsyncEqual(await setup.light.matchCancellations(), 0)
        await setup.light.releaseMatch()
        await setup.clock.waitForSleepCount(4)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(5)
        await first.value
        await XCTAssertAsyncEqual(await firstCompletions.value(), 1)
    }

    func testReconnectCallerAfterTerminalRequestStartsFreshOperationAfterDrain() async throws {
        let setup = try await makeDisconnectedOrchestrator()
        await setup.light.setMatchBlocked(true)
        await setup.light.setMatchCancellationIgnored(true)
        let first = Task { await setup.orchestrator.reconnect() }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)

        first.cancel()
        await setup.light.waitForMatchCancellationCount(1)
        let completions = CompletionCounter()
        let second = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }

        await XCTAssertAsyncEqual(await completions.value(), 0)
        await setup.light.releaseMatch()
        await setup.clock.waitForSleepCount(4)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(5)
        await first.value
        await setup.clock.waitForSleepCount(5)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(6)
        await second.value
        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(await setup.light.operations.matchCount, 2)
        await XCTAssertAsyncEqual((await setup.orchestrator.currentSnapshot()).connection, .connected)
    }

    func testIdleDuringBlockedReconnectHealthDrainsHealthBeforeRestore() async throws {
        let setup = try await makeDisconnectedOrchestrator()
        await setup.light.setMatchBlocked(true)
        let reconnect = Task { await setup.orchestrator.reconnect() }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)

        let idle = Task { await setup.orchestrator.accept(makeEvent(state: .idle)) }
        await setup.light.waitForMatchCancellationCount(1)
        await idle.value
        await reconnect.value

        await XCTAssertAsyncEqual(await setup.light.restoreCount(), 1)
        await XCTAssertAsyncEqual(await setup.light.matchCancellations(), 1)
    }

    func testFinalReconnectCancellationDrainsBlockedPendingClearBeforeCompleting() async throws {
        let store = MemoryRecoveryStore(clearFailures: [.permanent])
        let light = RecordingLightController()
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, store: store, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .idle))
        await store.blockNextClearIgnoringCancellation()
        let completions = CompletionCounter()
        let reconnect = Task {
            await orchestrator.reconnect()
            await completions.increment()
        }
        await store.waitUntilClearIsBlocked()

        reconnect.cancel()
        await store.waitForClearCancellationCount(1)
        await XCTAssertAsyncEqual(await completions.value(), 0)
        await XCTAssertAsyncEqual(await light.operations.matchCount, 0)
        await store.releaseBlockedClear()
        await reconnect.value

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(await light.operations.matchCount, 0)
        await XCTAssertAsyncNotNil(await store.storedRecord())
        await XCTAssertAsyncEqual((await orchestrator.currentSnapshot()).connection, .disconnected)
    }

    func testFinalReconnectCancellationDrainsBlockedHealthBeforeCompleting() async throws {
        let setup = try await makeDisconnectedOrchestrator()
        await setup.light.setMatchBlocked(true)
        await setup.light.setMatchCancellationIgnored(true)
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)

        reconnect.cancel()
        await setup.light.waitForMatchCancellationCount(1)
        await XCTAssertAsyncEqual(await completions.value(), 0)
        await setup.light.releaseMatch()
        await reconnect.value

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual((await setup.orchestrator.currentSnapshot()).connection, .disconnected)
    }

    func testFinalReconnectCancellationDuringCommandDelayDrainsBeforePauseRestore() async throws {
        let setup = try await makeDisconnectedOrchestrator(matchResults: [.success(false)])
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.blockNextSleepRegistration()
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        await setup.clock.waitUntilSleepRegistrationIsBlocked()

        reconnect.cancel()
        await XCTAssertAsyncEqual(await completions.value(), 0)
        await setup.clock.releaseSleepRegistration()
        await reconnect.value
        await setup.orchestrator.pause()

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(await setup.clock.sleeperCount(), 0)
        await XCTAssertAsyncEqual(await setup.light.restoreCount(), 1)
    }

    func testFinalReconnectCancellationDuringPhysicalApplyDrainsBeforePauseRestore() async throws {
        let setup = try await makeDisconnectedOrchestrator(matchResults: [.success(false)])
        await setup.light.setApplyBlocked(true)
        let completions = CompletionCounter()
        let reconnect = Task {
            await setup.orchestrator.reconnect()
            await completions.increment()
        }
        await setup.clock.waitForSleepCount(3)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(4)
        await setup.clock.waitForSleepCount(4)
        await setup.clock.advance(by: .seconds(1))
        await setup.light.waitForOperationCount(5)

        reconnect.cancel()
        await XCTAssertAsyncEqual(await completions.value(), 0)
        let pause = Task { await setup.orchestrator.pause() }
        await XCTAssertAsyncEqual(await setup.light.restoreCount(), 0)
        await setup.light.releaseApply()
        await reconnect.value
        await pause.value

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(
            await setup.light.physicalPhases.suffix(4),
            [
                .applyStarted(desired(.working)),
                .applyFinished(desired(.working)),
                .restoreStarted(.testBaseline),
                .restoreFinished(.testBaseline)
            ]
        )
    }

    func testReconnectDriverDoesNotRetainOrchestratorAfterFinalCancellation() async throws {
        var setup: (
            orchestrator: MonitoringOrchestrator,
            light: RecordingLightController,
            clock: ManualClock
        )? = try await makeDisconnectedOrchestrator()
        let light = try XCTUnwrap(setup?.light)
        let clock = try XCTUnwrap(setup?.clock)
        var orchestrator: MonitoringOrchestrator? = setup?.orchestrator
        setup = nil
        weak var weakOrchestrator = orchestrator
        await light.setMatchBlocked(true)
        let reconnect = Task { [weak orchestrator] in await orchestrator?.reconnect() }
        await clock.waitForSleepCount(3)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(4)

        reconnect.cancel()
        await light.waitForMatchCancellationCount(1)
        await reconnect.value
        await orchestrator?.pause()
        orchestrator = nil

        XCTAssertNil(weakOrchestrator)
    }

    func testReconnectApplyUsesThrottleAndPauseDrainsItBeforeRestore() async throws {
        let light = RecordingLightController(
            applyResults: [.success(()), .failure(.permanent), .success(())],
            matchResults: [.success(false)]
        )
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(2)
        await orchestrator.accept(makeEvent(state: .working))
        await clock.waitForSleepCount(2)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(3)
        await light.setApplyBlocked(true)

        let completions = CompletionCounter()
        let reconnect = Task {
            await orchestrator.reconnect()
            await completions.increment()
        }
        await clock.waitForSleepCount(3)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(4)
        await clock.waitForSleepCount(4)
        await XCTAssertAsyncEqual(await light.appliedStates().count, 2)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(5)
        let pause = Task { await orchestrator.pause() }
        await light.releaseApply()
        await pause.value
        await reconnect.value

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(
            await light.physicalPhases.suffix(4),
            [
                .applyStarted(desired(.working)),
                .applyFinished(desired(.working)),
                .restoreStarted(.testBaseline),
                .restoreFinished(.testBaseline)
            ]
        )
    }

    func testReconnectApplyIsDrainedBeforeStopRestores() async throws {
        let light = RecordingLightController(
            applyResults: [.success(()), .failure(.permanent), .success(())],
            matchResults: [.success(false)]
        )
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(2)
        await orchestrator.accept(makeEvent(state: .working))
        await clock.waitForSleepCount(2)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(3)
        await light.setApplyBlocked(true)

        let completions = CompletionCounter()
        let reconnect = Task {
            await orchestrator.reconnect()
            await completions.increment()
        }
        await clock.waitForSleepCount(3)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(4)
        await clock.waitForSleepCount(4)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(5)
        let stop = Task { await orchestrator.stop() }
        await light.releaseApply()
        await stop.value
        await reconnect.value

        await XCTAssertAsyncEqual(await completions.value(), 1)
        await XCTAssertAsyncEqual(
            await light.physicalPhases.suffix(4),
            [
                .applyStarted(desired(.working)),
                .applyFinished(desired(.working)),
                .restoreStarted(.testBaseline),
                .restoreFinished(.testBaseline)
            ]
        )
    }

    func testProductionClassifierDoesNotRetryGenericAPIFailure() {
        XCTAssertFalse(MonitoringOrchestrator.defaultTransientClassifier(TuyaClientError.apiFailure))
        XCTAssertTrue(MonitoringOrchestrator.defaultTransientClassifier(TuyaClientError.transport))
        XCTAssertTrue(MonitoringOrchestrator.defaultTransientClassifier(TuyaClientError.httpStatus(429)))
        XCTAssertTrue(MonitoringOrchestrator.defaultTransientClassifier(TuyaClientError.httpStatus(503)))
        XCTAssertFalse(MonitoringOrchestrator.defaultTransientClassifier(TuyaClientError.httpStatus(400)))
        XCTAssertFalse(MonitoringOrchestrator.defaultTransientClassifier(TuyaClientError.authenticationFailure))
    }

    func testOlderAcceptCannotInstallTerminalTimerAfterNewerSameSessionEvent() async throws {
        let coordinator = BlockingSessionCoordinator()
        await coordinator.blockNextAccept()
        let clock = ManualClock()
        let orchestrator = MonitoringOrchestrator(
            light: RecordingLightController(),
            recoveryStore: MemoryRecoveryStore(),
            coordinator: coordinator,
            clock: clock,
            jitter: { _ in .zero },
            isTransient: { _ in false }
        )
        try await orchestrator.start()

        let older = Task { await orchestrator.accept(makeEvent(session: "same", state: .completed)) }
        await coordinator.waitUntilAcceptIsBlocked()
        await orchestrator.accept(makeEvent(session: "same", state: .working))
        await coordinator.releaseAccept()
        await older.value

        await XCTAssertAsyncTrue(await eventually { await clock.sleeperCount() == 1 })
        await XCTAssertAsyncEqual((await orchestrator.currentSnapshot()).state, .working)
    }

    func testCancellingStreamConsumerRemovesSubscriberDeterministically() async {
        let orchestrator = makeOrchestrator()
        let stream = await orchestrator.updates()
        let consumer = Task {
            for await _ in stream {}
        }
        await XCTAssertAsyncEqual(await orchestrator.subscriberCount(), 1)

        consumer.cancel()
        await consumer.value

        await XCTAssertAsyncEqual(await orchestrator.subscriberCount(), 0)
    }

    func testMonitoringProtocolExposesReconnectAndCurrentSnapshot() async {
        let orchestrator: any MonitoringOrchestrating = makeOrchestrator()
        await orchestrator.reconnect()
        _ = await orchestrator.currentSnapshot()
    }

    private func makeOrchestrator(
        light: RecordingLightController = RecordingLightController(),
        store: MemoryRecoveryStore = MemoryRecoveryStore(),
        clock: any AgentLightClock = ManualClock()
    ) -> MonitoringOrchestrator {
        MonitoringOrchestrator(
            light: light,
            recoveryStore: store,
            clock: clock,
            jitter: { _ in .zero },
            isTransient: { ($0 as? TestLightError) == .transient }
        )
    }

    private func makeDisconnectedOrchestrator(
        matchResults: [Result<Bool, TestLightError>] = [],
        coordinator: any SessionCoordinating = SessionCoordinator(),
        store: MemoryRecoveryStore = MemoryRecoveryStore()
    ) async throws -> (
        orchestrator: MonitoringOrchestrator,
        light: RecordingLightController,
        clock: ManualClock
    ) {
        let light = RecordingLightController(
            applyResults: [.success(()), .failure(.permanent), .success(()), .success(())],
            matchResults: matchResults
        )
        let clock = ManualClock()
        let orchestrator = MonitoringOrchestrator(
            light: light,
            recoveryStore: store,
            coordinator: coordinator,
            clock: clock,
            jitter: { _ in .zero },
            isTransient: { ($0 as? TestLightError) == .transient }
        )
        try await orchestrator.start()
        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(2)
        await orchestrator.waitForLastApplied(desired(.thinking))
        await orchestrator.accept(makeEvent(state: .working))
        await clock.waitForSleepCount(2)
        await clock.advance(by: .seconds(1))
        await light.waitForOperationCount(3)
        await orchestrator.waitForConnection(.disconnected)
        return (orchestrator, light, clock)
    }
}

final class FileMonitoringRecoveryStoreTests: XCTestCase {
    func testTemporaryCleanupRetainsAuthenticatedArtifactWithoutPathUnlink() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        operations.failNextRenameExclusive = true
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let record = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let unrelatedBytes = try encoded(
            MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.error))
        )
        operations.beforeUnlink = { name in
            try replaceInode(
                at: directory.appendingPathComponent(name),
                bytes: unrelatedBytes
            )
        }

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.ioFailure) {
            _ = try await store.save(record)
        }

        XCTAssertEqual(operations.unlinkCallCount(), 0)
        let artifacts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard artifacts.count == 1 else {
            XCTFail("Expected one retained temporary artifact, got \(artifacts.count)")
            return
        }
        XCTAssertEqual(
            try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: Data(contentsOf: artifacts[0])),
            record
        )
    }

    func testCommittedSaveCleanupRetainsDisplacedArtifactWithoutPathUnlink() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let original = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let replacement = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.working))
        _ = try await store.save(original)
        let unrelatedBytes = try encoded(
            MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.error))
        )
        operations.beforeUnlink = { name in
            try replaceInode(
                at: directory.appendingPathComponent(name),
                bytes: unrelatedBytes
            )
        }

        _ = try await store.save(replacement)

        XCTAssertEqual(operations.unlinkCallCount(), 0)
        let artifacts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let records = try artifacts.map {
            try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: Data(contentsOf: $0))
        }
        guard records.count == 2 else {
            XCTFail("Expected destination and retained displaced artifact, got \(records.count)")
            return
        }
        XCTAssertTrue(records.contains(original))
        XCTAssertTrue(records.contains(replacement))
    }

    func testCommittedClearCleanupRetainsTombstoneWithoutPathUnlink() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let record = MonitoringRecoveryRecord(baseline: .testBaseline)
        let revision = try await store.save(record)
        let unrelatedBytes = try encoded(
            MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.error))
        )
        operations.beforeUnlink = { name in
            try replaceInode(
                at: directory.appendingPathComponent(name),
                bytes: unrelatedBytes
            )
        }

        try await store.clear(
            expecting: StoredMonitoringRecovery(record: record, revision: revision)
        )

        XCTAssertEqual(operations.unlinkCallCount(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let artifacts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard artifacts.count == 1 else {
            XCTFail("Expected one retained tombstone, got \(artifacts.count)")
            return
        }
        XCTAssertEqual(
            try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: Data(contentsOf: artifacts[0])),
            record
        )
    }

    func testLoadMissingDestinationInvalidatesAndClosesSiblingRevisions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let record = MonitoringRecoveryRecord(baseline: .testBaseline)
        _ = try await store.save(record)
        _ = try await store.load()
        _ = try await store.load()
        XCTAssertEqual(operations.openFileDescriptorCount(), 3)
        try FileManager.default.removeItem(at: url)

        await XCTAssertAsyncNil(try await store.load())

        XCTAssertEqual(operations.openFileDescriptorCount(), 0)
    }

    func testPinnedRevisionRejectsDifferentOpenGenerationWithReusedMetadataAndClosesHandle() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        operations.overrideRegularIdentity = MonitoringRecoveryFileIdentity(device: 7, inode: 11)
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let record = MonitoringRecoveryRecord(baseline: .testBaseline)
        let revision = try await store.save(record)
        let expected = StoredMonitoringRecovery(record: record, revision: revision)
        let bytes = try Data(contentsOf: url)

        XCTAssertEqual(operations.openFileDescriptorCount(), 1)
        XCTAssertTrue(operations.duplicatedDescriptorsAreCloseOnExec())
        try replaceInode(at: url, bytes: bytes)

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.concurrentModification) {
            try await store.clear(expecting: expected)
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(operations.openFileDescriptorCount(), 0)
    }

    func testReplacementSaveRejectsDifferentOpenGenerationWithReusedMetadata() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        operations.overrideRegularIdentity = MonitoringRecoveryFileIdentity(device: 7, inode: 11)
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let original = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        _ = try await store.save(original)
        let concurrent = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.error))
        let concurrentBytes = try encoded(concurrent)
        operations.beforeSwap = {
            try replaceInode(at: url, bytes: concurrentBytes)
        }

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.concurrentModification) {
            _ = try await store.save(
                MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.working))
            )
        }

        XCTAssertEqual(try Data(contentsOf: url), concurrentBytes)
    }

    func testFileStoreRejectsPublicRevisionItDidNotIssue() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let store = FileMonitoringRecoveryStore(url: url)
        let record = MonitoringRecoveryRecord(baseline: .testBaseline)
        _ = try await store.save(record)

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.concurrentModification) {
            try await store.clear(
                expecting: StoredMonitoringRecovery(
                    record: record,
                    revision: MonitoringRecoveryRevision()
                )
            )
        }

        await XCTAssertAsyncEqual((try await store.load())?.record, record)
    }

    func testClearingOneRevisionInvalidatesAndClosesSiblingHandles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let record = MonitoringRecoveryRecord(baseline: .testBaseline)
        let saveRevision = try await store.save(record)
        let firstLoadedValue = try await store.load()
        let firstLoaded = try XCTUnwrap(firstLoadedValue)
        let secondLoadedValue = try await store.load()
        let secondLoaded = try XCTUnwrap(secondLoadedValue)

        XCTAssertEqual(operations.openFileDescriptorCount(), 3)
        try await store.clear(expecting: firstLoaded)

        XCTAssertEqual(operations.openFileDescriptorCount(), 0)
        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.concurrentModification) {
            try await store.clear(
                expecting: StoredMonitoringRecovery(record: record, revision: saveRevision)
            )
        }
        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.concurrentModification) {
            try await store.clear(expecting: secondLoaded)
        }
    }

    func testStoreDeinitClosesPinnedRevisionDescriptors() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        var store: FileMonitoringRecoveryStore? = FileMonitoringRecoveryStore(
            url: url,
            operations: operations
        )
        _ = try await store?.save(MonitoringRecoveryRecord(baseline: .testBaseline))
        XCTAssertEqual(operations.openFileDescriptorCount(), 1)

        store = nil

        XCTAssertEqual(operations.openFileDescriptorCount(), 0)
    }

    func testPostSwapDirectorySyncFailureRollsBackAndPriorRevisionRemainsClearable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let original = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let revision = try await store.save(original)
        let expected = StoredMonitoringRecovery(record: original, revision: revision)
        let replacement = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.working))
        operations.failNextDirectorySync = true

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.ioFailure) {
            _ = try await store.save(replacement)
        }

        XCTAssertEqual(
            try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: Data(contentsOf: url)),
            original
        )
        try await store.clear(expecting: expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(operations.openFileDescriptorCount(), 0)
    }

    func testFailedPostSwapRollbackRetargetsPriorRevisionWithoutClearingReplacement() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let original = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let revision = try await store.save(original)
        let expected = StoredMonitoringRecovery(record: original, revision: revision)
        let replacement = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.working))
        operations.failNextDirectorySync = true
        operations.failSwapCalls = [2]

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.ioFailure) {
            _ = try await store.save(replacement)
        }

        XCTAssertEqual(
            try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: Data(contentsOf: url)),
            replacement
        )
        try await store.clear(expecting: expected)
        XCTAssertEqual(
            try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: Data(contentsOf: url)),
            replacement
        )
        let artifacts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let records = try artifacts.map {
            try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: Data(contentsOf: $0))
        }
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.contains(original))
        XCTAssertTrue(records.contains(replacement))
        XCTAssertEqual(operations.openFileDescriptorCount(), 0)
    }

    func testClearDoesNotDeleteUnrelatedFileThatReplacesQuarantinedGeneration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let original = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let revision = try await store.save(original)
        let expected = StoredMonitoringRecovery(record: original, revision: revision)
        let unrelated = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.error))
        let unrelatedBytes = try encoded(unrelated)
        operations.afterNextRenameExclusive = { _, destination in
            try replaceInode(
                at: directory.appendingPathComponent(destination),
                bytes: unrelatedBytes
            )
        }

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.concurrentModification) {
            try await store.clear(expecting: expected)
        }

        let artifacts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(try Data(contentsOf: artifacts[0]), unrelatedBytes)
        XCTAssertEqual(operations.openFileDescriptorCount(), 0)
    }

    func testClearRejectsByteIdenticalReplacementWithDifferentRevision() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let store = FileMonitoringRecoveryStore(url: url)
        let record = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.working))
        _ = try await store.save(record)
        let loaded = try await store.load()
        let stored = try XCTUnwrap(loaded)
        let bytes = try Data(contentsOf: url)

        try replaceInode(at: url, bytes: bytes)

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.concurrentModification) {
            try await store.clear(expecting: stored)
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: bytes), stored.record)
    }

    func testClearRejectsEarlierSaveRevisionForByteIdenticalGeneration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let store = FileMonitoringRecoveryStore(url: url)
        let record = MonitoringRecoveryRecord(baseline: .testBaseline)
        let earlierRevision = try await store.save(record)
        let currentRevision = try await store.save(record)

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.concurrentModification) {
            try await store.clear(
                expecting: StoredMonitoringRecovery(record: record, revision: earlierRevision)
            )
        }

        await XCTAssertAsyncEqual((try await store.load())?.record, record)
        try await store.clear(
            expecting: StoredMonitoringRecovery(record: record, revision: currentRevision)
        )
        await XCTAssertAsyncNil(try await store.load())
    }

    func testSaveAndLoadIssuedRevisionsClearTheirExactInstalledGenerations() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let store = FileMonitoringRecoveryStore(url: url)
        let first = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let saveRevision = try await store.save(first)

        try await store.clear(
            expecting: StoredMonitoringRecovery(record: first, revision: saveRevision)
        )
        await XCTAssertAsyncNil(try await store.load())

        let second = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.working))
        _ = try await store.save(second)
        let loadedValue = try await store.load()
        let loaded = try XCTUnwrap(loadedValue)
        try await store.clear(expecting: loaded)

        await XCTAssertAsyncNil(try await store.load())
    }

    func testFreshStoreIssuesActorScopedRevisionForOpenedGeneration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let firstStore = FileMonitoringRecoveryStore(url: url)
        let record = MonitoringRecoveryRecord(baseline: .testBaseline)
        let saveRevision = try await firstStore.save(record)
        let reopenedStore = FileMonitoringRecoveryStore(url: url)

        let reopenedValue = try await reopenedStore.load()
        let reopened = try XCTUnwrap(reopenedValue)

        XCTAssertNotEqual(reopened.revision, saveRevision)
        try await reopenedStore.clear(expecting: reopened)
        await XCTAssertAsyncNil(try await reopenedStore.load())
    }

    func testFailedSaveRetainsPriorRevisionAndCommittedSaveReturnsNewRevision() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let original = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let priorRevision = try await store.save(original)
        let replacement = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.working))
        operations.failNextFileSync = true

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.ioFailure) {
            _ = try await store.save(replacement)
        }

        try await store.clear(
            expecting: StoredMonitoringRecovery(record: original, revision: priorRevision)
        )
        let committedRevision = try await store.save(replacement)
        XCTAssertNotEqual(committedRevision, priorRevision)
        try await store.clear(
            expecting: StoredMonitoringRecovery(record: replacement, revision: committedRevision)
        )
    }

    func testSaveUsesMode0600AndRoundTripsRecord() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let store = FileMonitoringRecoveryStore(url: url)
        let record = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.working))

        try await store.save(record)

        await XCTAssertAsyncEqual((try await store.load())?.record, record)
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testReplacementRetainsCompleteDecodableDisplacedRecord() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let store = FileMonitoringRecoveryStore(url: url)
        let original = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        try await store.save(original)
        let replacement = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.error))

        try await store.save(replacement)

        await XCTAssertAsyncEqual((try await store.load())?.record, replacement)
        let artifacts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let records = try artifacts.map {
            try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: Data(contentsOf: $0))
        }
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.contains(original))
        XCTAssertTrue(records.contains(replacement))
    }

    func testSymlinkDestinationIsRejectedWithoutChangingTarget() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        try Data("unchanged".utf8).write(to: target)
        let link = directory.appendingPathComponent("monitoring-recovery.json")
        XCTAssertEqual(symlink(target.path, link.path), 0)
        let store = FileMonitoringRecoveryStore(url: link)

        await XCTAssertThrowsErrorAsync { try await store.save(MonitoringRecoveryRecord(baseline: .testBaseline)) }

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
    }

    func testLoadRejectsOversizedAndMalformedRecordsWithSanitizedErrors() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        try Data(repeating: 0x41, count: FileMonitoringRecoveryStore.maximumRecordBytes + 1).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let store = FileMonitoringRecoveryStore(url: url)

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.recordTooLarge) {
            _ = try await store.load()
        }
        try Data("not-json".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.malformedRecord) {
            _ = try await store.load()
        }
    }

    func testLoadRejectsUnsafeModeHardLinkAndDirectory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        try encoded(MonitoringRecoveryRecord(baseline: .testBaseline)).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let store = FileMonitoringRecoveryStore(url: url)
        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.unsafeFile) {
            _ = try await store.load()
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let link = directory.appendingPathComponent("hard-link")
        XCTAssertEqual(linkat(AT_FDCWD, url.path, AT_FDCWD, link.path, 0), 0)
        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.unsafeFile) {
            _ = try await store.load()
        }
        try FileManager.default.removeItem(at: link)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.unsafeFile) {
            _ = try await store.load()
        }
    }

    func testSaveDetectsDestinationReplacementAndPreservesConcurrentBytes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let original = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let concurrent = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.error))
        _ = try await store.save(original)
        let concurrentBytes = try encoded(concurrent)
        operations.beforeSwap = {
            try replaceInode(at: url, bytes: concurrentBytes)
        }

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.concurrentModification) {
            try await store.save(MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.working)))
        }

        XCTAssertEqual(try Data(contentsOf: url), concurrentBytes)
    }

    func testClearDetectsDestinationReplacementAndDoesNotDeleteConcurrentBytes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let original = MonitoringRecoveryRecord(baseline: .testBaseline)
        let originalRevision = try await store.save(original)
        let concurrent = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.error))
        let concurrentBytes = try encoded(concurrent)
        operations.beforeRenameExclusive = {
            try replaceInode(at: url, bytes: concurrentBytes)
        }

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.concurrentModification) {
            try await store.clear(
                expecting: StoredMonitoringRecovery(record: original, revision: originalRevision)
            )
        }

        XCTAssertEqual(try Data(contentsOf: url), concurrentBytes)
    }

    func testFileSyncFailureLeavesExistingRecordAndRetainsTemporaryArtifact() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let original = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let attempted = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.working))
        try await store.save(original)
        operations.failNextFileSync = true

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.ioFailure) {
            try await store.save(attempted)
        }

        await XCTAssertAsyncEqual((try await store.load())?.record, original)
        let artifacts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let records = try artifacts.map {
            try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: Data(contentsOf: $0))
        }
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.contains(original))
        XCTAssertTrue(records.contains(attempted))
    }

    func testCommittedSaveRetainsDisplacedRecoveryArtifactWithoutFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        try await store.save(MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking)))
        let replacement = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.working))
        let replacementRevision = try await store.save(replacement)

        await XCTAssertAsyncEqual((try await store.load())?.record, replacement)
        XCTAssertGreaterThan(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        try await store.clear(
            expecting: StoredMonitoringRecovery(
                record: replacement,
                revision: replacementRevision
            )
        )
    }

    func testDirectorySyncFailureAfterReplacementPreservesBothRecoveryRecords() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let original = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let replacement = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.working))
        try await store.save(original)
        operations.failNextDirectorySync = true

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.ioFailure) {
            try await store.save(replacement)
        }

        let artifacts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let records = try artifacts.map { try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: Data(contentsOf: $0)) }
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.contains(original))
        XCTAssertTrue(records.contains(replacement))
    }

    func testLoadRejectsSetIDAndStickyPermissionBits() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let record = MonitoringRecoveryRecord(baseline: .testBaseline)
        try encoded(record).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let operations = FaultInjectingRecoveryPOSIXOperations()
        operations.overrideNextRegularMode = S_IFREG | S_IRUSR | S_IWUSR | S_ISUID | S_ISGID | S_ISVTX
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.unsafeFile) {
            _ = try await store.load()
        }
    }

    func testConditionalClearCleanupFailureCannotDeleteLaterReplacement() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let original = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let replacement = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.working))
        let originalRevision = try await store.save(original)
        let expected = StoredMonitoringRecovery(record: original, revision: originalRevision)
        try await store.clear(expecting: expected)
        try await store.save(replacement)
        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.concurrentModification) {
            try await store.clear(expecting: expected)
        }

        await XCTAssertAsyncEqual((try await store.load())?.record, replacement)
    }

    func testConditionalClearDirectorySyncFailurePreservesQuarantinedRecord() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let original = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let originalRevision = try await store.save(original)
        let expected = StoredMonitoringRecovery(record: original, revision: originalRevision)
        operations.failNextDirectorySync = true

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.ioFailure) {
            try await store.clear(expecting: expected)
        }

        let artifacts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: Data(contentsOf: artifacts[0])), original)
        try await store.clear(expecting: expected)
        let retained = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(
            try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: Data(contentsOf: retained[0])),
            original
        )
    }

    func testSaveParentReplacementAfterCommitSyncPreservesDisplacedRecord() async throws {
        let parent = try temporaryDirectory()
        let movedParent = parent.appendingPathExtension("opened")
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: movedParent)
        }
        let url = parent.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let original = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let replacement = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.working))
        try await store.save(original)
        operations.afterNextDirectorySync = {
            try FileManager.default.moveItem(at: parent, to: movedParent)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        }

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.concurrentModification) {
            try await store.save(replacement)
        }

        let artifacts = try FileManager.default.contentsOfDirectory(at: movedParent, includingPropertiesForKeys: nil)
        let records = try artifacts.map { try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: Data(contentsOf: $0)) }
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.contains(original))
        XCTAssertTrue(records.contains(replacement))
    }

    func testClearParentReplacementAfterCommitSyncPreservesQuarantinedRecord() async throws {
        let parent = try temporaryDirectory()
        let movedParent = parent.appendingPathExtension("opened")
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: movedParent)
        }
        let url = parent.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let record = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let revision = try await store.save(record)
        operations.afterNextDirectorySync = {
            try FileManager.default.moveItem(at: parent, to: movedParent)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        }

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.concurrentModification) {
            try await store.clear(
                expecting: StoredMonitoringRecovery(record: record, revision: revision)
            )
        }

        let artifacts = try FileManager.default.contentsOfDirectory(at: movedParent, includingPropertiesForKeys: nil)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: Data(contentsOf: artifacts[0])), record)
    }

    func testTemporaryNameCollisionRetriesWithoutChangingCollisionFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let collisionName = ".monitoring-recovery.json.collision.tmp"
        let collision = directory.appendingPathComponent(collisionName)
        try Data("collision".utf8).write(to: collision)
        let names = LockedNameSequence([collisionName, ".monitoring-recovery.json.unique.tmp"])
        let store = FileMonitoringRecoveryStore(
            url: url,
            operations: DarwinMonitoringRecoveryPOSIXOperations(),
            temporaryName: { names.next() }
        )
        let record = MonitoringRecoveryRecord(baseline: .testBaseline)

        try await store.save(record)

        await XCTAssertAsyncEqual((try await store.load())?.record, record)
        XCTAssertEqual(try Data(contentsOf: collision), Data("collision".utf8))
    }

    func testCancelledOperationsDoNotMutateExistingRecord() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let store = FileMonitoringRecoveryStore(url: url)
        let original = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let originalRevision = try await store.save(original)
        let expected = StoredMonitoringRecovery(record: original, revision: originalRevision)

        let save = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await store.save(MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.working)))
        }
        await XCTAssertTaskIsCancelled(save)
        await XCTAssertAsyncEqual((try await store.load())?.record, original)

        let clear = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.clear(expecting: expected)
        }
        await XCTAssertTaskIsCancelled(clear)
        await XCTAssertAsyncEqual((try await store.load())?.record, original)
    }

    func testOpenedDescriptorLoadIsStableAcrossPathReplacement() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let original = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking))
        let concurrent = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.error))
        try await store.save(original)
        operations.beforeRead = {
            try replaceInode(at: url, bytes: try encoded(concurrent))
        }

        await XCTAssertAsyncEqual((try await store.load())?.record, original)
        XCTAssertEqual(try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: Data(contentsOf: url)), concurrent)
    }

    func testSaveDetectsParentReplacementAndKeepsCommittedArtifactInOpenedDirectory() async throws {
        let parent = try temporaryDirectory()
        let movedParent = parent.appendingPathExtension("opened")
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: movedParent)
        }
        let url = parent.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let replacement = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.working))
        operations.beforeRenameExclusive = {
            try FileManager.default.moveItem(at: parent, to: movedParent)
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.concurrentModification) {
            try await store.save(replacement)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let preserved = movedParent.appendingPathComponent(url.lastPathComponent)
        XCTAssertEqual(
            try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: Data(contentsOf: preserved)),
            replacement
        )
    }

    func testRenameFailureLeavesDestinationAbsentAndRetainsTemporaryArtifact() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        operations.failNextRenameExclusive = true
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let record = MonitoringRecoveryRecord(baseline: .testBaseline)

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.ioFailure) {
            try await store.save(record)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let artifacts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(
            try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: Data(contentsOf: artifacts[0])),
            record
        )
        XCTAssertEqual(operations.unlinkCallCount(), 0)
    }

    func testCommittedClearRetainsTombstoneRecoveryArtifact() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let operations = FaultInjectingRecoveryPOSIXOperations()
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)
        let record = MonitoringRecoveryRecord(baseline: .testBaseline)
        let revision = try await store.save(record)
        try await store.clear(
            expecting: StoredMonitoringRecovery(record: record, revision: revision)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let artifacts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(
            try JSONDecoder().decode(MonitoringRecoveryRecord.self, from: Data(contentsOf: artifacts[0])),
            record
        )
    }

    func testMetadataOwnerMismatchIsRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let record = MonitoringRecoveryRecord(baseline: .testBaseline)
        try encoded(record).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let operations = FaultInjectingRecoveryPOSIXOperations()
        operations.overrideNextRegularOwner = geteuid() &+ 1
        let store = FileMonitoringRecoveryStore(url: url, operations: operations)

        await XCTAssertThrowsSpecificError(MonitoringRecoveryStoreError.unsafeFile) {
            _ = try await store.load()
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

}

private extension Array where Element == MemoryRecoveryStore.Operation {
    var firstSave: MonitoringRecoveryRecord? {
        for operation in self {
            if case let .save(record) = operation { return record }
        }
        return nil
    }

    var saveRecords: [MonitoringRecoveryRecord] {
        compactMap {
            if case let .save(record) = $0 { return record }
            return nil
        }
    }
}

private extension Array where Element == RecordingLightController.Operation {
    var captureCount: Int {
        filter { $0 == .capture }.count
    }

    var matchCount: Int {
        filter {
            if case .match = $0 { return true }
            return false
        }.count
    }
}

private final class FaultInjectingRecoveryPOSIXOperations: MonitoringRecoveryPOSIXOperations, @unchecked Sendable {
    private let base = DarwinMonitoringRecoveryPOSIXOperations()
    private let lock = NSLock()
    var beforeSwap: (() throws -> Void)?
    var beforeRenameExclusive: (() throws -> Void)?
    var beforeRead: (() throws -> Void)?
    var beforeUnlink: ((String) throws -> Void)?
    var afterNextRenameExclusive: ((String, String) throws -> Void)?
    var failNextFileSync = false
    var failNextDirectorySync = false
    var failNextRenameExclusive = false
    var overrideNextRegularOwner: uid_t?
    var overrideNextRegularMode: mode_t?
    var overrideRegularIdentity: MonitoringRecoveryFileIdentity?
    var afterNextDirectorySync: (() throws -> Void)?
    var failSwapCalls: Set<Int> = []
    private var swapCallCount = 0
    private var openFileDescriptors: Set<Int32> = []
    private var openDirectoryDescriptors: Set<Int32> = []
    private var duplicateCloseOnExecValues: [Bool] = []
    private var unlinkCalls = 0

    func openDirectory(path: String) throws -> Int32 {
        let descriptor = try base.openDirectory(path: path)
        _ = locked { openDirectoryDescriptors.insert(descriptor) }
        return descriptor
    }

    func openExisting(at directory: Int32, name: String) throws -> Int32? {
        let descriptor = try base.openExisting(at: directory, name: name)
        if let descriptor {
            _ = locked { openFileDescriptors.insert(descriptor) }
        }
        return descriptor
    }

    func createExclusive(at directory: Int32, name: String, mode: mode_t) throws -> Int32 {
        let descriptor = try base.createExclusive(at: directory, name: name, mode: mode)
        _ = locked { openFileDescriptors.insert(descriptor) }
        return descriptor
    }

    func duplicate(_ descriptor: Int32) throws -> Int32 {
        let duplicate = try base.duplicate(descriptor)
        locked {
            duplicateCloseOnExecValues.append(fcntl(duplicate, F_GETFD) & FD_CLOEXEC != 0)
            if openFileDescriptors.contains(descriptor) {
                openFileDescriptors.insert(duplicate)
            } else if openDirectoryDescriptors.contains(descriptor) {
                openDirectoryDescriptors.insert(duplicate)
            }
        }
        return duplicate
    }

    func metadata(for descriptor: Int32) throws -> MonitoringRecoveryFileMetadata {
        let metadata = try base.metadata(for: descriptor)
        return locked {
            guard metadata.mode & S_IFMT == S_IFREG,
                  overrideNextRegularOwner != nil
                    || overrideNextRegularMode != nil
                    || overrideRegularIdentity != nil else {
                return metadata
            }
            let owner = overrideNextRegularOwner ?? metadata.owner
            let mode = overrideNextRegularMode ?? metadata.mode
            let identity = overrideRegularIdentity ?? metadata.identity
            overrideNextRegularOwner = nil
            overrideNextRegularMode = nil
            return MonitoringRecoveryFileMetadata(
                device: identity.device,
                inode: identity.inode,
                mode: mode,
                owner: owner,
                linkCount: metadata.linkCount
            )
        }
    }

    func sameOpenFile(_ first: Int32, _ second: Int32) throws -> Bool {
        return try base.sameOpenFile(first, second)
    }

    func read(from descriptor: Int32, maximumBytes: Int) throws -> Data {
        let hook = locked { () -> (() throws -> Void)? in
            defer { beforeRead = nil }
            return beforeRead
        }
        try hook?()
        return try base.read(from: descriptor, maximumBytes: maximumBytes)
    }

    func write(_ data: Data, to descriptor: Int32) throws {
        try base.write(data, to: descriptor)
    }

    func setMode(_ mode: mode_t, for descriptor: Int32) throws {
        try base.setMode(mode, for: descriptor)
    }

    func synchronize(_ descriptor: Int32, kind: MonitoringRecoveryDescriptorKind) throws {
        let shouldFail = locked { () -> Bool in
            if kind == .file, failNextFileSync {
                failNextFileSync = false
                return true
            }
            if kind == .directory, failNextDirectorySync {
                failNextDirectorySync = false
                return true
            }
            return false
        }
        if shouldFail { throw MonitoringRecoveryPOSIXError.system(EIO) }
        try base.synchronize(descriptor, kind: kind)
        if kind == .directory {
            let hook = locked { () -> (() throws -> Void)? in
                defer { afterNextDirectorySync = nil }
                return afterNextDirectorySync
            }
            try hook?()
        }
    }

    func swap(at directory: Int32, _ first: String, _ second: String) throws {
        let hook = locked { () -> (() throws -> Void)? in
            defer { beforeSwap = nil }
            return beforeSwap
        }
        try hook?()
        let shouldFail = locked { () -> Bool in
            swapCallCount += 1
            return failSwapCalls.remove(swapCallCount) != nil
        }
        if shouldFail { throw MonitoringRecoveryPOSIXError.system(EIO) }
        try base.swap(at: directory, first, second)
    }

    func renameExclusive(at directory: Int32, from: String, to: String) throws {
        let hook = locked { () -> (() throws -> Void)? in
            defer { beforeRenameExclusive = nil }
            return beforeRenameExclusive
        }
        try hook?()
        let shouldFail = locked {
            guard failNextRenameExclusive else { return false }
            failNextRenameExclusive = false
            return true
        }
        if shouldFail { throw MonitoringRecoveryPOSIXError.system(EIO) }
        try base.renameExclusive(at: directory, from: from, to: to)
        let afterHook = locked { () -> ((String, String) throws -> Void)? in
            defer { afterNextRenameExclusive = nil }
            return afterNextRenameExclusive
        }
        try afterHook?(from, to)
    }

    func close(_ descriptor: Int32) {
        locked {
            openFileDescriptors.remove(descriptor)
            openDirectoryDescriptors.remove(descriptor)
        }
        base.close(descriptor)
    }

    func openFileDescriptorCount() -> Int {
        locked { openFileDescriptors.count }
    }

    func duplicatedDescriptorsAreCloseOnExec() -> Bool {
        locked {
            !duplicateCloseOnExecValues.isEmpty && duplicateCloseOnExecValues.allSatisfy { $0 }
        }
    }

    func unlinkCallCount() -> Int {
        locked { unlinkCalls }
    }

    func unlink(at directory: Int32, name: String) throws {
        let hook = locked { () -> ((String) throws -> Void)? in
            unlinkCalls += 1
            return beforeUnlink
        }
        try hook?(name)
        guard Darwin.unlinkat(directory, name, 0) == 0 else {
            throw MonitoringRecoveryPOSIXError.system(errno)
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class LockedNameSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String]

    init(_ names: [String]) {
        self.names = names
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return names.isEmpty ? ".fallback.tmp" : names.removeFirst()
    }
}

private func replaceInode(at url: URL, bytes: Data) throws {
    let replacement = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try bytes.write(to: replacement)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replacement.path)
    guard rename(replacement.path, url.path) == 0 else {
        throw MonitoringRecoveryStoreError.ioFailure
    }
}

private func encoded(_ record: MonitoringRecoveryRecord) throws -> Data {
    try JSONEncoder().encode(record)
}

private func XCTAssertThrowsSpecificError<E: Error & Equatable>(
    _ expected: E,
    _ expression: @escaping @Sendable () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as E {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error type", file: file, line: line)
    }
}

private func XCTAssertTaskIsCancelled(
    _ task: Task<Void, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await task.value
        XCTFail("Expected cancellation", file: file, line: line)
    } catch is CancellationError {
    } catch {
        XCTFail("Unexpected error type", file: file, line: line)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping @Sendable () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}

private func XCTAssertAsyncEqual<T: Equatable>(
    _ actual: @autoclosure () async throws -> T,
    _ expected: @autoclosure () throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        let resolvedActual = try await actual()
        let resolvedExpected = try expected()
        if resolvedActual != resolvedExpected {
            XCTFail("Expected \(resolvedExpected), got \(resolvedActual)", file: file, line: line)
        }
    } catch {
        XCTFail("Unexpected error", file: file, line: line)
    }
}

private func XCTAssertAsyncTrue(
    _ expression: @autoclosure () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    if !(await expression()) {
        XCTFail("Expected true", file: file, line: line)
    }
}

private func XCTAssertAsyncNil<T>(
    _ expression: @autoclosure () async throws -> T?,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        if try await expression() != nil {
            XCTFail("Expected nil", file: file, line: line)
        }
    } catch {
        XCTFail("Unexpected error", file: file, line: line)
    }
}

private func XCTAssertAsyncNotNil<T>(
    _ expression: @autoclosure () async throws -> T?,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        if try await expression() == nil {
            XCTFail("Expected non-nil value", file: file, line: line)
        }
    } catch {
        XCTFail("Unexpected error", file: file, line: line)
    }
}
