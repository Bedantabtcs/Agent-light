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
