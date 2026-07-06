# Task 8 Report: Monitoring Orchestration and Crash Recovery

## Status

Implemented and verified; ready for review/testing.

## Implementation

- Added a Swift 6 `MonitoringOrchestrator` actor with idempotent start, pause, resume, stop, reconnect, and recovery transitions.
- Assigned app-local monotonic sequences on acceptance and ignored external sequence values for cross-session arbitration.
- Added a cancellation-safe one-second coalescing window that recomputes the newest winner at send time and prevents a stale retry or late apply from winning a lifecycle race.
- Added eight-second Completed and twelve-second Error holds measured from acceptance, with same-session cancellation and winner recomputation on expiry.
- Added baseline ownership epochs: capture and durable save precede the first apply; idle, pause, and stop restore once; failed restoration retains ownership for a later retry.
- Added three-total-attempt transient retry behavior with 500 ms and one-second delays plus bounded injectable jitter. Non-transient failures disconnect immediately, and snapshots expose only typed connection state.
- Added multi-subscriber `AsyncStream` snapshots with an immediate current value, termination cleanup, and weakly captured timer tasks.
- Added crash recovery for matching applied or pending commands, external-state adoption on mismatch, repeated-recovery idempotence, and clear-only-after-success semantics.
- Added a file-backed recovery store using same-directory atomic rename, fsync, mode `0600`, owner/type validation, symlink rejection, and sanitized typed errors.

## Persistence Commit Points

1. The baseline-only record is saved before monitoring becomes active.
2. Before a physical apply, a record containing the previous `lastCommand` and new `pendingCommand` is saved.
3. Only after apply succeeds is `pendingCommand` promoted to `lastCommand`.
4. If the post-apply save fails, the pending record remains recoverable because recovery accepts either the last confirmed or pending command as Agent Light-owned.
5. Recovery and normal restoration clear the record only after the baseline restore succeeds.

## TDD Evidence

### Initial RED

Command:

```sh
swift test --filter MonitoringOrchestratorTests
```

Result: exit 1. Compilation failed because `MonitoringOrchestrator`, `TuyaLightControlling`, `MonitoringRecoveryRecord`, `MonitoringRecoveryStoring`, and `FileMonitoringRecoveryStore` did not exist. Full output: `/tmp/task8-red.log`.

### Focused GREEN

Command:

```sh
swift test --filter 'MonitoringOrchestratorTests|FileMonitoringRecoveryStoreTests'
```

Result: exit 0; 33 tests passed, 0 failures.

The focused suite covers rapid and cross-agent newest-wins ordering, exact throttle boundaries, terminal expiry and cancellation, concurrent lifecycle transitions, persistence ordering and failures, transient/non-transient retry behavior, stale retry cancellation, disconnect/reconnect, matching/mismatching recovery, stream fan-out, task cleanup, file permissions, atomic replacement, and symlink rejection.

### Additional Race RED/GREEN

- Concurrent starts initially returned cancellation to one caller.
- Concurrent pauses initially allowed a restore to race an in-flight apply.
- An event arriving while an idle transition drained an apply initially caused an obsolete restore.
- Resume initially accepted a command while pause restoration was still in flight.
- Timer tasks initially retained the orchestrator until their deadlines.

Each regression was captured as a failing focused test before the actor transition/task ownership logic was corrected.

## Verification

- `swift test`: exit 0; 132 tests passed, 0 failures.
- `swift build -c release`: exit 0.
- `git diff --check`: exit 0 with no output.
- Source scan found no debug output, TODO/FIXME markers, dynamic evaluation, hardcoded secrets, TypeScript `any`, or commented-out code.

## Self-Review

- Actor state is isolated; protocol dependencies, tasks, closures, records, snapshots, and timer metadata are `Sendable` under Swift 6 language mode.
- Generation tokens and shared task resolution prevent superseded start/pause/resume/stop work from committing state after a newer transition.
- Pause/stop await an in-flight apply before restoration, while concurrent callers share the same drain and restore tasks.
- Desired state is revalidated after each actor reentrancy boundary and before every retry.
- Recovery distinguishes confirmed and pending commands, closing the crash window around a physical apply without clearing the original baseline.
- File operations reject symlinks and unsafe file types, never log payloads, and expose only typed generic failures.

## Concerns

- No live Wipro bulb was used. The controller boundary is covered with deterministic actors; wiring the resolved Tuya capabilities to `TuyaLightControlling` remains an application-composition task.
- Crash consistency is tested at logical save/apply boundaries. Process-kill testing against a real filesystem and bulb remains a manual acceptance check.

## Next Step

Next phase: Task 9 — implement Keychain credential storage and login-item control.

Test this batch with:

```sh
swift test --filter 'MonitoringOrchestratorTests|FileMonitoringRecoveryStoreTests'
swift test
swift build -c release
```

Expected failure mode: transient light failures may produce a typed disconnected snapshot after three total attempts, but must not clear the recovery record or replay a superseded color.

Ready-to-paste prompt for a fresh agent:

```text
Implement Task 9 from docs/superpowers/plans/2026-07-06-agent-light-macos-implementation.md using strict TDD. Read the approved design, Task 8 report, and existing credential/application boundaries first. Add Keychain-backed credentials and login-item control, run focused and full verification, write .superpowers/sdd/task-9-report.md, and commit locally without pushing.
```
