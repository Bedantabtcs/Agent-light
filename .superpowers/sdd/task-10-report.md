# Task 10 Report — Agent Light application state

Date: 2026-07-07
Base HEAD: `5364a68b4094f22196a08b0cb0481e451fd48f2a`

## Scope

- Added the `AgentLightUI` library and `AgentLightUITests` target.
- Added a main-actor observable `AppViewModel` for onboarding, integration approval, monitoring, pause/resume, repair, and disconnect.
- Added deterministic canary-only fakes with explicit call order, async barriers, typed failures, stream subscription tracking, and rollback counts.

## Protocol findings

- `IntegrationInstalling` has no separate public verification or restoration method. Its concrete `install()` performs post-write verification and internal atomic rollback. The view model uses `uninstall()` only after an install is known to have committed.
- `IntegrationError.committedWithCleanupFailure` means installation committed, so approval compensation uninstalls the owned entries. `IntegrationError.rollbackFailed` is not safe to compensate destructively; the view model preserves `repairRequired` across disconnect until `repairIntegrations()` succeeds.
- `LoginItemControlling` exposes system approval indirectly: `setEnabled(true)` returns while `isEnabled()` remains false. The view model maps that outcome to the sanitized `loginApprovalRequired` presentation case and does not claim ownership of or disable a login item it did not enable.
- `MonitoringOrchestrating.updates()` includes the current snapshot in the production implementation. The view model still reads `currentSnapshot()` first, then maintains one cancellable stream subscription guarded by a monitor epoch.

## State and safety behavior

- Connection fields are trimmed and validated before `TuyaCredentials` construction. Only HTTPS origins without user info, query, fragment, or a non-root path are accepted.
- Connect generations cancel and invalidate verification or preview completions from older attempts.
- Approval order is install/verify, load prior credential state, save, enable login, start monitoring, read current snapshot, and subscribe.
- Approval compensation runs in reverse order and only for steps known to have completed. The original allowlisted presentation error is retained if compensation also fails.
- Monitoring never starts before successful integration installation and durable credential persistence.
- Pause, resume, repair, approval, and disconnect share in-flight work for duplicate calls. Opposing pause/resume requests serialize, and disconnect waits for canceled approval/lifecycle work before cleanup.
- Disconnect cancels observation, stops owned monitoring, disables the approved login item, deletes owned credentials, and uninstalls known owned integrations. Unsafe integration rollback state remains repair-required.
- Presentation errors contain no associated strings and unknown errors map to `operationFailed`.

## TDD evidence

### Initial RED

Command:

```text
swift test --filter AppViewModelTests
```

Result: exit 1. Compilation failed because `ConnectionDraft`, `TuyaConnectionVerifying`, and `AppViewModel` were missing. This was the expected feature gap.

### Reentrancy RED/GREEN

Command:

```text
swift test --filter AppViewModelTests/testDisconnectDuringCancellationIgnoringInstallWaitsThenCompensates
```

RED: exit 1; phase was `integrationReview` instead of `onboarding`, and uninstall count was 0 instead of 1.

GREEN: exit 0; 1 test passed after disconnect awaited canceled approval and install completion was recorded before the cancellation check.

### Lifecycle serialization RED/GREEN

Command:

```text
swift test --filter AppViewModelTests/testResumeRequestedDuringPauseRunsAfterPauseCompletes
```

RED: exit 1; phase remained `paused`, resume count was 0, and no active subscription remained.

GREEN: exit 0; 1 test passed after opposing pause/resume operations were serialized.

### Integration compensation RED/GREEN

Command:

```text
swift test --filter 'AppViewModelTests/test(CommittedInstallFailure|UncertainInstallRollback)'
```

RED: exit 1; committed install failure was not uninstalled, and uncertain rollback returned to integration review instead of repair state.

GREEN: exit 0; 2 tests passed after committed and uncertain integration failures were handled separately.

### Repair-state preservation RED/GREEN

Command:

```text
swift test --filter AppViewModelTests/testUncertainInstallRollbackPreservesRepairStateWithoutDestructiveCompensation
```

RED: exit 1; disconnect incorrectly cleared the uncertain integration state to onboarding.

GREEN: exit 0; 1 test passed after uncertain ownership was retained as `repairRequired` without destructive cleanup.

## Verification

- `swift test --filter AppViewModelTests`: exit 0; 22 tests passed, 0 failures.
- `swift test`: exit 0; 280 tests passed, 0 failures.
- `swift build -c release`: exit 0; production configuration linked `AgentLight` successfully.
- `git diff --cached --check`: exit 0 after staging, including all new files.
- Secret/debug scan: no credential-pattern, debug logging, dynamic evaluation, or underlying error-description matches in the new source and tests.

## Security review

- Test credentials and metadata use explicit `CANARY_*` values only.
- No real secrets, credential-like literals, dynamic evaluation, debug logging, or underlying error descriptions were added.
- The view model never interpolates dependency errors into presentation state.

## Concerns for review

- Repair after `IntegrationError.rollbackFailed` requires explicit user action because the current installer protocol cannot prove ownership or restore an exact pre-attempt snapshot.
- System login approval cannot be distinguished from other non-enabled service statuses through the public protocol; the exposed behavior is intentionally conservative and sanitized.
