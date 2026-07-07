# Agent Light Final Lifecycle and Reliability Correction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every Critical and Important branch-review finding so Agent Light can enter live manual acceptance without destructive shutdown, unbounded hook latency, stale ownership, incorrect timing, or unbounded recovery storage.

**Architecture:** Separate process shutdown from explicit setup removal, persist a minimal non-secret setup receipt with Keychain-backed credential rollback, and make external boundaries deadline-, rate-, and storage-bounded. Preserve the existing actor/lease/CAS architecture; add narrow persistence and syscall interfaces so each correction has deterministic RED/GREEN coverage.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit, Swift Package Manager, Security/Keychain, ServiceManagement, POSIX Unix datagrams, XCTest; macOS 14+; no external dependencies.

## Global Constraints

- Do not hardcode or log credentials, tokens, access secrets, device IDs, private keys, or live Tuya payloads.
- Do not modify real `~/.codex`, `~/.claude`, or `~/.cursor` files during automated work.
- Do not install/open the app, register a real login item, access the live Wipro bulb, push GitHub, or create a pull request.
- Quit must be non-destructive; only explicit Disconnect/Replace Device may remove verified owned setup.
- Hook processes must fail open within 200 ms; the relay transport budget is 100 ms.
- Existing config permissions are preserved; new config files use `0600`.
- Completed and Error physical holds are measured from successful bulb application: 8 and 12 seconds.
- Every Tuya command attempt, including retries and restores, is separated by at least one second.
- Recovery storage remains bounded to the named active/previous/tombstone/lock set; unknown files are never deleted.
- Keep errors sanitized, UI light-command-free, and branch local/unpushed.

---

### Task 1: Durable setup ownership and Keychain rollback metadata

**Files:**
- Create: `Sources/AgentLightUI/SetupOwnershipReceipt.swift`
- Modify: `Sources/AgentLightUI/AppViewModel.swift`
- Modify: `Sources/AgentLightCore/Persistence/CredentialStore.swift`
- Modify: `Sources/AgentLightApp/AppEnvironment.swift`
- Create: `Tests/AgentLightUITests/SetupOwnershipReceiptTests.swift`
- Modify: `Tests/AgentLightUITests/AppViewModelTests.swift`
- Modify: `Tests/AgentLightUITests/Support/ViewModelHarness.swift`
- Modify: `Tests/AgentLightCoreTests/CredentialStoreTests.swift`

**Interfaces:**
- Produces: `SetupOwnershipReceipt`, `SetupOwnershipStoring`, `FileSetupOwnershipStore`, `PreviousCredentialStoring`, and a write-through `AppOwnershipLedger`.
- Consumes: existing ownership enums, `OutstandingObligation`, `TuyaCredentials`, Keychain service identifiers, and Application Support preparation.

- [ ] **Step 1: Write receipt and Keychain-backup RED tests**

Add focused tests proving a version-1 receipt round-trips without secrets, uses `0600`, atomically replaces an earlier receipt, rejects symlinks/unsafe modes/malformed or unsupported versions, and never authorizes deletion after decode failure. Add Keychain tests proving a separate previous-credential item can save/load/delete a `TuyaCredentials` value without changing the active item. Add a source scan assertion that the JSON receipt contains no access ID, access secret, device ID, or endpoint string.

Use the public contract:

```swift
public struct SetupOwnershipReceipt: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public var integration: PersistentIntegrationOwnership
    public var credential: PersistentCredentialOwnership
    public var login: PersistentLoginOwnership
    public var obligations: Set<OutstandingObligation>
}

public protocol SetupOwnershipStoring: Sendable {
    func load() async throws -> SetupOwnershipReceipt?
    func save(_ receipt: SetupOwnershipReceipt) async throws
    func delete() async throws
}

public protocol PreviousCredentialStoring: Sendable {
    func loadPrevious() throws -> TuyaCredentials?
    func savePrevious(_ credentials: TuyaCredentials) throws
    func deletePrevious() throws
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter SetupOwnershipReceiptTests
swift test --filter CredentialStoreTests
```

Expected: compilation fails because the receipt/store and previous-credential interface do not exist.

- [ ] **Step 3: Implement private atomic receipt storage and Keychain backup**

Implement `FileSetupOwnershipStore` with descriptor-relative regular-file checks, maximum encoded size, temporary-file write, `fsync`, atomic rename, directory sync, and final mode `0600`. Decode only `version == 1`; map all failures to a typed sanitized store error. Do not follow symlinks or delete unknown files.

Extend `KeychainCredentialStore` with a second account key for previous credentials. Reuse the existing allowlist and credential encoding validation. The active and previous items must never overwrite one another.

- [ ] **Step 4: Make `AppOwnershipLedger` load and persist every durable mutation**

Move persistent ownership enums out of `fileprivate` scope and make the ledger accept a store:

```swift
public actor AppOwnershipLedger {
    public init(store: any SetupOwnershipStoring = MemorySetupOwnershipStore())
    func hydrate() async throws
    func snapshot() async -> OwnershipSnapshot
    func update(_ mutation: OwnershipMutation) async throws
}
```

Keep presentation handles, monitoring ownership, active leases, and waiters memory-only. Persist integration, credential, login, and obligation changes before reporting the mutation successful. On write failure, preserve the last durable snapshot and surface a sanitized repair obligation; do not claim ownership that was not persisted.

Update approval and cleanup transactions so replacing preexisting credentials first saves the previous value in the backup Keychain item, then persists `.replacedWithBackup`, then saves the active credential. On explicit successful restoration/delete, clear the backup item and receipt state in crash-recoverable order.

- [ ] **Step 5: Wire production composition and startup hydration**

Construct the production ledger with:

```swift
let ownershipURL = AppIdentity.applicationSupportDirectory
    .appending(path: "setup-ownership-v1.json")
let ownershipStore = FileSetupOwnershipStore(url: ownershipURL)
let ownershipLedger = AppOwnershipLedger(store: ownershipStore)
```

Call ledger hydration after `prepareApplicationSupport()` and before credential-driven onboarding or cleanup decisions. A corrupt/unsupported receipt must present repair/reset guidance, start the relay only when safe, and never infer uninstall authority.

- [ ] **Step 6: Add relaunch and failure regressions, then run GREEN**

Cover: durable receipt survives a new ledger/view model; owned hooks/login/created credentials remain removable after relaunch; replaced credentials restore from the backup item; missing backup creates a typed obligation; receipt save failure cannot advance ownership; corrupt receipt fails closed; preexisting resources remain non-owned.

Run:

```bash
swift test --filter SetupOwnershipReceiptTests
swift test --filter CredentialStoreTests
swift test --filter AppViewModelTests
swift test --filter AppEnvironmentTests
```

Expected: all focused suites pass with no secret material in receipt fixtures.

- [ ] **Step 7: Commit locally**

```bash
git add Sources/AgentLightUI/SetupOwnershipReceipt.swift Sources/AgentLightUI/AppViewModel.swift Sources/AgentLightCore/Persistence/CredentialStore.swift Sources/AgentLightApp/AppEnvironment.swift Tests/AgentLightUITests Tests/AgentLightCoreTests/CredentialStoreTests.swift
git commit -m "fix: persist setup ownership across relaunches"
```

---

### Task 2: Non-destructive Quit and relaunch lifecycle

**Files:**
- Modify: `Sources/AgentLightUI/AppViewModel.swift`
- Modify: `Sources/AgentLightApp/AppEnvironment.swift`
- Modify: `Tests/AgentLightAppTests/AppEnvironmentTests.swift`
- Modify: `Tests/AgentLightUITests/AppViewModelTests.swift`
- Modify: `Tests/AgentLightUITests/Support/ViewModelHarness.swift`

**Interfaces:**
- Produces: `AppViewModeling.shutdownMonitoring()` as the process-lifecycle boundary.
- Consumes: durable ownership from Task 1, `MonitoringOrchestrating.stop()`, and the existing serialized environment lifecycle.

- [ ] **Step 1: Replace destructive-shutdown expectations with RED regressions**

Add tests that seed owned credentials, hooks, login registration, and a durable receipt, then call environment stop, request Quit through an injected termination boundary, and deallocate a ready environment. Each path must assert:

```swift
XCTAssertEqual(events, [.relayStop, .shutdownMonitoring])
XCTAssertEqual(credentials.deleteCount, 0)
XCTAssertEqual(integrations.uninstallCount, 0)
XCTAssertEqual(login.unregisterCount, 0)
XCTAssertEqual(monitor.stopCount, 1)
XCTAssertEqual(await receiptStore.load(), seededReceipt)
```

Add a relaunch test proving startup hydrates the receipt and resumes monitoring without reinstalling hooks or rewriting credentials.

- [ ] **Step 2: Run lifecycle tests and verify RED**

Run: `swift test --filter AppEnvironmentTests`

Expected: existing code records `.disconnect` and destructive dependency calls, so the new expectations fail.

- [ ] **Step 3: Add the narrow shutdown operation**

Extend the protocol and implementation:

```swift
@MainActor
public protocol AppViewModeling: AnyObject, Sendable {
    func shutdownMonitoring() async
    func disconnect() async
}
```

`shutdownMonitoring()` cancels observation, serializes with pause/resume/approval work, stops the monitor exactly once, restores the bulb through `monitor.stop()`, sets memory-only monitoring ownership false, and preserves durable setup ownership and user-facing setup state. It must not call credentials, integrations, login-item mutation, or receipt deletion.

Change `EnvironmentShutdownController` to call `shutdownMonitoring()`. Keep `disconnect()` only for explicit Replace Device/removal actions.

- [ ] **Step 4: Prove race and deinit behavior remains serialized**

Retain and extend blocked-start/stop, queued restart, ready deinit, and exact-once tests. Add stop concurrent with explicit disconnect and ensure the monitor restores once while destructive cleanup remains owned by the explicit action. Verify that a new start waits for shutdown completion and then reuses durable setup.

Run:

```bash
swift test --filter AppEnvironmentTests
swift test --filter AppViewModelTests
```

Expected: all lifecycle, deinit, relaunch, and explicit disconnect tests pass.

- [ ] **Step 5: Commit locally**

```bash
git add Sources/AgentLightUI/AppViewModel.swift Sources/AgentLightApp/AppEnvironment.swift Tests/AgentLightAppTests/AppEnvironmentTests.swift Tests/AgentLightUITests
git commit -m "fix: keep setup intact on app shutdown"
```

---

### Task 3: Bounded fail-open relay delivery and concurrent draining

**Files:**
- Modify: `Sources/AgentLightCore/Relay/UnixDatagramServer.swift`
- Modify: `Sources/AgentLightRelay/main.swift`
- Modify: `Tests/AgentLightCoreTests/UnixDatagramTests.swift`
- Create: `Tests/AgentLightCoreTests/RelayDeadlineTests.swift`
- Modify: `Tests/AgentLightCoreTests/EndToEndPipelineTests.swift`

**Interfaces:**
- Produces: a nonblocking `UnixDatagramSender` with an injectable monotonic deadline/syscall boundary and an owned server handler-task registry.
- Consumes: `RelayEnvelope.maximumEncodedBytes`, socket path validation, and `RelayEventCoordinator` actor serialization.

- [ ] **Step 1: Write deterministic relay deadline RED tests**

Define a testable boundary:

```swift
protocol DatagramSendingSystem: Sendable {
    func openNonblockingDatagramSocket() throws -> Int32
    func send(_ data: Data, descriptor: Int32, address: sockaddr_un) throws -> DatagramSendResult
    func waitUntilWritable(_ descriptor: Int32, deadline: ContinuousClock.Instant) throws -> Bool
    func close(_ descriptor: Int32)
}
```

Tests must prove immediate success, missing socket fail-open, `EAGAIN` then writable retry, repeated `EINTR` without extending the original deadline, full queue timeout at exactly the injected 100 ms budget, one final retry only, and descriptor closure on every exit. A subprocess-level test invokes `AgentLightRelay` against a missing socket and asserts exit status 0 and elapsed time below 200 ms with generous CI measurement tolerance while the deterministic test owns the exact budget assertion.

Add server tests with a blocked first handler and a second datagram; the second must be received before the first handler is released. Stop must cancel/await all owned handler tasks and leave no callback after return.

- [ ] **Step 2: Run relay tests and verify RED**

Run:

```bash
swift test --filter RelayDeadlineTests
swift test --filter UnixDatagramTests
```

Expected: compilation fails on the new boundary, and the slow-handler test times out under serial awaiting.

- [ ] **Step 3: Implement the sender deadline**

Set `O_NONBLOCK` at socket creation. Use one monotonic deadline computed once. Retry `poll` after `EINTR` with the same deadline, never a fresh interval. Treat missing/refused/full/deadline outcomes as a non-delivery result that makes the CLI exit 0. Invalid CLI input and oversized payload remain rejected before sending, without printing sensitive input.

The production sender API becomes:

```swift
public struct UnixDatagramSender: Sendable {
    public static let deliveryBudget: Duration = .milliseconds(100)
    public func sendFailOpen(_ data: Data) -> Bool
}
```

- [ ] **Step 4: Drain server input independently of handlers**

On each received datagram, register an owned child task that calls the async handler. Do not await it in the receive loop. Keep coordinator ordering correct by assigning sequence within the coordinator actor. On stop: close/cancel receive work, cancel handler tasks, await their completion, then unlink only the owned socket inode.

- [ ] **Step 5: Run focused, stress, and E2E GREEN tests**

Run:

```bash
swift test --filter RelayDeadlineTests
swift test --filter UnixDatagramTests
swift test --filter EndToEndPipelineTests
for i in {1..20}; do swift test --filter RelayDeadlineTests || exit 1; done
```

Expected: deterministic deadline paths, concurrent drain, stop ownership, and three provider E2E tests pass in every run.

- [ ] **Step 6: Commit locally**

```bash
git add Sources/AgentLightCore/Relay/UnixDatagramServer.swift Sources/AgentLightRelay/main.swift Tests/AgentLightCoreTests/UnixDatagramTests.swift Tests/AgentLightCoreTests/RelayDeadlineTests.swift Tests/AgentLightCoreTests/EndToEndPipelineTests.swift
git commit -m "fix: bound relay delivery and drain latency"
```

---

### Task 4: Integration trust, pending login approval, and permission preservation

**Files:**
- Modify: `Sources/AgentLightCore/Integrations/IntegrationInstaller.swift`
- Modify: `Sources/AgentLightUI/AppViewModel.swift`
- Modify: `Sources/AgentLightUI/Views/OnboardingView.swift`
- Modify: `Sources/AgentLightUI/Views/SettingsView.swift`
- Modify: `Tests/AgentLightCoreTests/IntegrationInstallerTests.swift`
- Modify: `Tests/AgentLightUITests/AppViewModelTests.swift`
- Modify: `Tests/AgentLightUITests/ViewRenderingTests.swift`
- Modify: `README.md`

**Interfaces:**
- Produces: durable `.pendingApproval` login ownership, Codex trust presentation state, and mode-preserving atomic install.
- Consumes: Task 1 receipt, `LoginItemStatus.requiresApproval`, integration previews/receipts, and AppKit-hosted accessibility controls.

- [ ] **Step 1: Write three boundary RED groups**

Add tests proving:

1. A newly registered `.requiresApproval` item remains registered, is persisted as pending, displays System Settings guidance, and becomes enabled after Retry Status; explicit Disconnect may unregister it.
2. Codex post-install UI renders `/hooks`, the exact integration identifier, and an honest `Trust required` state until explicit confirmation/status refresh. README contains the same sequence and warns that untrusted hooks are skipped.
3. A successful install over a regular `0640` config retains `0640`; `0600` and `0644` are likewise preserved as their permission bits; a newly created config is `0600`; symlinks/non-regular files remain rejected.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter IntegrationInstallerTests
swift test --filter AppViewModelTests
swift test --filter ViewRenderingTests
```

Expected: pending registration is currently compensated away, trust copy/state is absent, and successful replacement reports `0600` instead of the original mode.

- [ ] **Step 3: Preserve pending login registration**

Model persistent login ownership explicitly:

```swift
public enum PersistentLoginOwnership: String, Codable, Sendable {
    case none
    case registered
    case pendingApproval
}
```

Treat `.requiresApproval` as a recoverable success boundary: persist pending ownership, skip unregister compensation, show instructions, and allow a status-only retry. Compensation still unregisters a registration created by the failed transaction for errors other than user approval.

- [ ] **Step 4: Add Codex trust state and instructions**

Add a non-secret integration status dimension for Codex trust (`notRequired`, `required`, `confirmed`). Installation sets `required`; the UI presents the exact `/hooks` steps and never labels Codex monitoring fully active until confirmation. Confirmation does not modify Codex files or trust storage. Keep Claude Code and Cursor unaffected.

- [ ] **Step 5: Preserve destination file mode on commit**

Carry the original regular-file permission bits from the pinned snapshot into the staged inode before rename. For a missing destination use `0600`. Verify the final inode mode equals the intended mode after atomic replacement. Rollback continues restoring original bytes and mode.

- [ ] **Step 6: Run GREEN and static documentation checks**

Run:

```bash
swift test --filter IntegrationInstallerTests
swift test --filter AppViewModelTests
swift test --filter ViewRenderingTests
rg -n '/hooks|Trust required|skipped' README.md Sources/AgentLightUI
```

Expected: all focused tests pass; README and UI contain Codex trust steps; no automated trust mutation exists.

- [ ] **Step 7: Commit locally**

```bash
git add Sources/AgentLightCore/Integrations/IntegrationInstaller.swift Sources/AgentLightUI Tests/AgentLightCoreTests/IntegrationInstallerTests.swift Tests/AgentLightUITests README.md
git commit -m "fix: preserve integration approval boundaries"
```

---

### Task 5: Physical terminal holds and one-second command-attempt gate

**Files:**
- Modify: `Sources/AgentLightCore/Coordination/MonitoringOrchestrator.swift`
- Modify: `Tests/AgentLightCoreTests/MonitoringOrchestratorTests.swift`
- Modify: `Tests/AgentLightCoreTests/Support/TestDoubles.swift`

**Interfaces:**
- Produces: an applied-terminal expiry token and a single command-attempt gate used by apply, retry, and restore.
- Consumes: `AgentLightClock`, current winner generation, retry classifier, and `TuyaLightControlling`.

- [ ] **Step 1: Write timing and rate RED tests**

Using `ManualClock`, assert that a Completed event delayed one second by coalescing remains physically applied for a full additional eight seconds; Error remains for twelve. Add transient failures so a successful retry at or after one second begins the hold only after success. Superseding a terminal event before apply or during its hold must cancel the old expiry.

Record every `apply` and `restore` attempt instant. Assert adjacent attempts are never less than one second apart, including first retry, second retry, apply-to-restore, restore retry, and reconnect flush. Assert an obsolete desired state is not retried once a newer winner exists.

- [ ] **Step 2: Run orchestrator tests and verify RED**

Run:

```bash
swift test --filter MonitoringOrchestratorTests/testCompletedPhysicalHoldStartsAfterSuccessfulApply
swift test --filter MonitoringOrchestratorTests/testErrorPhysicalHoldStartsAfterSuccessfulRetry
swift test --filter MonitoringOrchestratorTests/testEveryCommandAttemptIsAtLeastOneSecondApart
swift test --filter MonitoringOrchestratorTests/testNewWinnerDropsObsoleteRetry
```

Expected: terminal expiry occurs from acceptance and the first transient retry appears at roughly 500–750 ms.

- [ ] **Step 3: Move terminal expiry to successful application**

Do not schedule expiry in event acceptance. Carry the session, sequence/generation, and hold duration with the pending desired command. After `light.apply` succeeds and the committed recovery record is durable, schedule expiry only if the same event is still current. A failed or superseded command schedules nothing.

Use a token containing source/session/sequence/generation so late apply completion cannot expire a newer event.

- [ ] **Step 4: Add a shared command-attempt gate**

Before every physical `apply` or `restore` attempt:

```swift
private func awaitCommandPermit(for generation: UInt64?) async throws {
    let earliest = lastCommandAttempt.map { $0.advanced(by: .seconds(1)) }
    if let earliest { try await clock.sleep(until: earliest) }
    try Task.checkCancellation()
    guard generation == nil || generation == currentGeneration else { throw ObsoleteCommand() }
    lastCommandAttempt = clock.now
}
```

Retry jitter may extend the delay but never shorten the one-second minimum. Recheck current desired generation immediately before consuming a permit and before dispatch.

- [ ] **Step 5: Run focused and stress GREEN tests**

Run:

```bash
swift test --filter MonitoringOrchestratorTests
for i in {1..20}; do swift test --filter MonitoringOrchestratorTests/testCompletedPhysicalHoldStartsAfterSuccessfulApply || exit 1; done
for i in {1..20}; do swift test --filter MonitoringOrchestratorTests/testEveryCommandAttemptIsAtLeastOneSecondApart || exit 1; done
```

Expected: all orchestrator tests and both deterministic stress loops pass.

- [ ] **Step 6: Commit locally**

```bash
git add Sources/AgentLightCore/Coordination/MonitoringOrchestrator.swift Tests/AgentLightCoreTests/MonitoringOrchestratorTests.swift Tests/AgentLightCoreTests/Support/TestDoubles.swift
git commit -m "fix: measure holds and retries at the bulb"
```

---

### Task 6: Bounded recovery-generation rotation

**Files:**
- Modify: `Sources/AgentLightCore/Persistence/MonitoringRecoveryStore.swift`
- Modify: `Tests/AgentLightCoreTests/MonitoringOrchestratorTests.swift`

**Interfaces:**
- Produces: fixed-name active/previous/tombstone/lock generation rotation with existing revision CAS semantics.
- Consumes: pinned parent descriptors, safe metadata validation, atomic rename/fsync helpers, and `MonitoringRecoveryRevision`.

- [ ] **Step 1: Replace indefinite-retention expectations with RED bounded tests**

Add tests that perform hundreds of saves and clears and assert the directory contains at most:

```swift
Set(["monitoring-recovery-v1.json", ".monitoring-recovery.previous", ".monitoring-recovery.tombstone", ".monitoring-recovery.lock"])
```

Unknown files must remain byte-for-byte unchanged. Add crash-point tests for each rotation boundary and two-store-instance races proving load selects the newest valid committed generation, stale revisions cannot clear a newer generation, and no successful operation grows the named set.

- [ ] **Step 2: Run store tests and verify RED**

Run the recovery-store subset of `MonitoringOrchestratorTests`.

Expected: existing tests find random retained names and the repeated-save count exceeds the fixed bound.

- [ ] **Step 3: Implement fixed-slot locked rotation**

Open a stable `0600` lock file in the pinned `0700` parent and acquire an exclusive advisory lock for every save/clear/maintenance mutation. Under the lock:

- validate every known slot with `fstatat(..., AT_SYMLINK_NOFOLLOW)`;
- write and sync a uniquely staged new record;
- atomically replace `previous` with the old active and install the new active;
- on clear, atomically replace the single tombstone with active;
- sync the directory before releasing the lock;
- never enumerate-and-delete or touch unknown names.

On any failure, retain the bounded slot that contains recoverable data and return the existing typed failure. Preserve exact revision compare-and-swap and pinned-parent behavior.

- [ ] **Step 4: Update old retention tests to assert bounded recoverability**

Tests that formerly required random retained artifacts must instead assert the displaced record is decodable from `previous` or `tombstone`, and that later successful maintenance replaces only that internal slot. Keep all symlink, hard-link, parent replacement, owner, mode, fsync, cancellation, and cross-instance tests.

- [ ] **Step 5: Run focused and full store GREEN tests**

Run:

```bash
swift test --filter MonitoringOrchestratorTests
for i in {1..10}; do swift test --filter MonitoringOrchestratorTests/testRecoveryArtifactsRemainBoundedAcrossRepeatedSaveAndClear || exit 1; done
```

Expected: existing recovery safety coverage plus bounded-artifact and cross-instance tests pass.

- [ ] **Step 6: Commit locally**

```bash
git add Sources/AgentLightCore/Persistence/MonitoringRecoveryStore.swift Tests/AgentLightCoreTests/MonitoringOrchestratorTests.swift
git commit -m "fix: bound monitoring recovery generations"
```

---

### Task 7: Deferred boundary coverage, documentation, and final automated gate

**Files:**
- Modify: `Tests/AgentLightProtocolTests/RelayEnvelopeTests.swift`
- Modify: `Tests/AgentLightCoreTests/SessionCoordinatorTests.swift`
- Modify: `Tests/AgentLightCoreTests/JSONNumberTests.swift`
- Modify: `Tests/AgentLightCoreTests/TuyaHTTPTransportTests.swift`
- Modify: `README.md`
- Modify: `.superpowers/sdd/progress.md`
- Create: `.superpowers/sdd/final-correction-report.md`

**Interfaces:**
- Produces: explicit regressions for all deferred boundaries and a verified local manual-acceptance handoff.
- Consumes: corrected implementation from Tasks 1–6 and Task 12 packaging scripts.

- [ ] **Step 1: Add RelayEnvelope exact-boundary and validation tests**

Cover encoded data at exactly 2,048 bytes and 2,049 bytes plus individual invalid version, source, event, empty session, workspace length, status length, and payload validation errors. Assert sanitized typed errors and no oversized allocation path.

- [ ] **Step 2: Add SessionCoordinator guard tests**

Cover stale expiry for a replaced event in the same source/session, equal-sequence reverse insertion with the documented stable lexical tie break, empty coordinator winner, expiry for missing session, older sequence rejection, and terminal expiry that cannot remove a newer same-session event. Change the coordinator key from bare `sessionID` to `(source, sessionID)` so equal identifiers from different providers cannot overwrite one another; add a regression that inserts matching identifiers from Codex and Claude Code and preserves both sessions while newest-event arbitration remains deterministic.

- [ ] **Step 3: Add exact integer limit tests**

Assert successful `JSONNumber.exactInteger` conversion for `String(Int.max)` and `String(Int.min)`, and nil for the immediately adjacent out-of-range decimal strings without floating-point conversion.

- [ ] **Step 4: Add production URLProtocol redirect/final-origin regression**

Use an ephemeral `URLSessionConfiguration` with a test `URLProtocol` to issue a redirect response. Assert the production session delegate rejects both same-origin and cross-origin redirects before following them. Return a response whose final URL differs from the allowlisted request origin and assert `TuyaTransportError.invalidResponseOrigin` before body handling.

- [ ] **Step 5: Run focused boundary suites**

Run:

```bash
swift test --filter RelayEnvelopeTests
swift test --filter SessionCoordinatorTests
swift test --filter JSONNumberTests
swift test --filter TuyaHTTPTransportTests
```

Expected: all explicit boundary and security regressions pass.

- [ ] **Step 6: Update README and correction report**

Document non-destructive Quit versus explicit Disconnect, durable ownership receipt location and non-secret contents, Codex `/hooks` trust, pending login approval recovery, 100 ms relay budget, one-second command attempts, bounded recovery slots, and remaining ad-hoc-signing/live-device limitations. The report records RED/GREEN evidence and explicitly lists unperformed manual checks.

- [ ] **Step 7: Run the complete automated gate from a clean worktree state**

Run:

```bash
swift test --parallel
swift build -c release
./scripts/build-app.sh release
codesign --verify --deep --strict "build/Agent Light.app"
plutil -lint "build/Agent Light.app/Contents/Info.plist"
git diff --check
bash -n scripts/build-app.sh scripts/install-local.sh
git status --short --branch
git remote -v
```

Expected: all tests pass; release and app bundle build; strict signature and plist checks pass; shell and diff checks are clean; branch has no upstream/push. `build/` may be ignored but source worktree must otherwise be clean after commit.

- [ ] **Step 8: Run security and artifact scans**

Scan production source/scripts/docs for debug logging, force casts/tries, fatal traps, dynamic evaluation, TODO/FIXME markers, credential assignments, private-key material, and direct UI bulb commands. Inspect the app bundle for exactly the expected executables and plist. Confirm no orphaned `xctest` process.

- [ ] **Step 9: Commit locally without pushing**

```bash
git add Tests README.md .superpowers/sdd/progress.md .superpowers/sdd/final-correction-report.md
git commit -m "test: close final reliability review gaps"
git status --short --branch
```

Expected: branch is clean, local, and unpushed.

---

## Review and manual acceptance gate

After every task, run independent spec and quality review and fix all Critical/Important findings before proceeding. After Task 7, run a branch-wide review from `a3277c0` to final HEAD.

Only after the automated gate and review pass may the project be described as ready for manual testing. Manual acceptance still requires the user to:

1. install/open the local ad-hoc-signed app;
2. enter credentials locally and record only discovered DP codes, never secrets;
3. approve integrations, trust the Codex hook through `/hooks`, and approve login launch in System Settings if required;
4. verify newest-event arbitration for Codex, Claude Code, and Cursor;
5. verify 8/12-second physical holds and powered-on/off baseline restoration;
6. quit/relaunch and confirm setup persists while the bulb restores;
7. invoke each hook with the app closed and confirm observed completion below 200 ms;
8. inspect agent config semantics and confirm unrelated hooks are unchanged.

Expected limitations: local bundle is ad-hoc signed and unnotarized; fake-Tuya automation does not establish Wipro cloud/device production readiness.
