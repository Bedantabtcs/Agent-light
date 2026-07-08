# Task 6 Report: Bounded Recovery-Generation Rotation

## Status

Ready for review/testing. Task 6 is implemented on top of `0128be45559c645e1612cd818dc744eb58e42c37` without accessing live bulbs, credentials, HOME configuration, login items, the installed application, browser state, or GitHub.

## Root cause and RED evidence

The Task 8 retention-only correction removed unsafe pathname unlinking by retaining every staged, displaced, and cleared record under a unique random name. That preserved recoverability but made successful save/clear cycles grow the directory without a bound.

The first production-independent regression performed 200 save/clear cycles and allowed only:

```text
monitoring-recovery-v1.json
.monitoring-recovery.previous
.monitoring-recovery.tombstone
.monitoring-recovery.lock
```

Command:

```bash
swift test --filter FileMonitoringRecoveryStoreTests/testRecoveryArtifactsRemainBoundedAcrossRepeatedSaveAndClear
```

Result before production changes: exit 1. The store retained 200 random `.monitoring-recovery-v1.json.<UUID>.tmp` artifacts; both the fixed-name subset assertion and maximum count assertion failed.

## Implementation

- The configured recovery URL remains the active slot. Production composition therefore continues to use `monitoring-recovery-v1.json`; injected test URLs remain supported as alternate active names.
- Fixed sibling names are `.monitoring-recovery.previous`, `.monitoring-recovery.tombstone`, and `.monitoring-recovery.lock`.
- Failed pre-rotation writes reuse one `.monitoring-recovery.stage` pathname. Successful save consumes it as active; successful clear atomically absorbs it into previous. Repeated failures cannot create new names.
- Every operation opens the exact private `0700` parent directory, opens the lock with `O_NOFOLLOW | O_CLOEXEC` at exact mode `0600`, acquires `flock(LOCK_EX)`, then reopens the lock path and compares live inode identity with the locked descriptor.
- Lock pathname replacement causes a bounded retry. Eight consecutive replacements fail closed with `concurrentModification` before any recovery-slot mutation.
- Active, previous, tombstone, lock, and any present stage are validated under the lock with `fstatat(..., AT_SYMLINK_NOFOLLOW)`, exact owner/type/mode checks, and link count 1.
- Save file-syncs a fully written stage, rotates active to previous with atomic replacement, installs stage as active, directory-syncs, then revalidates the parent and lock before issuing a descriptor-pinned revision.
- Clear authenticates the exact revision record and pinned inode, atomically rotates its owned active/previous slot to tombstone, directory-syncs, revalidates parent/lock, and invalidates sibling handles only after commit.
- `load()` chooses active first. With no active it returns nil when tombstone marks a clear; otherwise it loads previous as interrupted-save recovery.
- Post-install save failures use an atomic swap to preserve both candidate and prior generations in active/previous. Failed rollback retains the prior descriptor at previous so exact CAS clear can target it without touching the replacement.
- Production never enumerates the directory and never calls recovery `unlink`/`unlinkat`; unknown names and bytes remain untouched.

## Coverage added and preserved

Added deterministic coverage for:

- 200 repeated successful save/clear cycles with the fixed artifact set;
- 100 repeated file-sync failures retaining one reusable stage, followed by successful stage absorption;
- injected active URLs and byte-for-byte preservation of unknown files;
- seeded crash states after active-to-previous, new-active installation, and active-to-tombstone boundaries;
- 200 concurrent saves through two store instances using the same advisory lock;
- stale cross-instance revision rejection;
- one-time lock-inode replacement retry and persistent replacement fail-closed behavior;
- unsafe symlink rejection in the fixed previous slot.

Preserved coverage includes exact revision CAS, descriptor pinning, inode reuse, sibling descriptor invalidation, store deinitialization, save/clear replacement races, failed rollback retargeting, symlink/hard-link/owner/mode validation, file and directory fsync failures, cancellation, parent replacement, malformed/oversized records, temporary-name collision, and public opaque revision conformance.

## Verification

- `swift test --filter FileMonitoringRecoveryStoreTests`: 47 tests, 0 failures.
- `swift test --filter 'FileMonitoringRecoveryStoreTests|MonitoringOrchestratorTests|MonitoringRecoveryPublicAPITests'`: 160 tests, 0 failures (47 store, 112 orchestrator, 1 public API).
- Ten externally bounded stress runs of the four bounded/cross-instance/lock tests: 40/40 tests passed.
- `swift test --parallel --num-workers 2`: final run completed 534/534 tests, exit 0.
- `swift build -c release`: passed.
- `./scripts/build-app.sh release`: passed.
- `codesign --verify --deep --strict "build/Agent Light.app"`: passed.
- `plutil -lint "build/Agent Light.app/Contents/Info.plist"`: OK.
- `git diff --check`: passed.
- Recovery unlink/random-name scan: no `unlink`, `unlinkat`, or UUID temporary recovery names in production recovery storage.
- Changed-source security scan: no debug output, forced casts/tries, dynamic evaluation, hardcoded credential/private-key material, TODO/FIXME markers, or commented-out code.
- Backup/reject artifact scan: no matches.
- Worktree Swift/XCTest orphan scan: no matches.

## Concerns

- The first two-worker parallel run hit the pre-existing Task 3 relay subprocess wall-clock assertion: 0.73s versus the `<0.2s` test threshold. The isolated test immediately passed at 0.073s, and the fresh full two-worker rerun completed all 534 tests. Task 7 already owns removal of this CI-sensitive wall-clock assertion without weakening the deterministic 100ms transport budget.
- Crash behavior is covered with seeded on-disk boundary states and deterministic syscall fault injection. No destructive process-kill test was run.
- No live Tuya device was accessed; Task 5 physical timing remains covered by its deterministic clock/controller tests.

## Next Step

Next phase: Task 7 — deferred boundary coverage, documentation, and the final automated gate. Use a fresh agent because it covers independent protocol, number, relay timing, documentation, and final-release concerns.

Test this batch with:

```bash
swift test --filter 'FileMonitoringRecoveryStoreTests|MonitoringOrchestratorTests|MonitoringRecoveryPublicAPITests'
swift test --parallel --num-workers 2
swift build -c release
./scripts/build-app.sh release
codesign --verify --deep --strict "build/Agent Light.app"
plutil -lint "build/Agent Light.app/Contents/Info.plist"
```

Expected failure mode: a persistent lock-path replacement must return `concurrentModification` without creating active/previous/tombstone/stage; a stale revision must never clear a newer active inode; successful repeated maintenance must never exceed the fixed active/previous/tombstone/lock set.

Ready-to-paste prompt:

```text
Implement Task 7 from docs/superpowers/plans/2026-07-07-final-lifecycle-reliability-correction.md using strict TDD. Start from the reviewed Task 6 commit, read the final correction design and Tasks 1–6 reports first, remove the known relay wall-clock flake without weakening the deterministic transport budget, complete deferred protocol/JSON boundary coverage and documentation, run the final bounded parallel/release/package/security/artifact/orphan gates, write the final report, and commit locally without pushing. Do not access live bulbs, credentials, HOME configuration, login items, the installed application, browser state, or GitHub.
```

---

## Review correction: parent-vnode coordination and final inode authentication

The first bounded implementation still treated the replaceable lock-file inode as the authoritative advisory lock, trusted the installed active/tombstone identity after the directory fsync, used replacing rename when rolling back to an absent destination, and did not distinguish newly created lock files before correcting restrictive-umask permissions.

### Review RED evidence

Three focused regressions were added before the production correction:

```bash
swift test --filter 'FileMonitoringRecoveryStoreTests/(testSaveRejectsActiveReplacementAfterDirectorySyncWithoutResurrectingPrevious|testClearRejectsTombstoneRemovalAfterDirectorySyncWithoutResurrectingPrevious|testCancelledClearRollbackNeverReplacesConcurrentDestination)'
```

Result: exit 1; 3 tests ran with 5 failures. Save returned success after active was replaced post-fsync. Clear returned success after tombstone removal and a fresh store resurrected previous. Cancellation rollback overwrote a concurrent active destination and removed the owned tombstone.

The new directory-coordination tests were then verified against a deliberate regression that moved `flock` authority back to the lock-file descriptor:

```bash
perl -e 'alarm 20; exec @ARGV' swift test --filter 'FileMonitoringRecoveryStoreTests/(testLockReplacementBeforeStageWriteCannotSplitDirectoryCoordination|testLockReplacementDuringRollbackCannotLetNewCommitBeRolledOver)'
```

Result: exit 1; both tests failed. A second store committed through the replacement lock inode while the first remained blocked, and rollback/concurrent modification displaced the expected final winner.

The restrictive-umask regression was verified with the newly created lock-file `fchmod` deliberately removed:

```bash
swift test --filter FileMonitoringRecoveryStoreTests/testNewLockFileIsForcedToMode0600UnderRestrictiveUmask
```

Result: exit 1; the save failed with `unsafeFile`, proving the test detects mode truncation by umask.

### Review correction

- The validated, pinned parent directory descriptor now holds `flock(LOCK_EX)` for the complete operation. Stores using the same directory inode cannot split coordination when `.monitoring-recovery.lock` is replaced.
- The lock file remains fixed-name validated metadata. Creation uses `O_CREAT | O_EXCL | O_NOFOLLOW`, corrects only the newly created descriptor to `0600`, fsyncs the file and directory, and never chmods a preexisting unsafe file.
- Parent path identity and lock-file descriptor/path identity are revalidated before stage creation/truncation and immediately before every recovery pathname mutation.
- Save reopens and validates active after the commit directory fsync and compares it with the pinned candidate descriptor before issuing a revision.
- Clear reopens and validates tombstone after the commit directory fsync and compares it with the pinned owned generation before returning success.
- If a committed slot disappears after fsync, previous is moved exclusively to tombstone when needed so a fresh load cannot resurrect a stale generation.
- Pre-commit save recovery authenticates active/previous before rollback. Restoration to an absent active path uses exclusive no-replace rename; a concurrent destination remains untouched.
- Clear cancellation and mismatch rollback authenticate the tombstone source and use exclusive no-replace rename. Concurrent destination bytes and the recovery slot are both retained.
- Lock descriptors are closed on every post-open validation failure; the authoritative directory lock is released only after all mutation/recovery work completes.

### Review verification

- Eight focused review regressions: 8 tests, 0 failures.
- `swift test --filter FileMonitoringRecoveryStoreTests`: 53 tests, 0 failures.
- `swift test --filter 'FileMonitoringRecoveryStoreTests|MonitoringOrchestratorTests|MonitoringRecoveryPublicAPITests'`: 166 tests, 0 failures (53 store, 112 orchestrator, 1 public API).
- Twenty externally bounded runs of eight critical coordination/fsync/rollback/bounded tests: 160/160 tests passed.
- `swift test --parallel --num-workers 2`: final rerun completed 540/540 tests, exit 0.
- `swift build -c release`: passed.
- `./scripts/build-app.sh release`: passed.
- `codesign --verify --deep --strict "build/Agent Light.app"`: passed.
- `plutil -lint "build/Agent Light.app/Contents/Info.plist"`: OK.
- Diff, recovery unlink/random-name, changed-source security, backup/reject artifact, and orphan-process scans: clean.

The first parallel review run hit only the documented Task 3 relay wall-clock assertion at 0.58s versus `<0.2s`. The immediate isolated run passed at 0.075s and the fresh complete two-worker rerun passed.

## Next Step

Next phase: Task 7 — deferred boundary coverage, documentation, and the final automated gate. Use the ready-to-paste Task 7 prompt above in a fresh agent.
