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

## Review correction

Review findings were addressed with a second RED/GREEN cycle.

### Additional RED evidence

- A repeated same-session Completed event was deduplicated solely because its color matched the prior command; no second physical apply, committed save, or fresh timer occurred.
- Equivalent repeated Error and cross-source/cross-session Completed/Error regressions exposed the same color-only identity gap.
- After a successful terminal apply followed by committed-save failure, reconnect treated matching bulb color as sufficient and completed without reapplying, committing, or starting a hold.
- With the old command suspended in the final `clock.now()`, a newer accept blocked at its first coordinator await did not change desired generation yet; the stale command consumed the permit and reached the controller.
- Boundary tests initially failed to compile because counter overflow handling and ManualClock saturation did not exist.

### Correction implementation

- Terminal dedup now requires the exact source/session/sequence/winner-generation/lifecycle-generation token to be both the last durably applied terminal identity and the owner of an active terminal timer. A new terminal identity always performs a gated physical command and durable commit before its fresh hold begins.
- Physical success followed by committed-save failure clears terminal identity. Matching-color reconnect therefore reapplies, commits, and only then schedules the hold.
- `acceptanceEpoch` advances synchronously before `accept`'s first await. Physical attempts carry the captured epoch.
- The gate owns validation, permit consumption, and physical dispatch. It revalidates cancellation, generation, acceptance epoch, and stable winner after the rate sleep and again after the final monotonic `now()` suspension; stale work exits before updating the last-attempt instant or calling the controller.
- UInt64 monitoring counters use checked increment with an explicit exhaustion precondition instead of wrapping.
- ManualClock deadline, advancement, and Duration conversion arithmetic saturate at Int64 boundaries.
- Main Completed/Error tests now wait for terminal-timer sleep registration before advancing ManualClock.

### Correction verification

- Correction-focused and original timing/gate tests: 12 tests, 0 failures.
- `swift test --filter MonitoringOrchestratorTests`: 109 tests, 0 failures.
- Completed hold stress: 20/20.
- Shared command gate stress: 20/20.
- Final-permit acceptance-epoch race stress: 20/20.
- Repeated terminal-identity stress: 20/20.
- `swift test --filter EndToEndPipelineTests`: 3 tests, 0 failures.
- `swift test --parallel`: 523 tests executed, exit 0.
- `swift build -c release`: passed.
- `./scripts/build-app.sh release`: passed.
- Code-sign verification and plist validation: passed.

## Final dispatch-timestamp correction

The final review finding was addressed with another deterministic RED/GREEN cycle.

### Final RED evidence

- `testRetryIntervalStartsAtControllerEntryAfterBlockedFinalValidation` blocked the final stable-winner lookup after a rate sleep, advanced `ManualClock` by five seconds while blocked, then released it and forced a transient controller failure.
- Before the correction, the following retry entered the controller at the same instant as the failed attempt. The assertion failed with an observed gap of 0 ns instead of the required 1,000,000,000 ns, proving that the permit timestamp was captured before the blocked async validation rather than at physical dispatch.

### Final correction implementation

- Every physical apply attempt completes stable async winner validation before reading its dispatch instant.
- After the dispatch-time `clock.now()` returns, the actor performs only synchronous checks: task cancellation, lifecycle/throttle/reconnect context, desired generation, acceptance epoch, and exact desired/winner request identity.
- The exact identity includes desired state, full winner event, winner generation, acceptance epoch, throttle operation, lifecycle generation, and reconnect operation. It is checked against the actor's current snapshot and per-session sequence before permit consumption.
- The post-validation instant is stored as `lastCommandAttempt`, followed immediately by controller dispatch in the same actor continuation. No async winner lookup occurs between timestamp capture and controller entry.

### Final correction verification

- New deterministic regression: passed after first failing with a 0 ns retry gap.
- `swift test --filter MonitoringOrchestratorTests`: 110 tests, 0 failures.
- Five dispatch/epoch/gate/hold/terminal-identity regressions: 20/20 stress iterations passed.
- `swift test --filter EndToEndPipelineTests`: 3 tests, 0 failures.
- `swift test --parallel`: 524 tests executed, exit 0 on the final run. An initial run had one unrelated relay subprocess wall-clock threshold failure under parallel load (0.64 seconds versus 0.2 seconds); the isolated test passed in 0.07 seconds and the immediate full rerun passed.
- `swift build -c release`: passed.
- `./scripts/build-app.sh release`: passed.
- `codesign --verify --deep --strict "build/Agent Light.app"`: passed.
- `plutil -lint "build/Agent Light.app/Contents/Info.plist"`: OK.
- `git diff --check`: passed.
- Changed-source scans found no debug logging, dynamic evaluation, hardcoded access-secret/private-key material, or backup/reject artifacts; no orphaned Swift/XCTest processes remain.

## Next Step

Next phase: Task 6 — bounded recovery-generation rotation. Use the ready-to-paste Task 6 prompt above in a fresh chat or agent so this reviewed Task 5 state remains a clean checkpoint.

## Cross-session terminal-invalidation correction

The cross-session review finding was addressed with a deterministic RED/GREEN cycle.

### Cross-session RED evidence

- `testUnrelatedTerminalExpiryPreservesWinnerSuspendedAtFinalPermitNow` applied terminal A with an active hold, selected B from a different source and session, and suspended B at final `clock.now()`.
- A then expired completely, including coordinator removal and snapshot refresh, while B remained the exact winner with unchanged desired generation.
- The global terminal-mutation epoch incorrectly invalidated B. Before the correction, only A entered the controller at t=1 second; B never entered at t=9 seconds.

### Cross-session implementation

- Terminal mutation epochs are keyed by exact `(AgentSource, sessionID)` identity instead of one global counter.
- `PhysicalCommandRequest` captures only its winner identity key and that key's current epoch. Synchronous post-`clock.now()` validation compares only the captured winner key.
- Valid expiry advances only the expiring token's identity epoch before token removal or the first await. Same-terminal expiry still invalidates a suspended reapply; unrelated expiry cannot invalidate the current winner.
- Epoch tombstones are retained while their identity appears in the current snapshot, owns an active terminal timer, or has the active physical request. Snapshot refresh and request completion prune obsolete entries; lifecycle terminal reset clears the map.

### Cross-session verification

- Same-terminal invalidation and unrelated-terminal preservation regressions: 2 tests, 0 failures.
- Six timer/dispatch/epoch/gate/terminal-identity regressions: 20/20 stress iterations passed.
- `swift test --filter MonitoringOrchestratorTests`: 112 tests, 0 failures.
- `swift test --filter EndToEndPipelineTests`: 3 tests, 0 failures.
- `swift test --parallel --num-workers 2`: 526 tests executed, exit 0. A four-worker run hit only the known unrelated relay subprocess wall-clock threshold (0.78 seconds versus 0.2 seconds); the isolated test passed in 0.070 seconds before the clean two-worker run.
- `swift build -c release`: passed.
- `./scripts/build-app.sh release`: passed.
- Code-sign verification and plist validation: passed.

## Next Step

Next phase: Task 6 — bounded recovery-generation rotation. Use the ready-to-paste Task 6 prompt above in a fresh chat or agent so this reviewed Task 5 state remains a clean checkpoint.

## Final timer-invalidation correction

The final terminal-expiry race was addressed with a deterministic RED/GREEN cycle.

### Timer-invalidation RED evidence

- `testTerminalExpiryInvalidatesReconnectReapplySuspendedAtFinalPermitNow` established an applied Completed winner with an active hold, made the connection fail on a different session, restored the terminal as current, and started a forced reconnect reapply after a current-state mismatch.
- The reapply was suspended in its final `clock.now()`. Hold expiry synchronously removed the terminal token, then blocked in coordinator expiry before snapshot or desired-generation refresh.
- Before the correction, releasing `clock.now()` allowed the stale terminal reapply to consume the t=9-second permit and enter the controller. The test expected two applies and attempt instants `[1s, 2s]`, but observed three applies and `[1s, 2s, 9s]`.

### Timer-invalidation implementation

- Physical command identity is now represented by `PhysicalCommandRequest`, captured when the winner is selected before any apply-path suspension.
- The request includes the terminal-mutation epoch and exact active terminal-timer token in addition to desired state, full winner event, acceptance epoch, winner generation, lifecycle generation, throttle operation, and reconnect operation.
- A valid terminal expiry advances the checked terminal-mutation epoch synchronously before removing the timer token or reaching its first await.
- The post-`clock.now()` synchronous gate now requires the captured terminal epoch and, when present, the exact timer token and durable terminal identity to remain current. Expiry therefore drops stale work before permit consumption or controller entry even while snapshot refresh is still blocked.
- Event-driven terminal cancellation remains protected by the synchronously advanced acceptance epoch; lifecycle bulk cancellation remains protected by lifecycle generation.

### Timer-invalidation verification

- New deterministic timer-expiry regression: passed after first failing with an extra t=9-second controller entry.
- Related dispatch, terminal identity, durable hold, reconnect, and shared-gate set: 11 tests, 0 failures.
- `swift test --filter MonitoringOrchestratorTests`: 111 tests, 0 failures.
- Six timer/dispatch/epoch/gate/hold/terminal-identity regressions: 20/20 stress iterations passed.
- `swift test --filter EndToEndPipelineTests`: 3 tests, 0 failures.
- `swift test --parallel --num-workers 4`: 525 tests executed, exit 0 on the final post-refactor run. Unbounded parallel runs intermittently hit the known unrelated relay subprocess wall-clock threshold under saturation (0.78–0.83 seconds versus 0.2 seconds); the isolated test passed in 0.067 seconds. One post-refactor orchestrator run also stalled in an unrelated ownership-recapture test, which passed isolated in 0.003 seconds and on the immediate full 111-test rerun.
- `swift build -c release`: passed.
- `./scripts/build-app.sh release`: passed.
- Code-sign verification, plist validation, and `git diff --check`: passed.

## Next Step

Next phase: Task 6 — bounded recovery-generation rotation. Use the ready-to-paste Task 6 prompt above in a fresh chat or agent so this reviewed Task 5 state remains a clean checkpoint.
