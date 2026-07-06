# Task 8 Lifecycle and Recovery Correction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Task 8's distributed reconnect latches and value-only recovery clearing with one lifecycle-owned reconnect operation and exact stored-generation compare-and-swap.

**Architecture:** The recovery store returns an opaque revision with every loaded or saved record, and clear requires that exact revision. The orchestrator owns one reconnect operation with a monotonic ID, explicit waiters, one terminal resolver, and caller-aware cancellation; superseded applies remain inside the same reconnect operation until the current winner applies or lifecycle cancellation terminates it.

**Tech Stack:** Swift 6.2, Swift concurrency actors/tasks, XCTest, Foundation, Darwin descriptor-relative filesystem APIs, macOS 14+.

## Global Constraints

- Do not push to GitHub.
- Do not hardcode credentials, tokens, device IDs, passwords, or agent content.
- No debug logs, forced casts, forced tries, dynamic evaluation, or commented-out code.
- Preserve the one-second command window, Completed hold of 8 seconds, and Error hold of 12 seconds.
- Pause and stop must drain all light-changing work before restoring the baseline.
- Recovery files must be owner-only exact mode `0600`, descriptor-relative, bounded to 64 KiB, and symlink-safe.
- Every behavior change must follow RED, GREEN, refactor with deterministic barriers rather than `Task.yield()` timing.

---

### Task 1: Versioned Recovery Store CAS

**Files:**
- Modify: `Sources/AgentLightCore/Persistence/MonitoringRecoveryStore.swift`
- Modify: `Sources/AgentLightCore/Coordination/MonitoringOrchestrator.swift`
- Modify: `Tests/AgentLightCoreTests/MonitoringOrchestratorTests.swift`
- Modify: `Tests/AgentLightCoreTests/Support/TestDoubles.swift`

**Interfaces:**
- Produces: `MonitoringRecoveryRevision`, `StoredMonitoringRecovery`, `save(_:) -> MonitoringRecoveryRevision`, `clear(expecting:)`.
- Consumes: existing `MonitoringRecoveryRecord`, descriptor-relative file identity, and recovery-store POSIX seam.

- [ ] **Step 1: Add failing identical-replacement and revision-flow tests**

Add tests that load or save a record, replace the file with byte-identical content on a different inode, and assert conditional clear throws `concurrentModification` without deleting the replacement. Add memory-store tests proving orchestrator save/load/clear carries the same revision through baseline ownership, pending command, committed command, clear-pending retry, and recovery.

```swift
func testClearRejectsByteIdenticalReplacementWithDifferentRevision() async throws {
    let stored = try await store.load()
    try replaceWithByteIdenticalNewInode(recordURL)

    await XCTAssertThrowsErrorAsync(
        try await store.clear(expecting: try XCTUnwrap(stored))
    ) { error in
        XCTAssertEqual(error as? MonitoringRecoveryStoreError, .concurrentModification)
    }
    XCTAssertEqual(try decodeRecord(recordURL), stored?.record)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```sh
swift test --filter 'FileMonitoringRecoveryStoreTests/testClearRejectsByteIdenticalReplacementWithDifferentRevision|MonitoringOrchestratorTests/testRecoveryRevisionFlowsThroughPendingCommittedAndClear'
```

Expected: compilation fails because the store returns only record values and clear accepts only `MonitoringRecoveryRecord`.

- [ ] **Step 3: Introduce opaque revisions and versioned store results**

Use public value types that expose equality but not filesystem fields:

```swift
public struct MonitoringRecoveryRevision: Hashable, Sendable {
    fileprivate let rawValue: UUID
}

public struct StoredMonitoringRecovery: Equatable, Sendable {
    public let record: MonitoringRecoveryRecord
    public let revision: MonitoringRecoveryRevision
}

public protocol MonitoringRecoveryStoring: Sendable {
    func load() async throws -> StoredMonitoringRecovery?
    @discardableResult
    func save(_ record: MonitoringRecoveryRecord) async throws -> MonitoringRecoveryRevision
    func clear(expecting stored: StoredMonitoringRecovery) async throws
}
```

The file store binds each returned revision to the exact installed `(device, inode)` in actor-isolated revision state. `load()` records the opened descriptor identity. `save()` records the final installed destination identity after directory sync and parent verification. `clear(expecting:)` rejects a revision not issued for the expected identity, then atomically quarantines and verifies that exact inode before the clear commit. A new byte-identical inode must fail.

The memory store uses a monotonically changing revision on every save and replacement. The orchestrator stores `StoredMonitoringRecovery`, replacing its revision after every save and retaining it across clear-pending retries.

- [ ] **Step 4: Test durable clear and revision behavior**

Run:

```sh
swift test --filter FileMonitoringRecoveryStoreTests
swift test --filter 'MonitoringOrchestratorTests/(testRecoveryMatchRestoresStoredBaselineAndClearsOnlyAfterSuccess|testClearFailureRetriesClearWithoutRepeatingPhysicalRestore|testCommittedPersistenceFailureLeavesPendingCommandRecoverable)'
```

Expected: identical replacements survive, pre-commit failures retain the exact revision and artifact, cleanup failures remain committed success, and orchestrator clear retries never target a later generation.

- [ ] **Step 5: Commit Task 1 locally**

```sh
git add Sources/AgentLightCore/Persistence/MonitoringRecoveryStore.swift Sources/AgentLightCore/Coordination/MonitoringOrchestrator.swift Tests/AgentLightCoreTests/MonitoringOrchestratorTests.swift Tests/AgentLightCoreTests/Support/TestDoubles.swift
git commit -m "fix: version monitoring recovery ownership"
```

---

### Task 2: Unified Reconnect and Caller Cancellation

**Files:**
- Modify: `Sources/AgentLightCore/Coordination/MonitoringOrchestrator.swift`
- Modify: `Tests/AgentLightCoreTests/MonitoringOrchestratorTests.swift`
- Modify: `Tests/AgentLightCoreTests/Support/TestDoubles.swift`

**Interfaces:**
- Consumes: versioned recovery ownership from Task 1, `MonitoringOrchestrating`, `TuyaLightControlling`, and `AgentLightClock`.
- Produces: lifecycle-owned reconnect state with centralized resolution and caller-aware transition waiting; no public API change to `MonitoringOrchestrating`.

- [ ] **Step 1: Add failing reconnect terminal-path tests**

Add these barrier-controlled tests:

```swift
func testPauseDuringReconnectApplyDelayCancelsAndCompletesReconnect() async throws
func testStopDuringReconnectApplyDelayCancelsAndCompletesReconnect() async throws
func testReconnectNoWinnerCompletesExactlyOnce() async throws
func testReconnectDeduplicatedWinnerCompletesExactlyOnce() async throws
func testNewWinnerDuringBlockedReconnectApplyRemainsPendingUntilNewestApplies() async throws
func testCancellingSoleStartCallerCancelsBlockedCaptureAndNeverActivates() async throws
func testCancellingOneOfTwoReconnectWaitersDoesNotCancelSharedOperation() async throws
```

Each test waits on operation, clock-sleeper, or light-controller barriers before cancellation or clock advancement. Wrap critical tests in a five-second external bound; no direct `Task.yield()` may establish ordering.

- [ ] **Step 2: Run the new tests and verify RED**

Run:

```sh
swift test --filter 'MonitoringOrchestratorTests/(testPauseDuringReconnectApplyDelayCancelsAndCompletesReconnect|testStopDuringReconnectApplyDelayCancelsAndCompletesReconnect|testReconnectNoWinnerCompletesExactlyOnce|testReconnectDeduplicatedWinnerCompletesExactlyOnce|testNewWinnerDuringBlockedReconnectApplyRemainsPendingUntilNewestApplies|testCancellingSoleStartCallerCancelsBlockedCaptureAndNeverActivates|testCancellingOneOfTwoReconnectWaitersDoesNotCancelSharedOperation)'
```

Expected: pause or stop hangs during the reconnect delay, supersession completes reconnect too early or loses the newest winner, and caller cancellation does not cancel sole lifecycle work.

- [ ] **Step 3: Replace distributed reconnect latches with one state**

Use one actor-isolated operation:

```swift
private struct ReconnectOperation: Sendable {
    enum Phase: Sendable { case health, commandWindow, applying }
    let id: UUID
    var phase: Phase
    var waiterIDs: Set<UUID>
    let completion: MonitoringOperationCompletion
}

private enum ReconnectTerminal: Sendable {
    case connected
    case disconnected
    case lifecycleCancelled
}
```

All health, throttle, apply, no-winner, deduplication, failure, and cancellation paths call one `finishReconnect(id:terminal:)`. It verifies the operation ID, publishes the terminal connection state, clears reconnect state, and finishes the completion exactly once.

Superseded apply is not terminal. Keep the reconnect operation and disconnected state, update its phase to `commandWindow`, and schedule the current winner while disconnected. Complete only after the current winner applies, no current winner remains, or lifecycle cancellation explicitly drains the operation.

`cancelThrottleAndWait()` owns throttle completion directly; it cannot clear the throttle ID before the cancelled task resolves. Guard exits in `fireThrottle` use the same throttle terminal helper.

- [ ] **Step 4: Tie lifecycle work to caller waiters**

Wrap public lifecycle waits in cancellation handlers:

```swift
return try await withTaskCancellationHandler {
    try await waitForLifecycle(requestID: requestID, waiterID: waiterID)
} onCancel: {
    Task { await orchestrator.cancelLifecycleWaiter(requestID: requestID, waiterID: waiterID) }
}
```

Removing one waiter does not cancel shared work. Removing the final waiter cancels its dependency task and invalidates the request. Every dependency await checks request and operation currency before state mutation. A cancelled sole start never activates later when blocked capture returns.

- [ ] **Step 5: Run focused and repeated race verification**

Run:

```sh
swift test --filter MonitoringOrchestratorTests
for i in {1..20}; do
  perl -e 'alarm 5; exec @ARGV' swift test --filter 'MonitoringOrchestratorTests/(testPauseDuringReconnectApplyDelayCancelsAndCompletesReconnect|testStopDuringReconnectApplyDelayCancelsAndCompletesReconnect|testNewWinnerDuringBlockedReconnectApplyRemainsPendingUntilNewestApplies|testCancellingSoleStartCallerCancelsBlockedCaptureAndNeverActivates|testCancellingOneOfTwoReconnectWaitersDoesNotCancelSharedOperation)' || exit 1
done
```

Expected: the focused suite passes; 100/100 bounded critical-race repetitions pass with no orphaned `xctest` process.

- [ ] **Step 6: Run complete verification**

Run:

```sh
swift test --filter 'MonitoringOrchestratorTests|FileMonitoringRecoveryStoreTests'
swift test
swift build -c release
git diff --check
```

Expected: every command exits 0. Scan Task 8 production files for debug output, forced casts or tries, dynamic evaluation, hardcoded secrets, TODO/FIXME markers, and commented-out code; expect no matches.

- [ ] **Step 7: Update report and commit Task 2 locally**

Append exact RED/GREEN commands, root-cause evidence, repeat counts, full-suite count, build result, and remaining live-bulb/process-kill concerns to `.superpowers/sdd/task-8-report.md`.

```sh
git add Sources/AgentLightCore/Coordination/MonitoringOrchestrator.swift Tests/AgentLightCoreTests/MonitoringOrchestratorTests.swift Tests/AgentLightCoreTests/Support/TestDoubles.swift
git commit -m "fix: unify monitoring reconnect ownership"
```

No GitHub push is permitted.
