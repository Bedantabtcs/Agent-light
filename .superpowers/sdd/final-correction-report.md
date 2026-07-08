# Final Correction Task 7 Report

## Status

Implemented from base `0ac4033e0916be6f0378fcdc12cfd50a3e76289e`; ready for independent review. Manual testing remains gated on that review. This is not a production-readiness assessment.

Review corrections from `dd69981549d24d4c187735e990ac42f9844384a9` are included below and remain ready for independent re-review.

## Corrections

- Added a bounded `RelayEnvelope.decodeValidated(from:)` entry point. Payloads above 2,048 bytes are rejected before JSON decoding; malformed payloads and unknown sources map to sanitized typed errors. The production relay coordinator now uses this boundary.
- Keyed session coordination, latest-sequence guards, and terminal timers by `(source, sessionID)`. Same-named sessions from different providers remain independent, stale expiry is source-qualified, and fallback still obeys the shared one-second physical-command gate.
- Added exact `Int.min`/`Int.max` and adjacent overflow coverage without changing the existing integer parser.
- Added real ephemeral-URLSession/custom-URLProtocol coverage proving the production delegate rejects same-origin and cross-origin redirects before a target request. A mismatched final response URL now throws `TuyaTransportError.invalidResponseOrigin`.
- Closed Task 4 minors: pending-login approval is compensated if monitoring then fails; Codex confirmation does not mutate the receipt and a fresh view model returns to `Trust required`; README checks the literal integration ID.
- Removed the scheduler-sensitive subprocess `<0.2s` assertion. The subprocess test owns silent fail-open behavior only; injected monotonic syscall tests remain the exact 100 ms transport-budget oracle.
- Added a running-server deinit regression for immediate owned-socket unlink and eventual callback release. It makes no claim that deinit awaits task completion; explicit `stop()` remains authoritative.
- Expanded README coverage for non-destructive Quit, explicit Disconnect, the non-secret durable ownership receipt, Codex `/hooks` trust, pending login approval, the relay budget, one-second command attempts, bounded recovery slots, and local signing limitations.

## Review corrections

- Replaced post-buffer `URLSession.data(for:)` origin validation with a production `URLSessionDataDelegate` path. Per-task state is registered before resume; HTTP type and final origin are validated in `didReceive response`; invalid responses return `.cancel` before body buffering; only `.allow` responses can append data.
- The malicious final-origin and non-HTTP regressions make the custom protocol attempt body delivery, then assert zero data-delegate callbacks, zero buffer callbacks, and zero accepted bytes.
- The delegate removes task state and resumes its continuation exactly once from task completion. Cancellation before or after task installation cancels the same registered task safely.
- Redirect rejection remains on the same production delegate. Every delegate integration test now has a one-second expectation or polling bound, so a wiring regression fails instead of hanging.
- Added deprecated public compatibility shims: `TuyaHTTPTransportError` aliases `TuyaTransportError`, and source-less `expireTerminalState(sessionID:sequence:)` expires only one unique exact terminal match. Ambiguous provider identities fail closed.
- Routed every invalid RelayEnvelope scalar through `decodeValidated(from:)` with sensitive sentinels and exact typed-error assertions. Added equal-sequence, identical-session cross-provider source tie coverage.

## RED evidence

- `swift test --filter RelayEnvelopeTests` failed to compile because `decodeValidated`, `payloadTooLarge`, `invalidPayload`, and `invalidSource` did not exist.
- `swift test --filter SessionCoordinatorTests` failed to compile because terminal expiry did not accept `source`.
- `swift test --filter TuyaHTTPTransportTests` failed to compile because `TuyaTransportError.invalidResponseOrigin` did not exist.
- The first unbounded parallel run exposed the same-ID cross-provider gap: `testSupersededLateTerminalCommitCannotExpireNewerSourceEvent` remained waiting after 557/559 tests. A bounded focused reproduction then failed with the preserved Codex session visible but its physical fallback blocked by bare-session latest-sequence guards. Migrating orchestrator guards and timers to `(source, sessionID)` made the focused regression pass.
- Exact integer limits and Task 4 minor coverage passed immediately, confirming existing behavior rather than requiring production changes.
- Review RED: the malicious final-origin test could not observe pre-body acceptance because the transport had no delegate body boundary; the existing implementation necessarily received the complete body before throwing. The new test first failed to compile on the missing `acceptedBodyObserver` seam.
- Review compatibility RED: tests failed to compile because `TuyaHTTPTransportError` and source-less terminal expiry no longer existed.

## Automated verification

- Focused boundary suites after review correction: RelayEnvelope 6, SessionCoordinator 13, JSONNumber 4, TuyaHTTPTransport 9; all passed.
- Affected suites: RelayEventCoordinator 1, RelayDeadline 8, UnixDatagram 12, MonitoringOrchestrator 112, AppViewModel 145, ViewRendering 21; all passed.
- TuyaClient 26 passed against the new production data delegate. The nine delegate tests passed 20 consecutive repetitions.
- Missing-socket subprocess regression passed ten consecutive `--skip-build` repetitions. One focused execution took 0.786 seconds under scheduling load, confirming wall clock is unsuitable for the 100 ms transport contract while the injected deadline regression remained exact.
- Initial `swift test --parallel` verification completed 559/559 twice. The review-corrected full suite completed 566/566 with exit 0.
- `swift build -c release`: passed.
- `./scripts/build-app.sh release`: passed.
- `codesign --verify --deep --strict "build/Agent Light.app"`: passed.
- `plutil -lint "build/Agent Light.app/Contents/Info.plist"`: OK.
- `swift package dump-package`, `bash -n scripts/build-app.sh scripts/install-local.sh`, and `git diff --check`: passed.
- Bundle inventory contains `Info.plist`, `MacOS/AgentLight`, `MacOS/AgentLightRelay`, and the generated code-signature resources. Exactly the two expected executable files are present.
- Signature inspection reports `Identifier=com.bbatchas.agentlight`, `Signature=adhoc`, and no Team ID.
- No orphaned `xctest` or `swift-test` process remained at the final scan.
- The branch has no configured remote or upstream and was not pushed.

## Security scan

- No production debug logging, force casts, force tries, dynamic evaluation, private-key material, new TODO/FIXME markers, or new fatal traps were found.
- Two pre-existing invariant traps remain unchanged: durable lease cancellation and monitoring counter exhaustion.
- Documentation contains only explicit dummy credential examples from the implementation plan; no credential-like production literals or canary secrets were found.
- AgentLightUI contains no direct Tuya controller construction or physical bulb command calls. Production composition remains in AgentLightApp.

## Manual checks not performed

The automated work did not install or open the app, read or modify live credentials, touch HOME hook configuration, register or approve login items, open Codex or a browser, operate a bulb, or mutate GitHub.

Manual acceptance still requires:

1. Install/open the local ad-hoc-signed bundle and verify menu-bar behavior.
2. Enter credentials locally, verify the Wipro/Tuya device, and record only discovered DP codes.
3. Approve integrations, trust the exact Codex hook through `/hooks`, and approve login launch in System Settings if required.
4. Verify newest-event arbitration across Codex, Claude Code, and Cursor, including identical session IDs from different providers.
5. Verify physical Completed/Error holds of 8/12 seconds and powered-on/off baseline restoration.
6. Quit/relaunch and confirm setup persists while bulb restoration remains correct.
7. Invoke each installed hook with the app closed and confirm end-to-end completion below 200 ms.
8. Inspect all agent configs and confirm unrelated hook semantics remain unchanged.

## Limitations

- The bundle is ad-hoc signed and unnotarized.
- Automated fake-Tuya coverage does not establish live Wipro cloud/device readiness.
- Explicit `stop()` provides the server task-await guarantee; running-server deinit is best-effort cancellation and ownership cleanup only.

## Whole-branch review correction

The follow-up correction from `b81c8c586797` closes fail-closed stored-credential startup, app-launch startup ownership, Tuya authentication-retry command spacing, physical terminal deadline persistence/recovery, committed setup-receipt cleanup outcomes, non-destructive launch-at-login opt-out, masked identifier relaunch hydration, and committed whitespace findings. Detailed RED/GREEN evidence is in `final-review-fix-report.md`.

Fresh verification completed 584/584 parallel tests, the release build, release app bundle, strict ad-hoc signature validation, plist/package/shell checks, whole-range diff validation, and security/artifact/remote scans. Independent re-review and all previously listed manual checks remain outstanding.
