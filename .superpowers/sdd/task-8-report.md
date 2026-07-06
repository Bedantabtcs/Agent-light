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

---

## Review Fix Batch: Lifecycle Serialization and Descriptor-Relative Recovery

### Corrections

- Replaced overlapping lifecycle optionals with queued lifecycle transitions. Every start, resume, pause, stop, and recovery request receives a monotonic request generation; older transitions check it after every suspension and cannot reset sessions or restore after a newer activation completes.
- Separated physical restore from recovery-record cleanup. A successful physical restore enters an explicit clear-pending phase; later pause or reconnect retries only `clear()` and never physically restores again over a possible manual change.
- Serialized active events behind an in-flight restore. A winner accepted during restoration remains current, then captures a fresh baseline and applies only after restore and cleanup complete.
- Applied the three-total-attempt retry policy to initial baseline capture, active ownership recapture, recovery matching, recovery mismatch capture, apply, and restore. The production classifier recognizes bounded transient Tuya failures and selected `URLError` connectivity failures.
- Added nonzero production jitter from 1–250 ms while retaining deterministic injection. Reconnect remains disconnected until a match, health capture, or current-winner apply succeeds.
- Guarded terminal timer installation with the latest local session sequence after the coordinator suspension.
- Moved stream continuations into a synchronously locked registry so consumer cancellation removes the subscriber before the consumer task completes.
- Reduced `TuyaLightControlling` to the record-aware `currentStateMatches(_:)` API and added `reconnect()` and `currentSnapshot()` to `MonitoringOrchestrating`.
- Rewrote the file store around an opened parent directory descriptor and descriptor-relative `openat`, `renameatx_np`, and `unlinkat` operations with `O_NOFOLLOW | O_CLOEXEC`.
- Added `fstat` owner/type/mode/link-count validation, a 64 KiB bounded read, cancellation checks, exact mode `0600`, file and directory fsync, temporary-name collision retries, parent identity checks, and compare-and-swap replacement/conditional clear.
- Added a narrow POSIX seam and real inode/fault tests. Ambiguous post-commit failures preserve displaced or tombstone artifacts rather than deleting possible recovery data.

### Diagnostic Root Cause: Baseline Retry Hang

The isolated baseline retry passed 30/30 under an external timeout before the deterministic diagnostic gate, showing the failure depended on scheduling.

The test originally waited for the light controller's capture call count, then advanced `ManualClock`. That call count is recorded before the retry task registers its sleep. A test-only gate suspended sleep registration and proved this cycle:

```text
start transition
  -> capture throws URLError
  -> retry enters ManualClock.sleep(500 ms), registration suspended
test observes capture count
  -> advances clock before sleeper exists
  -> releases registration, creating a future deadline
test awaits start.value
  -> start awaits a ManualClock deadline that is never advanced again
```

Bounded diagnostic command:

```sh
perl -e 'alarm 5; exec @ARGV' swift test --filter MonitoringOrchestratorTests/testBaselineCaptureRetriesURLErrorWithProductionClassifier
```

Result: exit 142, proving the missed-registration await cycle. Log: `/tmp/task8-baseline-cycle-proof.log`.

The apply-retry test had the same call-entry-versus-sleep-registration race, but differed in two ways: it already passed through an initial throttle sleeper, and it did not directly await the retry task at the end. It therefore tended to fail a count assertion rather than hang.

`ManualClock.waitForSleepCount(_:)` now provides a condition barrier before each retry advance. The temporary diagnostic gate was removed. The fixed baseline test passed 30/30 bounded repetitions; the two lifecycle ordering tests also passed 20/20 repetitions after replacing Task-creation-order assumptions with lifecycle-request condition barriers.

### Review RED

Initial orchestrator command:

```sh
swift test --filter MonitoringOrchestratorTests
```

Result: exit 1. Compilation failed on the wished-for `SessionCoordinating` seam, production jitter API, deterministic subscriber inspection, and protocol-level reconnect/current snapshot. Log: `/tmp/task8-review-fixes-red.log`.

Store command:

```sh
swift test --filter FileMonitoringRecoveryStoreTests
```

Result: exit 1. Compilation failed on the wished-for descriptor-relative POSIX seam, bounded-record error, CAS conflict error, injected initializer, and Darwin operations implementation. Log: `/tmp/task8-store-review-red.log`.

### Review GREEN

Command:

```sh
swift test --filter 'MonitoringOrchestratorTests|FileMonitoringRecoveryStoreTests'
```

Result: exit 0; 60 tests passed, 0 failures. Log: `/tmp/task8-review-focused-green-final.log`.

Coverage added for suspended restore/event reconciliation, pause-drain and suspended-start lifecycle ordering, clear-pending pause/reconnect, production jitter, transient capture/match/recapture, reconnect health barriers, stale terminal installation, deterministic stream termination, destination/parent replacement, load/save/clear races, unsafe metadata, bounded/malformed reads, cancellation, fsync/rename/unlink faults, and temporary collisions.

### Final Verification

- `swift test`: exit 0; 159 tests passed, 0 failures. Log: `/tmp/task8-review-full-test-final.log`.
- `swift build -c release`: exit 0. Log: `/tmp/task8-review-release-build.log`.
- `git diff --check`: exit 0 with no output.
- Source scan found no debug output, TODO/FIXME markers, force casts, forced tries, dynamic evaluation, hardcoded secrets, or commented-out code.

### Review Self-Review

- Lifecycle transitions are serialized, same-kind concurrent activation is coalesced, and all device/store/coordinator suspension points are followed by request or generation checks before state mutation.
- Physical restore, clear-pending cleanup, baseline ownership, and connection health are separate state dimensions; none infers another's success.
- Retry decisions use sanitized typed errors only. Snapshots contain no underlying error, URL, response, or agent content.
- Recovery CAS compares opened inode identities. Concurrent destination changes are swapped back; parent replacement is detected; ambiguous failures retain artifacts.
- File descriptors are opened close-on-exec and closed on every path. Reads are bounded to maximum plus one byte, and temporary files are exclusive, private, fsynced, and atomically installed.

### Review Concerns

- `renameatx_np` CAS semantics are macOS-specific, matching this package's macOS 14 deployment target.
- No live bulb or process-kill filesystem test was run; deterministic actor and POSIX fault tests cover the reviewed logical and atomic boundaries.
