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
- The original boolean login-boundary concern below was resolved by the review correction batch, which added explicit status and transition ownership.

---

## Review Correction Batch

Date: 2026-07-07
Starting commit: `117f46adc6488c7c5e67c6221a457b0f5f7dc8ed`

### Ownership and cleanup

- Approval now retains whether credentials were newly created or replaced a prior item. Compensation and disconnect delete only newly created credentials and restore replaced credentials.
- Credential delete/restore failures remain retryable as typed `credentialDelete` or `credentialRestore` obligations.
- Login cleanup uses Task 9 transition ownership. Pre-enabled and preexisting approval-pending registrations are never disabled; a registration created by the approval attempt is unregistered even when it enters system-approval state.
- Integration previews now carry exact per-source `hadOwnedEntries` metadata from the installer parser. Fresh installs are uninstallable; fully preexisting installs are preserved; mixed installs are preserved with an explicit integration obligation.
- `rollbackFailed` cannot be approved again. Explicit repair is required and clears only the integration obligation.
- The boolean repair flag was replaced with `Set<OutstandingObligation>` covering integration, credential restore/delete, and login registration cleanup.

### State and observation

- Connect is accepted only from onboarding or integration review with no outstanding obligations. Calls during verification, approval, monitoring, pause, or repair state are ignored without disturbing monitoring.
- The observation task has an ID and epoch, clears only its own handle on natural completion, marks the connection disconnected/idle, and permits resubscription.
- The stream loop holds the view model only while applying an update; deinitialization cancels all owned tasks and does not leave the stream subscribed.
- HTTP 401/403 map to invalid credentials, 408 and 5xx plus selected URL/transport failures map offline, 429 maps rate-limited, capability errors map unsupported, and unknown errors remain sanitized.
- All UI polling and scheduler-yield synchronization was replaced with call-number continuations, stream subscription/termination barriers, observation expectations, and explicit invocation barriers.

### Review RED evidence

- `swift test --filter LoginItemControllerTests`: exit 1; missing status and transition ownership types.
- `swift test --filter IntegrationInstallerTests/testPreviewReports`: exit 1; `IntegrationPreview.hadOwnedEntries` missing.
- Ownership matrix compile RED: `AppViewModel.outstandingObligations` and typed obligation cases missing.
- Natural stream/deinit focused run did not complete because the completed observation handle retained the model and prevented resubscription/cancellation.

### Review GREEN and final verification

- `swift test --filter LoginItemControllerTests`: 8 passed, 0 failures.
- `swift test --filter IntegrationInstallerTests`: 24 passed, 0 failures.
- `swift test --filter AgentLightUITests`: 44 passed, 0 failures.
- Concurrency/stale-stream subset: 20 consecutive runs passed under a 60-second process alarm.
- `swift test`: 305 passed, 0 failures.
- `swift build -c release`: exit 0.
- `git diff --cached --check`: exit 0 with no output.
- Security/orphan scan: no polling/yields, removed boolean repair/login APIs, force casts/tries, debug output, dynamic evaluation, TODO/FIXME markers, production credential literals, or orphaned old API references.
- Test credential scan: explicit `CANARY_*` values and intentional blank validation fields only.

### Remaining concern

- Mixed preexisting integration ownership cannot be destructively separated with the current installer API. Agent Light preserves all entries and requires explicit repair/adoption instead of removing entries that may predate this approval attempt.
