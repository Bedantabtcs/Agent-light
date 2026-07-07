# Task 2 Report: Non-destructive Quit and relaunch lifecycle

**Date:** 2026-07-07
**Base:** `189671f690888b6a7ad38a37d5dfbd60e42ce520`

## Result

- Added `AppViewModeling.shutdownMonitoring()` as the process-lifecycle boundary.
- App stop, injected Quit, startup failure cleanup, and ready-environment deinit stop relay acceptance before calling the non-destructive monitoring shutdown.
- Shutdown cancels observation, restores the bulb through exactly one `monitor.stop()`, clears only memory-owned monitoring state, and retains credentials, verified hook ownership, login registration, Keychain backup authority, durable receipt, obligations, and the explicit setup phase.
- Explicit `disconnect()` and Replace Device remain destructive and retain Task 1's verified receipt, emergency recovery, durable lease, and Keychain backup behavior.
- Approval, pause, resume, repair, shutdown, and explicit disconnect serialize through shared operations and the durable ownership lease. Concurrent shutdown/disconnect restores once; only the explicit action performs setup cleanup.
- Startup tracks approval as the only mutation-bearing phase that must finish before cancellation. A lifecycle guard prevents an uncancelled approval startup from restarting the relay after shutdown has begun, while recovery/verifying cancellation remains immediate.
- Relaunch hydrates a complete durable receipt, resumes monitoring, and starts a new observation without reinstalling hooks or rewriting credentials.
- Quit uses an injected application-termination closure in tests; XCTest is never terminated.

## TDD evidence

- Environment RED: three lifecycle tests observed `[.relayStop, .disconnect]` instead of `[.relayStop, .shutdownMonitoring]`.
- Quit injection RED: `AppEnvironment` rejected the missing `terminateApplication` argument.
- View-model RED: shutdown called stop, login unregister, credential delete, and verified hook uninstall; it deleted the receipt and reset phase to onboarding. Relaunch remained onboarding with zero monitor starts.
- Approval-order RED: stop could not claim shutdown while approval was blocked.
- Post-approval relay RED: the realistic approval/shutdown waiter exposed a relay start after shutdown had begun.
- Each RED was observed before its corresponding production change.

## Verification

- `swift test --filter AppEnvironmentTests`: 21 passed, 0 failures.
- `swift test --filter AppViewModelTests`: 139 passed, 0 failures.
- Lifecycle stress: 20 full AppEnvironment runs and 20 focused shutdown/relaunch/race runs passed.
- `swift test --parallel`: 477 tests executed, exit 0.
- `swift build -c release`: exit 0.
- `git diff --check`: clean.
- Production security scan: no added debug logging, dynamic evaluation, private-key material, canary credentials, or hardcoded access secrets.
- Scope scan: only the five Task 2 implementation/test files plus this report changed.
- Process scan: no orphaned AgentLight XCTest process.

No HOME configuration, real credentials, login item, hook file, bulb, installed app, browser, or GitHub state was accessed or mutated.

## Review correction: generation and path-level lifecycle proof

The Task 2 review identified two registration-window races and missing path-level integration coverage. The correction adds:

- A monotonic monitoring lifecycle generation. Shutdown and explicit disconnect invalidate it synchronously before any suspension. Pause, resume, and approval claim the current generation synchronously and recheck it after pre-registration suspension points.
- A completed shutdown remains authoritative after `shutdownTask` is cleared. Stale pause/resume entrants blocked at hydration cannot register an operation or call the monitor.
- Registered pause/resume operations remain owned by shutdown and finish their explicit phase transition before the bulb restore. Explicit Connect and startup ownership synchronization create a new generation for intentional reactivation.
- Approval registers its operation before its first suspension or refuses a generation already invalidated by shutdown. Shutdown awaits the underlying approval/compensation driver directly; cancellation-aware waiter return is not treated as child completion.
- `AppEnvironment` no longer uses the pre-registration `startupApprovalInProgress` Boolean. Startup cancellation and shutdown run concurrently, so a not-yet-entered approval sees the advanced view-model generation while an already-registered approval is awaited through compensation.
- A deterministic pre-approval test boundary is injected only through the internal environment initializer.
- Real `AppEnvironment` + real `AppViewModel` path tests use only fake system boundaries and seed credentials, verified owned hooks, login registration, and a durable receipt. They cover stop, injected Quit, ready deinit, concurrent explicit Disconnect, queued restart, pre-approval stop, and Quit waiting for canceled-approval compensation.

### Correction RED evidence

- Pause/resume hydration-window tests first failed compilation on the missing deterministic gate. With the gate present, pause and resume each called the monitor once after shutdown completed; resume also reactivated monitoring.
- The environment pre-approval-entry test failed compilation because `beforeApproval` did not exist.
- The real path tests failed compilation until the real environment/view-model fixture and system-boundary fakes were added.
- The first complete AppViewModel run exposed over-broad invalidation: registered pause/resume operations lost their phase transition, and explicit Connect after cleanup could not approve. The generation checks were narrowed to pre-registration entrants and Connect now activates a fresh generation.
- The first release build failed because the DEBUG hydration gate lacked a non-DEBUG no-op. The release-only compile branch was added and reverified.

### Correction verification

- `swift test --filter AppEnvironmentTests`: 29 passed, 0 failures.
- `swift test --filter AppViewModelTests`: 143 passed, 0 failures.
- Real path-level lifecycle tests: 7 passed, 0 failures.
- Stress: 20 full AppEnvironment runs and 20 focused generation/approval runs passed.
- `swift test --parallel`: 489 tests executed, exit 0.
- `swift build -c release`: exit 0.
- `git diff --check`: clean.
- Production security and scope scans: clean.
- Process scan: no orphaned AgentLight XCTest process.

The correction did not access or mutate HOME configuration, live credentials, login registration, hook files, a physical bulb, an installed app, browser state, or GitHub.

## Concerns

- None blocking Task 2. Live launch-at-login relaunch and physical bulb restore remain manual acceptance checks outside automated implementation.
- This batch is ready for review/testing, not assessed as production ready.

## Next Step

Next phase: Task 3 — bounded fail-open relay delivery and concurrent draining. Use a fresh chat or agent because Task 3 changes an independent transport boundary.

Test this batch with:

```bash
swift test --filter AppEnvironmentTests
swift test --filter AppViewModelTests
swift test --parallel
swift build -c release
git diff --check
```

Expected failure mode: any ordinary stop, Quit, or ready deinit that invokes `disconnect()`, mutates durable setup, restores more than once, or starts the relay after shutdown begins must fail the lifecycle regressions.

Ready-to-paste prompt:

```text
Implement Task 3 from .superpowers/sdd/task-3-brief.md using strict TDD. Preserve Task 1 durable ownership and Task 2 non-destructive lifecycle guarantees. Do not touch HOME configs, live credentials/login items/hooks/bulbs, install or open the app, or use GitHub. Run focused deadline/socket/E2E tests, deterministic stress, the full parallel suite, release build, diff/security checks, write .superpowers/sdd/task-3-report.md, and commit locally without push.
```
