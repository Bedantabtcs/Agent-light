import Darwin
import Foundation
import XCTest
@testable import AgentLightCore

final class MonitoringOrchestratorTests: XCTestCase {
    func testConcurrentStartsShareOneOwnershipCaptureAndBothSucceed() async {
        let light = RecordingLightController()
        let orchestrator = makeOrchestrator(light: light)

        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        try await orchestrator.start()
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
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

        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.advance(by: .seconds(1))

        await XCTAssertAsyncTrue(await eventually {
            (await orchestrator.currentSnapshot()).connection == .disconnected
        })
        await XCTAssertAsyncEqual(await light.appliedStates(), [])
        await XCTAssertAsyncEqual(
            await store.storedRecord(),
            MonitoringRecoveryRecord(baseline: .testBaseline)
        )
    }

    func testCommittedPersistenceFailureLeavesPendingCommandRecoverable() async throws {
        let light = RecordingLightController()
        let store = MemoryRecoveryStore(saveFailureCalls: [3])
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, store: store, clock: clock)
        try await orchestrator.start()

        await orchestrator.accept(makeEvent(state: .working))
        await clock.advance(by: .seconds(1))

        await XCTAssertAsyncTrue(await eventually {
            (await orchestrator.currentSnapshot()).connection == .disconnected
        })
        await XCTAssertAsyncEqual(await light.appliedStates(), [desired(.working)])
        await XCTAssertAsyncEqual((await store.storedRecord())?.pendingCommand, desired(.working))
        await XCTAssertAsyncNil((await store.storedRecord())?.lastCommand)
    }

    func testRapidCrossAgentEventsUseLocalAcceptanceOrderAndNewestWins() async throws {
        let light = RecordingLightController()
        let clock = ManualClock()
        let orchestrator = makeOrchestrator(light: light, clock: clock)
        try await orchestrator.start()

        await orchestrator.accept(makeEvent(source: .codex, session: "a", state: .thinking, externalSequence: 999))
        await orchestrator.accept(makeEvent(source: .cursor, session: "b", state: .working, externalSequence: 1))
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
        await XCTAssertAsyncTrue(await eventually { await clock.sleeperCount() >= 1 })

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
        await XCTAssertAsyncTrue(await eventually { await clock.sleeperCount() == 2 })

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
        await XCTAssertAsyncTrue(await eventually { await clock.sleeperCount() == 2 })

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
        await clock.advance(by: .seconds(1))
        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 1 })

        let pause = Task { await orchestrator.pause() }
        await Task.yield()
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
        await clock.advance(by: .seconds(1))
        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 1 })

        let first = Task { await orchestrator.pause() }
        let second = Task { await orchestrator.pause() }
        for _ in 0..<20 { await Task.yield() }
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
        await clock.advance(by: .seconds(1))
        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 1 })

        let idle = Task {
            await orchestrator.accept(makeEvent(session: "old", state: .idle))
        }
        for _ in 0..<20 { await Task.yield() }
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
        for _ in 0..<20 { await Task.yield() }
        await orchestrator.accept(makeEvent(state: .thinking))
        await clock.advance(by: .seconds(1))
        await XCTAssertAsyncEqual(await light.appliedStates(), [])

        await light.releaseRestore()
        await pause.value
        try await resume.value
        await orchestrator.accept(makeEvent(state: .working))
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
        await XCTAssertAsyncTrue(await eventually { await light.restoreCount() == 1 })
        await clock.advance(by: .milliseconds(500))
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
        await clock.advance(by: .seconds(1))
        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 1 })
        await clock.advance(by: .milliseconds(500))
        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 2 })
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
        await clock.advance(by: .seconds(1))
        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 1 })

        await orchestrator.accept(makeEvent(state: .working))
        await clock.advance(by: .milliseconds(500))
        await clock.advance(by: .seconds(1))

        await XCTAssertAsyncTrue(await eventually { await light.appliedStates().count == 2 })
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
        await clock.advance(by: .seconds(1))
        await XCTAssertAsyncTrue(await eventually { (await orchestrator.currentSnapshot()).connection == .disconnected })
        await orchestrator.accept(makeEvent(state: .working))

        await orchestrator.reconnect()
        await clock.advance(by: .seconds(1))

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
            await Task.yield()
        }

        XCTAssertNil(weakOrchestrator)
        await XCTAssertAsyncTrue(await eventually { await clock.sleeperCount() == 0 })
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
}

final class FileMonitoringRecoveryStoreTests: XCTestCase {
    func testSaveUsesMode0600AndRoundTripsRecord() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let store = FileMonitoringRecoveryStore(url: url)
        let record = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.working))

        try await store.save(record)

        await XCTAssertAsyncEqual(try await store.load(), record)
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testReplacementLeavesCompleteDecodableRecordAndNoTemporaryFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitoring-recovery.json")
        let store = FileMonitoringRecoveryStore(url: url)
        try await store.save(MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.thinking)))
        let replacement = MonitoringRecoveryRecord(baseline: .testBaseline, lastCommand: desired(.error))

        try await store.save(replacement)

        await XCTAssertAsyncEqual(try await store.load(), replacement)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [url.lastPathComponent])
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
