# Final Whole-Branch Review Fix Report

## Status

Implementation complete from base `b81c8c586797`; ready for independent re-review. This is not a production-readiness assessment. No live credentials, HOME agent configuration, login item, app installation, browser, bulb, GitHub remote, or pushed branch was accessed or mutated.

## Corrections

- Startup with stored Keychain credentials now auto-resumes only through an authenticated durable setup receipt. Missing, corrupt, reset, or incomplete ownership stops at integration review and never installs hooks or registers login automatically.
- Application startup is triggered once by an app-lifecycle controller created in `AgentLightApp.init`; menu presentation no longer owns startup.
- `TuyaClient` has an injected monotonic command-request gate at the command POST transport boundary. Authentication-retry command POSTs are one second apart; token requests are exempt; slow responses do not add a second delay.
- Completed/Error expiry is scheduled immediately after successful physical apply. Recovery records optionally persist non-secret apply/deadline metadata with backward-compatible decoding. Late persistence is cleared after expiry or supersession and cannot regain physical authority.
- Setup receipt mutations distinguish complete commits from committed cleanup-pending outcomes. Post-commit cleanup sync failures retain the new/missing authoritative path and one fixed authenticated cleanup artifact; the ledger follows disk authority.
- Settings exposes an accessible native launch-at-login switch. Explicit opt-out handles enabled and pending-approval registration, retains all other setup, and fails closed/retries when login or receipt persistence fails.
- Approved relaunch hydrates only masked Access ID and Device ID from Keychain without invoking connection verification.
- Committed trailing whitespace in the final correction design was removed.

## RED evidence

- App lifecycle tests failed to compile on the missing launch controller. The stored-credential regression then showed the old `.approve` call and setup mutation path.
- Tuya client tests failed to compile on the missing injected command clock/gate.
- Terminal recovery tests failed to compile on missing applied/deadline metadata and wall-clock injection. The blocked-persistence test initially failed because expiry waited for the blocked throttle save.
- Receipt tests failed to compile on the missing committed mutation outcome. Prior store behavior rolled authoritative paths back after cleanup failure.
- View-model tests failed to compile on the missing launch-at-login opt-out. The rendered test could not find an accessible login switch.
- The opt-out persistence-failure regression initially remained in Monitoring with no visible repair obligation after the login item had already been disabled.
- Whole-range diff validation identified trailing whitespace in the approved final lifecycle design.

## Focused GREEN evidence

- `AppEnvironmentTests`: 33 passed.
- `TuyaClientTests`: 28 passed, including command retry at 0/1 seconds and no extra delay after a two-second response.
- `MonitoringOrchestratorTests`: 114 passed sequentially after physical-timer, retry, supersession, blocked-save, and recovery corrections.
- `AppViewModelTests`: 147 passed before the final persistence-failure regression; the added persistence failure/retry test passed focused.
- `ViewRenderingTests`: 22 passed with the login switch identifier, label, checkbox role, pending-state rendering, and target-action invocation.
- Setup ownership committed save/delete fault tests, relaunch consistency tests, terminal metadata public API tests, and masked-ID relaunch tests passed focused.

## Final automated gate

- Stress: stored-credential lifecycle 20/20, auth command gate 20/20, blocked-persistence physical hold 20/20, receipt cleanup fault 10/10, and login opt-out persistence retry 10/10.
- `swift test --parallel`: 584/584 passed with exit 0.
- `swift build -c release` and `./scripts/build-app.sh release`: passed.
- `codesign --verify --deep --strict`, plist lint, package dump, and shell syntax: passed.
- Whole-range diff check, bundle inventory, source security scan, orphan-process check, and remote/upstream scan: passed. The bundle contains exactly `Info.plist`, `AgentLight`, `AgentLightRelay`, and signature resources; its signature is ad hoc with no Team ID.

## Manual limitations

The following remain manual: app install/open, Keychain credential entry, HOME hook installation and semantic inspection, Codex `/hooks` trust, macOS login approval/relaunch, live Wipro/Tuya command timing, powered-on/off baseline restoration, end-to-end hook latency, Developer ID signing, notarization, and formal readiness assessment.

## Last-correction addendum

The final independent review identified four additional edge cases. All four were reproduced with deterministic failing tests before correction:

- The Tuya command gate reserved a future slot before timestamp/nonce request construction and could charge canceled work. Request construction now finishes first; the gate records an actual start only after its final monotonic-clock and cancellation checks, then invokes transport in the same actor continuation. Blocked timestamp, blocked nonce, canceled waiter, auth refresh, and slow-response coverage passes.
- Recovery accepted wall-clock values before `appliedAt` and allowed a completed record to inherit the error state's 12-second ceiling. Backward dates now restore immediately, and terminal metadata is validated against the command's original completed/error hold of 8/12 seconds.
- A transient ownership-receipt write failure was inserted into the durable obligation set, so a successful launch-at-login opt-out retry could not leave Repair. Transient persistence provenance is now in-memory and clears only after a successful write; durable/manual/corrupt obligations remain independent. Monitoring and Paused retry paths plus rendered warning removal pass.
- A post-commit displaced-receipt rename failure could leave a new UUID artifact on every attempt. Save/delete now use fixed authenticated `stage` and `cleanup` slots. Twelve consecutive injected rename failures remained bounded to the active file plus one stage file, and a later successful save removed all artifacts while preserving relaunch authority.

### Last-correction verification

- Focused suites: `TuyaClientTests` 31/31, `MonitoringOrchestratorTests` 117/117, `AppViewModelTests` 149/149, and receipt/render suites 46/46.
- Stress: Tuya construction/cancellation cases 20/20; backward/excessive recovery, monitoring/paused login retry, and fixed-artifact rename failure cases 10/10 each.
- Full gate: `swift test --parallel` 593/593; release build, app bundle build, strict code-sign verification, plist lint, package dump, shell syntax, diff check, bundle inventory, and source security scans passed.
- The bundle remains ad hoc signed with no Team ID. Live app, HOME/login/Keychain/bulb, Developer ID, notarization, and formal readiness checks remain manual and were not performed.

## Final login-reconciliation addendum

The final UX review found that a successful login-item unregister followed by receipt-write failure left the switch Off with no durable relaunch recovery path. Deterministic model and rendered tests first failed on the missing compensation/retry API and accessibility identifier.

- After unregister succeeds but receipt persistence fails, Agent Light now attempts to restore the registration so macOS state again matches the durable receipt. A successful compensation returns the rendered switch to On, keeps Monitoring/Paused and all setup intact, and presents only a sanitized operation error. A second rendered Off action retries the full opt-out.
- When compensation cannot confirm Enabled, Settings renders an accessible **Retry saving disabled login state** action. It persists login ownership as none only when macOS currently reports Not registered/Not found, never calls unregister/register again, clears only the transient receipt failure on success, and returns to Monitoring/Paused.
- Ownership synchronization now compares durable login ownership with current macOS status. A fresh view model/ledger derives an actionable repair when the receipt says owned but the item is absent, resumes retained monitoring, and offers the same receipt-only retry without enabling anything automatically.
- Requires approval and Unknown states fail closed. Retry does not clear durable authority until macOS confirms the item is absent; pending compensation can instead be disabled again through the switch.
- README recovery guidance and the stable accessibility identifier list now document/expose the reconciliation flow.

### Final login-reconciliation verification

- Focused: `AppViewModelTests` 152/152, `ViewRenderingTests` 25/25, `AppEnvironmentTests` 33/33, and setup-receipt/login-controller tests 31/31.
- Stress: compensation/retry/relaunch/ambiguous model cases 20/20; rendered switch/button/relaunch target-action cases 10/10.
- Full gate: `swift test --parallel` 598/598 before the final release and artifact verification pass.

## Latched login-reconciliation correction

The last review found that the reconciliation flag could remain latched after macOS status changed, and that Unknown/Approval required incorrectly exposed an absent-state receipt action. RED tests first failed on the missing ambiguous-state model and then demonstrated the stale action/state.

- Login reconciliation is now recomputed from the current durable login ownership and current macOS status whenever ownership presentation synchronizes. Durable-owned plus Not registered/Not found is the only state that exposes **Retry saving disabled login state**.
- Durable Registered plus Unknown/Approval required is an ambiguous status reconciliation. Settings renders read-only **Retry Status** guidance and never offers the receipt-only action. Pending Approval plus Approval required remains the existing approval flow.
- When a status retry later observes Enabled with durable Registered ownership, reconciliation and its sanitized error clear and the app returns to Monitoring or Paused based on actual monitoring activity, with zero register/unregister calls.
- Receipt retry rechecks status before writing, so an absent-to-ambiguous change cannot use a stale button to clear authority.
- Successful disconnect, explicit receipt reset, and new approval recompute from their new ownership snapshots, preventing stale reconciliation from surviving a new setup.

### Latched-state verification

- Focused: `AppViewModelTests` 156/156, `ViewRenderingTests` 27/27, and AppEnvironment/setup-receipt/login-controller tests 64/64.
- Added model and rendered target/action coverage for Unknown-to-Enabled, Approval-required-to-Enabled, Paused restoration, pending approval, disconnect/new setup cleanup, button absence, and zero login mutations.
- Stress: derived-state model cases 20/20 and rendered action-selection cases 10/10. Full parallel gate: 604/604.

## Read-only status and guarded transient-repair correction

The remaining review found two coupling problems: ambiguous **Retry Status** still shared the explicit-enable API, and later Enabled compensation relied on an unconstrained transient-flag clear. RED tests failed on the missing read-only refresh boundary.

- `refreshLaunchAtLoginStatus()` now reads current macOS status, recomputes reconciliation, and performs no login registration mutation. Both rendered **Retry Status** controls use it; switch On remains the separate explicit enable action.
- Unknown/Approval-required changing to Not registered/Not found now swaps the rendered status action for **Retry saving disabled login state**, with unchanged register/unregister counts and durable authority retained until that receipt retry succeeds.
- The ownership ledger clears its memory-only persistence-repair overlay only when an authenticated durable receipt still owns a registered/pending login item and status is confirmed Enabled. The operation performs no receipt write/delete.
- Durable/manual repair obligations and unsafe/reset-eligible ownership failures remain untouched. If status becomes absent, the transient marker remains until the receipt-only persistence update commits.
- Later Enabled status clears the transient repair/error and restores Monitoring or Paused without login mutations; rendered and model tests cover both compensation outcomes and explicit switch enablement.

### Read-only/guarded-clear verification

- Focused: `AppViewModelTests` 161/161, `ViewRenderingTests` 30/30, and AppEnvironment/setup-receipt/login-controller tests 66/66.
- Stress: status-refresh/ledger cases 20/20 and rendered split-action cases 10/10.
- Full parallel gate: 614/614 after stabilizing deterministic waits exposed by the first saturated parallel run.

## Pending-approval receipt-promotion correction

The final receipt review found that macOS could report Enabled while durable ownership remained Pending Approval. RED model and hosted-render tests showed that read-only status refresh left the pending receipt unchanged, and an injected promotion-write failure did not expose a retryable reconciliation.

- Read-only status refresh now promotes durable login ownership from Pending Approval to Registered only after macOS reports Enabled. It never calls register or unregister.
- A failed promotion write retains Pending Approval authority, the transient persistence-repair overlay, and the rendered **Retry Status** action. A later retry writes only the receipt promotion, clears only the transient error, and restores Monitoring or Paused.
- Relaunch/synchronization treats Pending Approval plus Enabled as unresolved until the promotion commit succeeds. After promotion, later Approval required/Unknown statuses use Registered reconciliation semantics.
- The prior pending-approval test now exercises status refresh, and hosted Settings tests invoke the rendered button's exact target/action pair while asserting unchanged enable/disable counts.
- The rendered immediate receipt-retry path also exposed a publication-order race: its retry flag could appear while phase was still Monitoring. The receipt-only retry now accepts Monitoring, Paused, or Repair while still requiring its specific flag and the serialized ownership lease.

### Pending-promotion verification

- Focused: `AppViewModelTests` 163/163, `ViewRenderingTests` 31/31, and AppEnvironment/setup-receipt/login-controller selected tests 41/41.
- Stress: promotion model cases 20/20; pending-success, promotion-failure, and adjacent immediate-retry rendered cases 10/10.
- Full gate: `swift test --parallel` 617/617; release build, app-bundle build, strict code-sign verification, plist lint, package dump, shell syntax, diff check, bundle inventory, source security scan, orphan-process check, and remote/upstream scan passed.
- The bundle remains ad hoc signed with no Team ID. No live app, HOME/login/Keychain/bulb, GitHub remote, Developer ID, notarization, or formal readiness checks were performed.
