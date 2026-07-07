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
