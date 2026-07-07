# Task 10 Report — Agent Light application state

Date: 2026-07-07
Base HEAD: `5364a68b4094f22196a08b0cb0481e451fd48f2a`

## Scope

- Added the `AgentLightUI` library and `AgentLightUITests` target.
- Added a main-actor observable `AppViewModel` for onboarding, integration approval, monitoring, pause/resume, repair, and disconnect.
- Added deterministic canary-only fakes with explicit call order, async barriers, typed failures, stream subscription tracking, and rollback counts.

## Protocol findings

- `IntegrationInstalling` exposes authoritative install receipts plus read-only retained-artifact verification. Its concrete install still performs post-write verification and internal atomic rollback; artifact verification never deletes files.
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
- All UI polling and scheduler-yield synchronization was replaced with call-number continuations, stream subscription/termination barriers, observation expectations, and waiter-count barriers inside the shared operation/dependency test seams.

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

---

## Final Findings Follow-up

Date: 2026-07-07
Starting commit: `384aad7fba0d740f1f1e0e2e20c854be8e3b0981`

- All committed cleanup error forms now normalize to the persistent artifact obligation in uninstall/compensation/disconnect paths. Mixed adoption treats a malformed authoritative receipt as invalid and retains mixed repair state.
- `AppOwnershipLedger` is now an explicit process-environment dependency injected into every view model. Replacement view models call `synchronizeOwnership()` to hydrate repair state and can retry credential, login, integration, and artifact cleanup without persisting secrets outside process memory.
- If approval cancellation has no original presentation error but cleanup leaves obligations, the view model presents `integrationConflict` or `operationFailed` instead of repair-required state with no recovery error.
- DEBUG action-entry barriers now prove the second connect enters while preview is blocked and resume enters while pause is blocked. Shared waiter tests establish initiating caller, waiter count one, then noninitiating caller and waiter count two before cancellation/release.
- Process limitation: the ledger intentionally does not survive process termination. Prior credentials remain only in process-owned Sendable memory. Task 12/manual acceptance must verify behavior for app termination during cleanup and document any remaining manual recovery steps; no secret is written to UserDefaults or a plaintext file.

### RED/GREEN evidence

- RED: legacy and receipt-bearing committed uninstall errors became uninstall retry; GREEN: both retain artifact cleanup.
- RED: malformed mixed-adoption receipt cleared repair state; GREEN: mixed obligation remains.
- RED: replacement view model had no synchronization API; GREEN: shared-ledger hydration and retries pass.
- RED: canceled approval cleanup failure entered repair-required with nil error; GREEN: sanitized integration conflict is presented.
- RED: connect/resume ordering tests had no method-entry proof; GREEN: action-entry barriers are awaited before dependency release.

### Verification

- `swift test --filter AppViewModelTests`: 76 passed, 0 failures.
- `swift test --filter IntegrationInstallerTests`: 32 passed, 0 failures.
- `swift test --filter LoginItemControllerTests`: 8 passed, 0 failures.
- Shared-ledger and ordering subset: 20 consecutive runs; 8 tests per run, 0 failures.
- `swift test`: 345 passed, 0 failures.
- `swift build -c release`: exit 0.
- `git diff --cached --check`: exit 0 with no output.
- Security/orphan scan: no polling/yields, removed boolean repair/login APIs, force casts/tries, debug output, dynamic evaluation, TODO/FIXME markers, production credential literals, or orphaned old API references.
- Test credential scan: explicit `CANARY_*` values and intentional blank validation fields only.

### Remaining concern

- Mixed preexisting integration ownership cannot be destructively separated with the current installer API. Agent Light preserves all entries and requires explicit repair/adoption instead of removing entries that may predate this approval attempt.

---

## Re-review Correction Batch

Date: 2026-07-07
Starting commit: `0a1e1bb8bfe99e786146c5a1ff0496fbbe52276a`

### Integration commit authority and cleanup

- Added `IntegrationInstallReceipt` with per-source `fresh`, `fullyPreexisting`, or `partial` ownership derived from the exact snapshots passed to the atomic writer. Preview data is display-only and no longer controls compensation.
- Preserved source compatibility for existing `IntegrationInstalling` conformers with a conservative default receipt. The concrete installer overrides it with authoritative ownership.
- A committed installation that cannot remove staging or rollback material now carries its receipt and creates a distinct `integrationArtifactCleanup` obligation.
- Split integration obligations into uninstall retry, rollback repair, mixed adoption, and artifact cleanup. Repair dispatches only the action appropriate to the obligation; artifact-only state remains visible because no safe automatic artifact-removal API exists.
- Partial-event drift is classified as mixed ownership and is adopted by an authoritative install rather than destructively uninstalled.

### Lifecycle ownership and cancellation

- Replaced raw task handles with a shared-operation owner. Duplicate callers await one driver; canceling one waiter returns promptly without canceling a driver still used by another waiter, while the final canceled waiter cancels the driver.
- External dependency waits capture dependencies and immutable inputs, then weakly commit to the view model. Blocked verify, install, pause, resume, repair, and disconnect-cleanup calls no longer retain the view model.
- Driver completion, rather than a caller returning, clears the in-flight handle. This prevents a canceled waiter from opening a duplicate-operation window.
- Test synchronization now uses barriers inside fake dependency methods. The standalone invocation barrier was removed.

### Login and presentation behavior

- Login cleanup clears ownership only when the disable transition reports `notRegistered` or `notFound`. Unknown or still-registered postconditions retain `loginRegistrationCleanup` for retry.
- Added direct HTTP 401 and 403 presentation tests; both map to `invalidCredential` without exposing dependency error text.

### RED/GREEN evidence

- Commit-time TOCTOU RED: a fresh preview followed by externally appearing hooks caused one unsafe uninstall. GREEN: the authoritative install receipt classified them as preexisting and uninstall count remained zero.
- Login postcondition RED: a disable transition ending in `unknown` cleared ownership. GREEN: the obligation remains until a later terminal absence status.
- Caller-cancellation RED: a blocked verifier retained the view model and the caller did not return. GREEN: the caller returns before release and the weak reference is nil.
- Focused split-action tests prove uninstall retry calls only uninstall, rollback calls only repair, mixed adoption calls install, and artifact-only repair performs no destructive action.

### Final verification

- `swift test --filter AppViewModelTests`: 57 passed, 0 failures.
- `swift test --filter IntegrationInstallerTests`: 27 passed, 0 failures.
- `swift test --filter LoginItemControllerTests`: 8 passed, 0 failures.
- Shared-waiter plus cancellation/deinit subset: 20 consecutive runs passed.
- `swift test`: 321 passed, 0 failures.
- `swift build -c release`: exit 0.
- `git diff --check`: exit 0 with no output.
- Security/orphan scan: no polling/yields, external invocation barrier, debug output, dynamic evaluation, TODO/FIXME markers, commented-out code, production credential literals, or live references to the removed aggregate integration obligation.

### Remaining concern

- Artifact cleanup remains a typed, visible manual obligation because the installer intentionally exposes verification but no automatic deletion. Manual cleanup can now be verified and the obligation cleared safely.

---

## Final Ledger Lease Correction Batch

Date: 2026-07-07
Starting commit: `f23c014ff486e596e25da2dd6b21bb0cdec82a0b`

### Hydration and single-flight ownership

- Every actionable public view-model operation reloads the ownership ledger before dependency work. Locally non-actionable duplicate connect/approval calls are gated or join their existing shared operation.
- `AppViewModeling` now exposes `synchronizeOwnership()`. Explicit synchronization cancels and awaits local connect work before applying the final leased snapshot, and it waits for an active approval transaction rather than applying an intermediate state.
- `AppOwnershipLedger` now grants FIFO token leases. Approval and durable disconnect cleanup hold one lease across all external awaits and final ledger mutation; queued approvals revalidate ownership after acquiring the lease.
- Integration repair also derives its plan from a snapshot taken after lease acquisition and retains that lease through the external repair and final ledger update.
- Disconnect hydrates and cleans inside its durable dependency-owned lease. Caller cancellation and view-model deallocation do not cancel required cleanup.
- Replacement view models wait for an active cleanup lease. A replacement connect cannot verify against an intermediate snapshot, and a replacement disconnect observes the completed cleanup without repeating monitor, login, credential, or integration side effects.

### Compatibility and construction

- Restored the four-argument `IntegrationPreview` initializer. It delegates to the ownership-aware initializer with conservative `hadOwnedEntries: false` behavior.
- Restored the five-dependency `AppViewModel` initializer. It creates a private process-memory ledger for source compatibility.
- The six-dependency initializer with an explicitly shared `AppOwnershipLedger` remains the recommended construction for replacement view models. The five-dependency convenience initializer cannot coordinate ownership across separately constructed view models because each instance owns a distinct ledger.
- The ledger remains process-memory-only and intentionally does not persist credentials or cleanup state across application termination.

### RED/GREEN evidence

- RED: a previously synchronized replacement performed a second verification after another view model committed a cleanup obligation. GREEN: the action rehydrates and remains repair-required without verification.
- RED: a replacement connect ran while old cleanup held a blocked uninstall, then lost the final obligation. GREEN: it waits for the lease, performs no new dependency action, and applies the committed uninstall-retry state.
- RED: two view models queued approval and both installed, saved credentials, enabled login, and started monitoring. GREEN: the queued approval revalidates under the lease and adopts the completed transaction without repeating side effects.
- RED: explicit synchronization during blocked local connect left phase `verifying`. GREEN: it cancels and awaits the connect generation, rejects the stale completion, and returns to onboarding.
- GREEN: synchronization during blocked approval waits for the final transaction; replacement disconnect joins blocked cleanup with exactly one stop, login disable, credential delete, and uninstall.

### Final verification

- `swift test --filter AppViewModelTests`: 83 passed, 0 failures.
- `swift test --filter IntegrationInstallerTests`: 33 passed, 0 failures.
- `swift test --filter LoginItemControllerTests`: 8 passed, 0 failures.
- Cross-instance hydration/lease subset: 20 consecutive runs; 6 tests per run, 0 failures.
- `swift test`: 353 passed, 0 failures.
- `swift build -c release`: exit 0.
- `git diff --check`: exit 0 with no output.
- Security scan: no polling/sleeps, debug output, dynamic evaluation, TODO/FIXME markers, force tries/casts, private-key markers, or non-canary test credentials in changed files.

### Remaining concern

- The compatibility initializer isolates its ledger by design. Callers that can replace a view model while work is active must inject and retain one shared `AppOwnershipLedger` through the six-dependency initializer.

---

## Second Re-review Correction Batch

Date: 2026-07-07
Starting commit: `56c48e9d464daa1f99cc04232f9e1a3432036e87`

### Receipt and artifact safety

- `IntegrationInstallReceipt` now validates exactly one entry for every `AgentSource`; duplicates and omissions are invalid and resolve conservatively to mixed ownership.
- Restored source-compatible `committedWithCleanupFailure([String])` and added a separate receipt-bearing committed error for the concrete installer. Legacy committed errors create mixed plus artifact obligations and are never destructively uninstalled.
- Added `verifyArtifactCleanup()`. The concrete implementation scans only known configuration directories and exact Agent Light staged/rollback filename prefixes; it never removes files. Existing conformers receive a conservative `false` default.
- Uninstall failures preserve `artifactCleanupFailure` across approval compensation, abandoned install/disconnect coordination, direct disconnect, and uninstall retry. Artifact failures are never downgraded to an ordinary uninstall retry.
- Artifact repair clears the obligation only after verification confirms absence. Present artifacts and inspection errors remain repair-required.

### Dependency-owned lifecycle

- Added a Sendable ownership ledger actor. Installation, credential replacement/creation, login registration, monitoring ownership, and cleanup obligations are recorded immediately after each completed step.
- Approval is one dependency-only transaction through install, credentials, login, monitor start, initial snapshot, and compensation. It returns a typed result and only weakly commits presentation state.
- Disconnect creates an independent cleanup task from the ledger and pending operation completions. Caller cancellation or view-model deallocation does not cancel required monitor, login, credential, or integration cleanup.
- Blocked monitor start, initial snapshot, compensation stop, integration uninstall, and disconnect-awaiting-approval tests prove the view model deallocates while ledger cleanup continues.

### Shared operation and pause safety

- Shared waiters now register before pre-cancellation is observed. A pre-canceled sole waiter unregisters immediately and cancels the zero-waiter driver.
- Added deterministic waiter-count barriers inside `SharedOperation`; duplicate approval, pause, resume, repair, and disconnect tests wait for two registered callers before dependency release.
- Initiating and noninitiating approval waiter cancellation both preserve one shared driver while another waiter remains.
- Pause cancellation now returns a typed outcome. If resume compensation fails, the view model cancels observation, commits paused state, and presents a sanitized offline error instead of claiming monitoring.

### RED/GREEN evidence

- Receipt/error RED: missing validation APIs and legacy committed-error construction failed compilation. GREEN: validation, conservative invalid ownership, and both error forms pass.
- Artifact RED: compensation/disconnect downgraded artifact failures, invalid receipts entered monitoring, and verified absence could not clear the obligation. GREEN: all six focused behaviors pass.
- Pause RED: failed cancellation compensation left phase monitoring with no error. GREEN: phase is paused, observation is reset, and the error is offline.
- Pre-cancel RED root cause was registration after the cancellation check; the regression test now observes dependency cancellation and view-model deallocation.

### Verification

- `swift test --filter IntegrationInstallerTests`: 32 passed, 0 failures.
- `swift test --filter LoginItemControllerTests`: 8 passed, 0 failures.
- `swift test --filter AppViewModelTests`: 71 passed, 0 failures.
- Shared-waiter, cancellation, ledger, and deinit subset: 20 consecutive runs; 15 tests per run, 0 failures.
- `swift test`: 340 passed, 0 failures.
- `swift build -c release`: exit 0.
