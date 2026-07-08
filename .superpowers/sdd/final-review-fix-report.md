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
