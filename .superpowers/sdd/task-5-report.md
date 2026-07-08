# Task 5 Report: Physical terminal holds and command-attempt gate

## Status

Ready for review/testing. Task 5 is implemented on top of `a9af044ea960` without touching live bulbs, credentials, HOME configuration, login items, the installed application, or GitHub.

## RED evidence

Tests were added before production changes.

- `testCompletedPhysicalHoldStartsAfterSuccessfulApply` failed at physical time 8.999 seconds: restore count was 1 instead of 0 and the snapshot was Idle instead of Completed.
- `testErrorPhysicalHoldStartsAfterSuccessfulRetry` failed before the post-retry 12-second hold: restore count was 1 instead of 0 and the snapshot was Idle instead of Error.
- `testEveryCommandAttemptIsAtLeastOneSecondApart` failed with premature retries/restores and measured adjacent attempt gaps of 999 ms and 1 ms.
- `testNewWinnerDropsObsoleteRetry` passed before production changes, documenting the existing cancellation guarantee that the correction preserves.

## Implementation

- Added monotonic elapsed time to `AgentLightClock`, with deterministic `ManualClock` support and a `ContinuousClock`-backed production implementation.
- Terminal expiry is no longer scheduled at event acceptance. It starts only after the matching physical apply succeeds, the committed recovery record is durably saved, and the winner is still current.
- Applied terminal tokens contain source, session, sequence, winner generation, and lifecycle generation. A late superseded apply/commit cannot install a timer or expire a newer same-session event.
- Added one shared physical-command path for every `apply` and `restore` attempt, including apply retry, restore retry, reconnect flush, recovery restore, pause restore, and stop restore.
- The gate records the previous attempt's monotonic start and delays the next attempt until at least one second later. Retry jitter extends that minimum and cannot shorten it.
- Stable-winner and winner-generation checks run before permit consumption and again at the dispatch boundary. Obsolete or unstable attempts drop without consuming a command slot.
- Existing recovery pending/committed/CAS behavior, reconnect drain behavior, cancellation handling, and lifecycle serialization remain on their prior paths.
- Test doubles record exact physical attempt instants. E2E teardown advances the injected ManualClock through the newly gated stop restore.

## Verification

- Four named Task 5 focused tests: passed individually.
- Added durable-commit, stale late terminal/source token, applied-hold cancellation, jitter-extension, and reconnect-flush regressions: passed.
- `swift test --filter MonitoringOrchestratorTests`: 101 tests, 0 failures.
- Completed physical-hold deterministic stress: 20/20 runs passed.
- Every-command-at-least-one-second deterministic stress: 20/20 runs passed after replacing a test scheduler-yield race with explicit ManualClock sleep-registration barriers.
- `swift test --filter EndToEndPipelineTests`: 3 tests, 0 failures.
- `swift test --parallel`: 515 tests executed, exit 0.
- `swift build -c release`: passed.
- `./scripts/build-app.sh release`: passed.
- `codesign --verify --deep --strict "build/Agent Light.app"`: passed.
- `plutil -lint "build/Agent Light.app/Contents/Info.plist"`: OK.
- `git diff --check`: passed.
- Changed-source security scan: no debug logging, dynamic evaluation, credential/private-key material, hardcoded access secrets, or live integration mutation.
- Scope/artifact scan: only Task 5 production/test/report files changed; no `.orig`, `.rej`, backup artifacts, or orphaned Swift/XCTest processes remain.

## Concerns

- Exact physical timing is verified with deterministic clocks and a recording controller. No live Tuya device was accessed.
- `AgentLightClock.now()` and E2E teardown are necessary supporting changes beyond the three files listed in the brief: the former makes the shared monotonic gate deterministic, and the latter advances ManualClock through the required gated stop restore.

## Next Step

Next phase: Task 6 — bounded recovery-generation rotation.

Ready-to-paste prompt:

```text
Implement Task 6 from .superpowers/sdd/task-6-brief.md using strict TDD. Preserve Tasks 1–5, especially recovery CAS semantics, physical terminal holds, and the shared one-second physical command-attempt gate. Run the named focused tests, full recovery/orchestrator suites, deterministic stress, full parallel suite, release verification, diff/security/orphan scans, write .superpowers/sdd/task-6-report.md, and commit locally without push. Do not touch live bulbs, credentials, HOME configuration, login items, the installed application, or GitHub.
```
