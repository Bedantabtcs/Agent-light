# Task 8 Correction 2: Unified Reconnect Ownership

## Status

Implemented and verified; ready for review/testing.

## Root Cause and Correction

- Reconnect terminal ownership was distributed across a health task, a separate apply completion, and the shared throttle. Cancelling the command window cleared throttle identity before the cancelled task resolved, supersession completed reconnect early, and no-winner/deduplication exits could leak completion.
- Reconnect now has one operation ID, `health`/`commandWindow`/`applying` phases, per-caller waiters, one operation completion, and one `finishReconnect(id:terminal:)` resolver. There is no reconnect-apply latch.
- Successful health remains disconnected until the current winner applies, deduplicates, or disappears. Supersession returns the same operation to the command window for the newest winner. Failure remains disconnected.
- Pause, stop, and final-waiter cancellation cancel and drain health, command delay, and physical apply before restoration or completion. Throttle identity remains installed until its task resolves.
- Lifecycle and reconnect calls use cancellation handlers and explicit waiter IDs. A cancelled shared caller resolves independently while the remaining caller retains one dependency operation. A final cancelled lifecycle waiter resolves only after dependency drain.
- Lifecycle and reconnect drivers are unretained tasks with weak actor capture, avoiding actor-retained self cycles. Explicit actor condition barriers replaced operation-entry ordering assumptions.
- Versioned recovery ownership and recovery storage were not changed.

## TDD Evidence

Required named RED command:

```sh
perl -e 'alarm 30; exec @ARGV' swift test --filter 'MonitoringOrchestratorTests/(testPauseDuringReconnectApplyDelayCancelsAndCompletesReconnect|testStopDuringReconnectApplyDelayCancelsAndCompletesReconnect|testReconnectNoWinnerCompletesExactlyOnce|testReconnectDeduplicatedWinnerCompletesExactlyOnce|testNewWinnerDuringBlockedReconnectApplyRemainsPendingUntilNewestApplies|testCancellingSoleStartCallerCancelsBlockedCaptureAndNeverActivates|testCancellingOneOfTwoReconnectWaitersDoesNotCancelSharedOperation)'
```

Result: bounded exit 142 after compilation. The reconnect apply-delay lifecycle drain did not complete. Log: `/tmp/task8-correction-2-red-named.log`.

Individual RED evidence:

- No winner: exit 1; reconnect returned but remained disconnected.
- Deduplicated winner, superseded winner, sole start cancellation, shared reconnect waiter, and sole reconnect cancellation: bounded exit 142.
- Successful health with a newer winner completed early: expected zero completions/disconnected, observed one completion/connected. Log: `/tmp/task8-correction-2-red-health-success-pending.log`.
- Idle during reconnect command delay leaked completion: bounded exit 142. Log: `/tmp/task8-correction-2-red-no-winner-delay-cancel.log`.
- Tightened shared-caller cancellation hit bounded exit 142 because the cancelled caller still awaited shared completion. Logs: `/tmp/task8-correction-2-red-shared-prompt-cancel.log` and `/tmp/task8-correction-2-red-shared-owner-cancel.log`.
- The first driver repeat exposed operation-entry versus committed-`lastApplied` ordering; actor condition barriers replaced that assumption before the final repeat was restarted.

Focused GREEN:

```sh
swift test --filter MonitoringOrchestratorTests
```

Result: exit 0; 68 tests passed, 0 failures.

## Race Repetition

Twenty externally bounded runs executed ten critical tests per run: health/apply-delay lifecycle cancellation, supersession, sole/shared start cancellation, sole/shared reconnect cancellation, physical apply drain, and no-winner delay cancellation.

Result: 200/200 passed under five-second bounds. No worktree `xctest` or `swift test` process remained. Log: `/tmp/task8-correction-2-race-repeats-final.log`.

## Final Verification

- `swift test --filter 'MonitoringOrchestratorTests|FileMonitoringRecoveryStoreTests'`: exit 0; 107 tests passed, 0 failures. Log: `/tmp/task8-correction-2-relevant-green.log`.
- `swift test`: exit 0; 207 tests passed, 0 failures. Log: `/tmp/task8-correction-2-full-test.log`.
- `swift build -c release`: exit 0. Log: `/tmp/task8-correction-2-release-build.log`.
- `git diff --check`: exit 0 with no output. Log: `/tmp/task8-correction-2-diff-check.log`.
- Production scan found no debug output, TODO/FIXME markers, forced casts/tries, dynamic evaluation, hardcoded credential literals, or commented-out code. Log: `/tmp/task8-correction-2-security-scan.log`.

## Concerns

- No live bulb test was run. Deterministic controller barriers cover health, apply, cancellation, and restoration ordering.
- No process-kill test was run. The recovery implementation is unchanged and all 39 file-store tests pass.

## Next Step

Test with:

```sh
swift test --filter 'MonitoringOrchestratorTests|FileMonitoringRecoveryStoreTests'
swift test
swift build -c release
```

Expected failure mode: failed health or current-winner apply remains disconnected and resolves each registered caller once; final-caller cancellation drains shared work without later activation.

Next phase: none — ready for review/testing.

---

## Final Blocker Correction: Stable Winner Snapshots

### RED

Six deterministic tests were added before production changes. Each uses coordinator barriers to capture a winner, complete or hold newer accepts while the orchestrator is suspended, and then release the stale snapshot:

- post-health stale no-winner snapshot;
- post-health stale deduplication snapshot;
- throttle stale no-winner snapshot;
- throttle stale deduplication snapshot;
- supersession-resolver stale no-winner snapshot;
- two overlapping in-flight accepts where revision does not change during the winner await.

Direct `xctest` runs failed all six tests for the intended behavior: the old code terminally connected reconnect over a newer completed accept, or connected while two newer accepts remained in flight. Log: `/tmp/task8-final-blocker-red.log`.

### GREEN

- `accept` now increments an actor-isolated monotonic event revision when acceptance begins and when `coordinator.accept` completes.
- An actor-isolated in-flight accept count covers multiple overlapping accepts.
- `stableWinnerSnapshot(while:)` is the sole production caller of `coordinator.currentWinner()`. It validates caller-specific lifecycle, task, throttle, and reconnect identity before and after the await, then requires unchanged event revision and zero accepts in flight.
- Post-health reconnect, reconnect throttle, and supersession resolution treat an unstable snapshot as non-terminal, retain disconnected reconnect ownership, and schedule a fresh winner window.
- Normal throttle, idle restoration, terminal expiry, physical-send currency, and post-apply rescheduling use the same snapshot helper; unstable normal snapshots reschedule instead of restoring or deduplicating.

Focused command:

```sh
swift test --filter 'MonitoringOrchestratorTests.test(PostHealthStale|FireThrottleStale|SupersessionResolverStale|PostHealthSnapshotRejects)'
```

Result: 6 tests passed, 0 failures. Log: `/tmp/task8-final-blocker-green.log`.

### Final Verification

- `swift test --filter MonitoringOrchestratorTests`: 91 passed, 0 failures. Log: `/tmp/task8-final-blocker-orchestrator.log`.
- Direct externally bounded `xctest`: 6 critical races × 20 runs = 120/120 passed under ten-second per-run bounds. Log: `/tmp/task8-final-blocker-races-20x.log`.
- `swift test --filter 'MonitoringOrchestratorTests|FileMonitoringRecoveryStoreTests'`: 130 passed, 0 failures. Log: `/tmp/task8-final-blocker-relevant.log`.
- `swift test`: 230 passed, 0 failures. Log: `/tmp/task8-final-blocker-full.log`.
- `swift build -c release`: exit 0. Log: `/tmp/task8-final-blocker-release.log`.
- `git diff --check`, production security scan, `Task.yield` scan, and orphan-process scan: clean. Log: `/tmp/task8-final-blocker-security-diff.log` and `/tmp/task8-final-blocker-orphans.log`.

### Next Step

Test with:

```sh
swift test --filter 'MonitoringOrchestratorTests|FileMonitoringRecoveryStoreTests'
swift test
swift build -c release
```

Expected failure mode: if an accept overlaps a winner snapshot, reconnect remains disconnected and pending until a fresh one-second winner window; no stale no-winner or deduplication snapshot may terminally connect.

Next phase: none — ready for review/testing.

---

## Re-review Correction

### RED

- Post-write supersession and physical-mismatch command:
  `perl -e 'alarm 10; exec @ARGV' swift test --filter 'MonitoringOrchestratorTests/(testWinnerAfterPhysicalReconnectApplyBeforeCommittedSaveKeepsReconnectPending|testPostWriteWinnerEqualToPreviousLogicalStateIsNotDeduplicated|testMismatchingHealthForcesApplyWhenWinnerEqualsLastApplied)'`
  bounded exit 142. The old physical write was not installed as `lastApplied`, reconnect could deduplicate against stale logical state, and mismatch was deduplicated again in the throttle. Log: `/tmp/task8-correction-2-rereview-red-post-write.log`.
- Lifecycle cancellation handoff command for initiating/non-initiating start plus pause/stop bounded exit 142. A new start remained joinable with the cancelled request, and pause/stop cancellation left lifecycle mode inconsistent. Log: `/tmp/task8-correction-2-rereview-red-lifecycle.log`.
- Driver focused command initially bounded exit 142. Reconnect had no operation-owned driver terminal callback for blocked health, pending clear, delay/apply drain, waiter attachment during cancellation, or deallocation. Log: `/tmp/task8-correction-2-rereview-driver-focused.log`.
- Removing `Task.yield()` from `ManualClock.advance` exposed missed-registration tests. Explicit sleep, operation, connection, and applied-state barriers replaced those assumptions.

### GREEN

- A physical apply is now always followed by a cancellation-independent committed-state save and a second currency check. `SendOutcome.physicallyAppliedButSuperseded` records actual physical state and keeps reconnect non-terminal for the current winner.
- Mismatching health disables deduplication until a corrective physical apply.
- Final lifecycle cancellation marks the transition non-joinable immediately. New starts queue after drain; pause/stop roll back to the prior active mode only after drain when no newer lifecycle request exists.
- Reconnect owns a weak-self driver task. Terminal requests cancel owned health/throttle work; only `finishReconnectFromDriver` drains subwork, publishes terminal state, clears operation identity, and finishes callers.
- Final waiter cancellation removes the waiter, resolves it, then rechecks the live operation/waiter set before cancelling the driver.
- `ManualClock.advance` resumes only registered due sleepers and contains no scheduling yields.

Verification:

- `swift test --filter MonitoringOrchestratorTests`: 81 passed, 0 failures.
- Direct bounded `xctest` repetition: 260/260 passed (13 critical tests × 20, five-second bound). Log: `/tmp/task8-correction-2-rereview-repeats-final.log`.
- `swift test --filter 'MonitoringOrchestratorTests|FileMonitoringRecoveryStoreTests'`: 120 passed, 0 failures. Log: `/tmp/task8-correction-2-rereview-relevant.log`.
- `swift test`: 220 passed, 0 failures. Log: `/tmp/task8-correction-2-rereview-full.log`.
- `swift build -c release`: exit 0. Log: `/tmp/task8-correction-2-rereview-release.log`.

Remaining concerns are unchanged: no live-bulb or process-kill acceptance test was run.

---

## Final Re-review Correction: Terminal Drain and Post-await Currency

### RED

Before production changes, the focused command was:

```sh
perl -e 'alarm 60; exec @ARGV' swift test --filter 'MonitoringOrchestratorTests.test(FinalReconnectCancellation|MismatchingHealthRemains|NewerWinnerAccepted|CancellingSolePauseStill|CancellingSoleStopStill|ReconnectCallerAfterTerminal|CancellingNonInitiating)'
```

The bounded run failed as follows:

- Cancelled pause rolled back to active, accepted and physically applied `working`, retained the recovery record, and published `working` instead of `idle`.
- Cancelled stop rolled back to active and published `needsYou` instead of `idle`.
- Final reconnect cancellation completed its caller while cancellation-ignoring health and pending-clear work remained blocked.
- The remaining terminal-attachment/current-snapshot cases did not complete before the external bound under the old implementation.
- The non-initiating shared reconnect waiter case passed, confirming that only the final-waiter ownership path needed to retain completion.

Result: nonzero/bounded failure. Log: `/tmp/task8-rereview-red.log`.

### GREEN

- Final reconnect cancellation now moves the last cancelled waiter to operation-owned terminal completion. The driver completes that waiter only after owned health, pending clear, command delay, and physical apply have drained.
- Terminal state is installed synchronously before any cancellation-path suspension. A reconnect arriving during terminal drain waits for the old operation completion and starts a fresh operation if monitoring remains active and disconnected.
- Mismatch disables deduplication until a corrective physical write. Pre-write supersession preserves that forced-write state; only a completed physical write re-enables deduplication.
- Every `currentWinner()` suspension in the physical-send path is followed by checks for task cancellation, exact throttle operation ID, generation, mode, reconnect ID/terminal state, and the expected locally accepted session sequence.
- A cancelled pause or stop caller remains retained until safe reset, restore, and conditional clear complete. Caller cancellation no longer invalidates or rolls back deactivation; newer lifecycle requests still supersede through their own request/generation.
- Pending-clear reconnect cancellation rechecks task and reconnect currency before health begins.

Focused command:

```sh
swift test --filter 'MonitoringOrchestratorTests.test(FinalReconnectCancellation|MismatchingHealthRemains|NewerWinnerAccepted|CancellingSolePauseStill|CancellingSoleStopStill|ReconnectCallerAfterTerminal|CancellingNonInitiating)'
```

Result: 10 tests passed, 0 failures. Log: `/tmp/task8-rereview-green-focused.log`.

### Final Verification

- `swift test --filter MonitoringOrchestratorTests`: 85 passed, 0 failures. Log: `/tmp/task8-rereview-orchestrator.log`.
- Direct externally bounded `xctest`: 10 critical tests × 20 runs = 200/200 passed under ten-second per-run bounds. Log: `/tmp/task8-rereview-races-20x.log`.
- `swift test --filter 'MonitoringOrchestratorTests|FileMonitoringRecoveryStoreTests'`: 124 passed, 0 failures. Log: `/tmp/task8-rereview-final-relevant.log`.
- `swift test`: 224 passed, 0 failures. Log: `/tmp/task8-rereview-final-full.log`.
- `swift build -c release`: exit 0. Log: `/tmp/task8-rereview-final-release.log`.
- `git diff --check`: exit 0; security scan found no debug output, TODO/FIXME markers, forced casts/tries, dynamic evaluation, credential literals, commented-out production code, or `Task.yield`. Log: `/tmp/task8-rereview-final-security-diff.log`.
- No worktree `xctest` or `swift test` process remained. Log: `/tmp/task8-rereview-final-orphans.log`.

### Next Step

Test with:

```sh
swift test --filter 'MonitoringOrchestratorTests|FileMonitoringRecoveryStoreTests'
swift test
swift build -c release
```

Expected failure mode: a cancelled final reconnect caller must remain pending until cancellation-ignoring owned work is released; a mismatch superseded before physical write must remain disconnected and schedule the corrective winner.

Next phase: none — ready for review/testing.

---

## Same-Winner Supersession Correction

### RED

Four deterministic tests were added before the production change:

- same-winner instability before physical write;
- forced-mismatch same-winner instability before physical write;
- same-winner instability after physical write and during committed recovery save;
- forced-mismatch same-winner instability after physical write and during committed recovery save.

Command:

```sh
swift test --filter 'MonitoringOrchestratorTests.test(SameWinner|ForcedMismatchSameWinner)'
```

Result: all four tests failed. Both pre-write cases terminally disconnected instead of opening a fresh command window. Both post-write cases persisted and recorded the successful command but published disconnected. Log: `/tmp/task8-same-winner-red.log`.

### GREEN

- A stable current winner equal to the attempted winner is no longer treated as failure.
- The reconnect connects only when `lastApplied` equals the attempted state and deduplication has been enabled by a successful physical write.
- Without that physical/logical confirmation, reconnect remains pending and disconnected and schedules a fresh one-second command window.
- Forced mismatch therefore cannot deduplicate a pre-write stale logical state, while a successful corrective physical write safely enables terminal connection without a redundant write.
- Different-winner supersession behavior is unchanged.

Focused result: 4 tests passed, 0 failures. Log: `/tmp/task8-same-winner-green.log`.

### Final Verification

- Direct externally bounded `xctest`: 4 critical races × 20 runs = 80/80 passed under ten-second per-run bounds. Log: `/tmp/task8-same-winner-races-20x.log`.
- `swift test --filter MonitoringOrchestratorTests`: 95 passed, 0 failures. Log: `/tmp/task8-same-winner-orchestrator.log`.
- `swift test --filter 'MonitoringOrchestratorTests|FileMonitoringRecoveryStoreTests'`: 134 passed, 0 failures. Log: `/tmp/task8-same-winner-relevant.log`.
- `swift test`: 234 passed, 0 failures. Log: `/tmp/task8-same-winner-full.log`.
- `swift build -c release`: exit 0. Log: `/tmp/task8-same-winner-release.log`.
- `git diff --check`, production security scan, `Task.yield` scan, and orphan-process scan: clean. Log: `/tmp/task8-same-winner-security-diff.log` and `/tmp/task8-same-winner-orphans.log`.

### Next Step

Test with:

```sh
swift test --filter 'MonitoringOrchestratorTests|FileMonitoringRecoveryStoreTests'
swift test
swift build -c release
```

Expected failure mode: an unconfirmed same-winner supersession remains pending/disconnected and retries; a committed same-winner physical write connects exactly once without another write.

Next phase: none — ready for review/testing.
