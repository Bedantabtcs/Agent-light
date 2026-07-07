# Agent Light Final Lifecycle and Reliability Correction Design

**Date:** 2026-07-07  
**Status:** Approved approach; written-spec review pending  
**Scope:** Correct the Critical and Important findings from the branch-wide review before live credentials, hook installation, login registration, or bulb acceptance testing.

## Goals

- Make ordinary app shutdown non-destructive while still restoring the bulb.
- Preserve enough ownership information across relaunches to maintain and explicitly remove Agent Light resources safely.
- Guarantee that source-agent hooks fail open within 200 ms when the app is unavailable or overloaded.
- Close integration, login-approval, file-mode, terminal-hold, recovery-retention, and command-rate gaps.
- Add deterministic regressions for every review finding and the four deferred minor test gaps.

## Non-goals

- No GitHub push, pull request, notarization, Developer ID distribution, or production-readiness claim.
- No automatic Codex hook trust, System Settings approval, credential entry, HOME config mutation, app installation, or live bulb operation during automated implementation.
- No change to the approved palette, app width, provider list, or newest-event-wins product behavior.

## Considered approaches

### 1. Comprehensive durable correction — selected

Separate shutdown from explicit setup removal, persist a minimal ownership receipt, enforce bounded relay and storage behavior, and correct timing/rate semantics. This supports launch-at-login and safe relaunch without asking the user to repeat onboarding.

### 2. Minimal lifecycle patch

Make Quit non-destructive and add a relay deadline, but keep ownership process-local and retain recovery artifacts indefinitely. This would permit stale resources and unsafe cleanup after relaunch, so it is insufficient for live testing.

### 3. Reapproval after every launch

Treat every resource as preexisting after relaunch and require setup approval again. This avoids durable metadata but conflicts with automatic launch and creates ambiguous uninstall behavior.

## Architecture

### Shutdown and explicit removal

`AppEnvironment.stop()` and ready-environment deinitialization will use a new non-destructive view-model lifecycle operation, `shutdownMonitoring()`. It will:

1. stop relay acceptance;
2. stop monitoring and restore the captured bulb baseline exactly once;
3. keep Keychain credentials, installed hooks, ownership receipt, and login-item registration;
4. leave the next process able to recover and resume normal startup.

`disconnect()` remains an explicit destructive user action for Replace Device or removal. It will stop monitoring, restore the bulb, remove only resources proven owned by Agent Light, and update the ownership receipt transactionally. Quit must never call `disconnect()`.

The existing environment lifecycle state machine remains responsible for coalescing start/stop/deinit work. Its shutdown controller will depend on the narrower non-destructive operation so ready deinitialization cannot accidentally erase setup.

### Durable ownership receipt

`AppOwnershipLedger` will persist a versioned, Codable receipt at:

`~/Library/Application Support/Agent Light/setup-ownership-v1.json`

The receipt contains only non-secret ownership facts:

- credential ownership: none, created, or replaced, with the previous credentials stored in Keychain rather than plaintext in the receipt;
- per-source integration ownership and the exact installed Agent Light marker/fingerprint needed to distinguish owned, partial, preexisting, and uncertain state;
- login registration ownership or pending-approval state;
- outstanding repair obligations.

Monitoring leases, presentation handles, and in-flight operation leases remain memory-only.

The receipt is written atomically with mode `0600` inside the existing `0700` Application Support directory. Production composition loads it before ownership synchronization. Corrupt or unsupported receipts fail closed into a repair/reset path; they are never silently treated as proof of ownership. Credentials remain exclusively in Keychain. An older replaced credential value, when needed for rollback, is stored as a second Keychain item scoped to the same service rather than encoded into JSON.

Integration ownership is revalidated against current config contents before uninstall or repair. A receipt authorizes examination, not blind deletion: removal still requires the exact Agent Light integration marker and expected structural fingerprint. External changes downgrade ownership to partial/uncertain and surface repair instead of deleting unrelated content.

### Relay fail-open deadline

`AgentLightRelay` will enforce the deadline itself so every generated hook command inherits it without depending on shell-specific `timeout` tools.

- Create the Unix datagram sender socket as nonblocking.
- Attempt `sendto` immediately.
- On `EAGAIN`/`EWOULDBLOCK`, poll only until a monotonic deadline of 100 ms, retry once when writable, then exit successfully without delivery.
- Missing socket, refused socket, full queue, malformed input, and deadline expiry all remain fail-open for the source agent.
- Encoding/validation still rejects oversized or invalid envelopes before socket work.

The 100 ms transport budget leaves process-startup margin beneath the 200 ms hook acceptance limit. Tests will use an injectable syscall/clock boundary to prove success, full-queue timeout, interruption handling, and total bounded waiting without relying on wall-clock flakiness.

The server receive loop will drain datagrams promptly and dispatch handler work without awaiting each handler inline. Ordering and sequence assignment remain serialized by `RelayEventCoordinator`; the socket loop itself does not become the processing bottleneck. In-flight handler tasks are owned and canceled/awaited during server stop.

### Codex hook trust onboarding

Agent Light cannot write Codex's independent trust decision. Integration approval and Settings will therefore show a Codex-specific post-install action:

1. open Codex;
2. run `/hooks`;
3. review and trust the exact Agent Light hook command and integration identifier;
4. return to Agent Light and confirm or retry status.

The README repeats this requirement and states that Codex may silently skip untrusted hooks. Agent Light does not claim Codex monitoring is active merely because the config entry exists.

### Login-item pending approval

`requiresApproval` is a durable, non-failure state. After `SMAppService.register()` returns that status:

- retain the registration;
- persist `pendingApproval` ownership;
- do not run unregister compensation;
- show the exact System Settings instruction and a Retry Status action;
- transition to enabled when a later status check reports enabled;
- allow explicit Disconnect to unregister the pending item if it is still proven owned.

Compensation unregisters only registrations created by the current failed transaction when the failure is unrelated to required user approval.

### Config-file permissions

Successful replacement preserves the existing regular file's permission bits. New config files use `0600`. Staging and verification use the intended final mode before the atomic swap. Symlinks and unsupported file types remain rejected. Rollback continues to restore both bytes and original mode.

### Physical terminal holds

Completed and Error expiry for bulb behavior starts only after the corresponding color command succeeds. The command-window delay and transient retries do not consume the 8-second or 12-second physical hold.

- Accepted terminal events remain eligible winners while awaiting application.
- A newer event for the same session supersedes the pending terminal event and cancels any eventual expiry.
- After successful apply, schedule the session expiry for 8 or 12 seconds.
- If apply ultimately fails, do not start a false physical-hold timer; retain the newest desired state for reconnect.
- UI status may show the accepted terminal event immediately, but tests distinguish UI acceptance time from physical applied-hold time.

### Bounded recovery artifacts

The recovery store will replace random, permanently retained artifacts with a bounded generation set under one store mutation lock:

- one active record;
- one previous record used for crash recovery;
- one clear tombstone when needed;
- one stable lock file.

Save rotates active to previous and atomically installs the new active record. Clear rotates active to the single tombstone. Replacing a previous/tombstone slot atomically discards the older slot rather than creating a new random pathname. All operations remain directory-relative, reject symlinks/non-regular files, preserve `0600`, fsync required data and directory boundaries, and keep revision compare-and-swap semantics. Cross-instance tests will prove that bounded rotation does not weaken winner selection or stale-writer rejection.

The directory may contain at most the fixed active/previous/tombstone/lock set after successful maintenance. Unknown files are never removed.

### One-command-per-second rate limit

The orchestrator will apply one shared monotonic command gate to every outbound Tuya command attempt, including retries. The next attempt begins no earlier than one second after the previous attempt began. Retry jitter is added after the minimum interval, not used to shorten it.

Newest desired state continues to coalesce while waiting. Before each retry, the orchestrator rechecks whether the attempted state is still current; obsolete retries are dropped. Baseline restore commands use the same gate when they follow a failed or recent apply.

## Error handling and security

- Shutdown failures restore as much as possible and surface sanitized local errors without converting Quit into destructive cleanup.
- Ownership receipt corruption cannot authorize deletion.
- No receipt, fixture, log, README example, or test contains Tuya credentials or private keys.
- Relay deadline expiry returns success to the source agent and records no debug output.
- Codex trust and macOS login approval remain explicit user decisions.
- Recovery maintenance touches only exact internal names in the private Application Support directory.

## Testing strategy

Each correction begins with a focused failing regression and is reviewed independently.

Required regressions:

1. Quit and ready deinit restore the bulb but retain credentials, hooks, login registration, and durable ownership.
2. Relaunch loads ownership; explicit Disconnect removes only still-verified owned resources; corrupt receipts fail closed.
3. Relay full-queue and missing-socket paths exit within the injected 100 ms budget; server slow handlers do not stop socket draining; stop owns handler tasks.
4. Codex integration UI and README expose `/hooks` trust instructions and do not report trust without confirmation.
5. `requiresApproval` survives compensation and can transition to enabled or explicit removal.
6. Existing `0640` hook configs remain `0640` after successful install; new files are `0600`.
7. Completed/Error remain physically applied for exactly 8/12 seconds after successful command application, including a delayed/retried apply.
8. Recovery files remain within the fixed bound across repeated saves, clears, crashes, and cross-instance CAS races.
9. All command attempts, including retries/restores, are separated by at least one second and obsolete retries are dropped.
10. Deferred coverage: RelayEnvelope exact size/error branches; SessionCoordinator stale same-session expiry, reverse-insertion tie break, and guard paths; successful `Int.max`/`Int.min` parsing; production URLProtocol redirect delegate and final-origin rejection.

Final automated gate:

```bash
swift test --parallel
swift build -c release
./scripts/build-app.sh release
codesign --verify --deep --strict "build/Agent Light.app"
plutil -lint "build/Agent Light.app/Contents/Info.plist"
git diff --check
```

Live credentials, actual hook installation/trust, login approval, launch-at-login relaunch, physical bulb timing, and powered-on/off restore remain manual acceptance checks after the automated gate and independent review pass.

## Acceptance criteria

- Ordinary Quit never removes successful setup.
- Relaunch can safely resume and later remove only verified Agent Light–owned resources.
- Every hook invocation remains fail-open beneath 200 ms under missing/full socket conditions.
- Codex trust and macOS pending login approval are represented honestly and recoverably.
- Existing config permissions are preserved.
- Physical terminal holds are measured from successful application.
- Recovery storage is bounded.
- No Tuya command attempts occur less than one second apart.
- All focused and full automated checks pass, independent review reports no Critical or Important findings, and the branch remains local and unpushed.
