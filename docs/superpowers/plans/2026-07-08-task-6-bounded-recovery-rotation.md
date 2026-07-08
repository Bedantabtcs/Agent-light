# Task 6 Bounded Recovery Rotation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace indefinitely retained recovery artifacts with a cross-process locked active/previous/tombstone rotation while preserving exact descriptor-pinned revision CAS behavior.

**Architecture:** Keep the configured recovery URL as the active slot and derive fixed sibling previous, tombstone, lock, and transient staging names. Every load and mutation opens the private parent directory, acquires and authenticates the stable advisory lock, validates known slots without following symlinks, and performs descriptor-relative atomic replacements plus required file/directory fsyncs. Failed writes reuse one bounded staging pathname; committed saves and clears absorb it so successful maintenance leaves only active/previous/tombstone/lock and never enumerates or changes unknown files.

**Tech Stack:** Swift 6.2, Swift actors, XCTest, Darwin `openat`/`fstatat`/`flock`/`renameat`/`fsync`, macOS 14+.

## Global Constraints

- Start from `0128be45559c645e1612cd818dc744eb58e42c37` in the existing isolated worktree.
- Do not access live bulbs, HOME state, credentials, login items, the installed application, browser state, or GitHub.
- Do not weaken descriptor pinning, revision compare-and-swap, symlink/hard-link/owner/mode validation, fsync, cancellation, parent-replacement, cross-instance, or Task 5 timing guarantees.
- Production active name remains `monitoring-recovery-v1.json`; sibling slots are `.monitoring-recovery.previous`, `.monitoring-recovery.tombstone`, and `.monitoring-recovery.lock`.
- Unknown directory entries remain byte-for-byte untouched; production code never enumerates the directory.
- No debug logs, `any`, forced casts/tries, dynamic evaluation, hardcoded secrets, commented-out code, or unbounded artifact names.

---

### Task 1: Establish bounded rotation RED

**Files:**
- Modify: `Tests/AgentLightCoreTests/MonitoringOrchestratorTests.swift`

**Interfaces:**
- Consumes: existing `FileMonitoringRecoveryStore(url:)`, `save`, `load`, and revision-checked `clear`.
- Produces: regression coverage for fixed names, unknown-file preservation, crash-boundary selection, two-instance serialization, stale revisions, and lock replacement.

- [ ] Add `testRecoveryArtifactsRemainBoundedAcrossRepeatedSaveAndClear` with hundreds of cycles, asserting successful maintenance leaves only the configured active name plus fixed previous/tombstone/lock slots.
- [ ] Add unknown-file preservation and injected-active-name tests that compare exact bytes before and after repeated store mutations.
- [ ] Add seeded crash-boundary tests for active-to-previous, new-active installation, and clear-to-tombstone states, asserting `load()` selects active, then previous only when no tombstone marks a clear.
- [ ] Add two-store concurrent save/clear and stale-revision tests that assert no split coordination and no artifact growth.
- [ ] Add a lock-inode replacement test that replaces the lock after acquisition and asserts retry or fail-closed behavior before mutation.
- [ ] Run `swift test --filter FileMonitoringRecoveryStoreTests/testRecoveryArtifactsRemainBoundedAcrossRepeatedSaveAndClear` and record an actual failure caused by the current random retained names.

---

### Task 2: Add stable lock and slot primitives

**Files:**
- Modify: `Sources/AgentLightCore/Persistence/MonitoringRecoveryStore.swift`
- Modify: `Tests/AgentLightCoreTests/MonitoringOrchestratorTests.swift`

**Interfaces:**
- Extend `MonitoringRecoveryPOSIXOperations` with no-follow pathname metadata, stable lock open/acquire/release, reusable private staging open/truncate, and atomic replacement rename.
- Keep all methods descriptor-relative after opening the validated parent.

- [ ] Implement Darwin primitives with `O_NOFOLLOW | O_CLOEXEC`, exact `0600` validation, `fstatat(..., AT_SYMLINK_NOFOLLOW)`, EINTR-safe `flock`, `ftruncate`/rewind, and `renameat` replacement.
- [ ] Update the fault-injecting seam to record lock/rename behavior and expose deterministic lock-replacement and crash-boundary hooks.
- [ ] Acquire the lock, validate it, then reopen the lock pathname and compare its live inode with the locked descriptor; release and retry a bounded number of times on replacement, then fail closed.
- [ ] Validate active, previous, tombstone, lock, and any present staging slot under the authenticated lock before mutation.
- [ ] Run focused lock/symlink/hard-link/owner/mode tests and keep the new lock replacement regression green.

---

### Task 3: Implement bounded save/load/clear rotation

**Files:**
- Modify: `Sources/AgentLightCore/Persistence/MonitoringRecoveryStore.swift`
- Modify: `Tests/AgentLightCoreTests/MonitoringOrchestratorTests.swift`

**Interfaces:**
- `load()` chooses active; if active is absent it returns nil when tombstone exists, otherwise it loads previous as interrupted-save recovery.
- `save(_:)` syncs a reusable stage, rotates active to previous, installs active, syncs the directory, revalidates parent/lock, and returns a pinned active revision.
- `clear(expecting:)` authenticates the revision’s exact slot and inode, atomically rotates that slot to tombstone, absorbs stale staging, syncs/revalidates, then invalidates sibling revisions.

- [ ] Implement slot-aware revision ownership for active, previous, and tombstone descriptors.
- [ ] Preserve old active in previous before installing the staged record; retarget prior revisions during an interrupted rotation and invalidate them only after commit.
- [ ] Preserve recoverable data at every failure boundary, reusing at most one staging name and ensuring later successful save/clear absorbs it.
- [ ] Replace random-retention assertions with exact previous/tombstone recovery assertions while retaining every existing security and crash test.
- [ ] Run the complete file-store suite and the bounded stress test ten times.

---

### Task 4: Full verification, report, and local commit

**Files:**
- Create: `.superpowers/sdd/task-6-report.md`

**Interfaces:**
- Produces: reproducible RED/GREEN evidence, verification counts, security/artifact/orphan results, concerns, and next step.

- [ ] Run `swift test --filter 'FileMonitoringRecoveryStoreTests|MonitoringOrchestratorTests|MonitoringRecoveryPublicAPITests'` and confirm the recovery/orchestrator total is at least 112 tests.
- [ ] Run bounded hundreds-cycle and cross-instance stress repeatedly under an external timeout.
- [ ] Run `swift test --parallel --num-workers 2`, `swift build -c release`, `./scripts/build-app.sh release`, code-sign verification, plist validation, and `git diff --check`.
- [ ] Scan changed production files for debug output, forced operations, dynamic evaluation, secret-like literals, TODO/FIXME markers, commented-out code, unsafe recovery unlink, unbounded random recovery names, backup/reject artifacts, and orphaned Swift/XCTest processes.
- [ ] Write `.superpowers/sdd/task-6-report.md` with exact commands/results and no unsupported production-readiness claim.
- [ ] Commit the scoped files locally as `fix: bound monitoring recovery generations`; do not push.
