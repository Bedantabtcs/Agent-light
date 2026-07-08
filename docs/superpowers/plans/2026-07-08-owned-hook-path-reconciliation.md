# Owned Hook Path Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep Claude Code, Codex, and Cursor hooks bound to the canonical installed Agent Light relay without overwriting unverified configuration.

**Architecture:** Receipt-verified repair becomes idempotent: matching hooks produce no writes, while a verified stale path produces one atomic update and a new receipt. Startup runs that health reconciliation after ownership hydration and before the relay socket starts. The local installer safely replaces and launches `~/Applications/Agent Light.app`.

**Tech Stack:** Swift 6.2, Swift Package Manager, Swift Concurrency, XCTest, POSIX atomic file operations, JSON hook configuration, Bash, macOS code signing.

## Global Constraints

- Canonical runtime: `~/Applications/Agent Light.app`.
- Mutate only commands proven by a valid persisted integration receipt.
- Preserve unrelated hooks and original permission bits.
- Matching paths perform no hook-file or receipt write.
- Changed owned hooks and unsafe files fail closed into repair-required state.
- Reconciliation resolves before the Unix relay socket starts.
- Do not change credentials, Tuya configuration, integration IDs, payload limits, or privacy boundaries.

---

### Task 1: Make verified repair idempotent

**Files:**
- Modify: `Tests/AgentLightCoreTests/IntegrationInstallerTests.swift`
- Modify: `Sources/AgentLightCore/Integrations/IntegrationInstaller.swift`

**Interfaces:**
- Consumes: `IntegrationInstaller.repair(using:)`, `IntegrationInstallReceipt`, `verifiedChanges(using:transform:)`.
- Produces: stale owned paths return an updated receipt; matching hooks return the original receipt without calling the atomic writer.

- [ ] **Step 1: Add a failing stale-path/no-op test**

Install hooks with `/old/AgentLightRelay`, repair with `~/Applications/Agent Light.app/Contents/MacOS/AgentLightRelay`, and assert all three owned command sets migrate while unrelated JSON and modes remain unchanged. Repair again through a counting `IntegrationFileOperating` test double and assert its replacement count is zero.

Core assertions:

```swift
let oldReceipt = try await oldInstaller.installWithReceipt()
let currentReceipt = try await currentInstaller.repair(using: oldReceipt)
XCTAssertNotEqual(currentReceipt, oldReceipt)

for url in paths.all.map(\.url) {
    let content = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    XCTAssertTrue(content.contains("/Applications/Agent Light.app"))
    XCTAssertFalse(content.contains("/old/AgentLightRelay"))
}

let noOpReceipt = try await noOpInstaller.repair(using: currentReceipt)
XCTAssertEqual(noOpReceipt, currentReceipt)
XCTAssertEqual(operations.replacementCount, 0)
```

- [ ] **Step 2: Verify RED**

Run:

```bash
swift test --filter IntegrationInstallerTests/testVerifiedRepairMigratesOwnedRelayPathThenPerformsNoWrites
```

Expected: FAIL because the second repair still requests atomic replacements.

- [ ] **Step 3: Add the no-write guard**

Immediately after `verifiedChanges` in `repair(using:)`:

```swift
guard prepared.contains(where: { change, _ in
    change.before.data != change.after
}) else {
    return receipt
}
```

Fingerprint verification must remain before the guard. Updated-receipt construction, atomic apply, cleanup-failure handling, and permission preservation remain unchanged for stale paths.

- [ ] **Step 4: Verify GREEN and commit**

```bash
swift test --filter IntegrationInstallerTests
git add Sources/AgentLightCore/Integrations/IntegrationInstaller.swift Tests/AgentLightCoreTests/IntegrationInstallerTests.swift
git commit -m "fix: make owned hook repair idempotent"
```

### Task 2: Reconcile before relay startup

**Files:**
- Modify: `Tests/AgentLightAppTests/AppEnvironmentTests.swift`
- Modify: `Tests/AgentLightUITests/AppViewModelTests.swift`
- Modify: `Sources/AgentLightApp/AppEnvironment.swift`
- Modify: `Sources/AgentLightUI/AppViewModel.swift`

**Interfaces:**
- Consumes: `AppViewModeling.phase`, `repairIntegrations()`, health `RepairPlan`, and idempotent `repair(using:)`.
- Produces: launch order `synchronizeOwnership -> repairIntegrations (monitoring/paused only) -> relay.start`; unchanged receipts map to `RepairResult.reconciled` without ledger writes.

- [ ] **Step 1: Add a failing launch-order test**

Extend the existing `EnvironmentEvent` and `EnvironmentViewModel` recorder with `.repairIntegrations`, set the fake phase to `.monitoring`, start the environment, and assert repair precedes relay start:

```swift
let events = recorder.snapshot()
XCTAssertLessThan(
    try XCTUnwrap(events.firstIndex(of: .repairIntegrations)),
    try XCTUnwrap(events.firstIndex(of: .relayStart))
)
```

- [ ] **Step 2: Verify RED**

```bash
swift test --filter AppEnvironmentTests/testExistingSetupReconcilesIntegrationsBeforeRelayStarts
```

Expected: FAIL because startup does not call `repairIntegrations()`.

- [ ] **Step 3: Add launch reconciliation**

Directly after `synchronizeOwnership()` and cancellation checking in `performStart`:

```swift
let synchronizedPhase = await viewModel.phase
if synchronizedPhase == .monitoring || synchronizedPhase == .paused {
    await viewModel.repairIntegrations()
}
try Task.checkCancellation()
```

This block must remain before `beforeRelayStart` and `shutdownController.start`.

- [ ] **Step 4: Add a failing unchanged-receipt test**

Use a monitoring `ViewModelHarness` whose repair result equals its persisted receipt. Record ownership-store writes, call `repairIntegrations()`, and assert no new write and phase `.monitoring`:

```swift
let writes = await store.writes()
await harness.viewModel.repairIntegrations()
XCTAssertEqual(await store.writes(), writes)
XCTAssertEqual(harness.viewModel.phase, .monitoring)
```

- [ ] **Step 5: Verify RED**

```bash
swift test --filter AppViewModelTests/testHealthRepairWithUnchangedReceiptPerformsNoLedgerWrite
```

Expected: FAIL because health repair records an unchanged receipt.

- [ ] **Step 6: Map unchanged health receipts to reconciliation**

Split `.health` from `.rollback` and `.adoptMixed` in `performRepair`:

```swift
case .health:
    guard let receipt = snapshot.integration.receipt else {
        return .invalidAdoptionReceipt
    }
    let updated = try await integrations.repair(using: receipt)
    return updated == receipt
        ? .reconciled
        : .success(updatedReceipt: updated)
```

Keep rollback/adoption behavior unchanged.

- [ ] **Step 7: Verify GREEN and commit**

```bash
swift test --filter 'AppEnvironmentTests|AppViewModelTests'
git add Sources/AgentLightApp/AppEnvironment.swift Sources/AgentLightUI/AppViewModel.swift Tests/AgentLightAppTests/AppEnvironmentTests.swift Tests/AgentLightUITests/AppViewModelTests.swift
git commit -m "fix: reconcile owned hooks before relay startup"
```

### Task 3: Install the canonical local runtime

**Files:**
- Modify: `scripts/install-local.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: `scripts/build-app.sh release`, bundle ID `com.bbatchas.agentlight`, destination `~/Applications/Agent Light.app`.
- Produces: a verified canonical bundle launched after the prior instance exits and a staged replacement succeeds.

- [ ] **Step 1: Harden the local installer**

Implement this order with quoted variables and a cleanup trap:

```bash
osascript -e 'tell application id "com.bbatchas.agentlight" to quit' >/dev/null 2>&1 || true
for _ in {1..100}; do
  pgrep -x AgentLight >/dev/null || break
  sleep 0.1
done
if pgrep -x AgentLight >/dev/null; then
  echo "Agent Light did not quit cleanly" >&2
  exit 1
fi

ditto "$SOURCE_APP" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
```

Reject a symlink destination. Stage in `~/Applications`, rename any existing destination to a same-directory backup, rename the verified stage into place, restore the backup if the final rename fails, delete the backup only after success, then open the canonical bundle.

- [ ] **Step 2: Document canonical installation**

Add to `README.md`:

```markdown
Run `scripts/install-local.sh` for local use. Agent Light runs from
`~/Applications/Agent Light.app`; receipt-verified startup reconciliation updates
only Agent Light-owned hook commands when a prior development bundle used a
different relay path.
```

- [ ] **Step 3: Verify and commit**

```bash
bash -n scripts/install-local.sh
swift test --parallel
git add scripts/install-local.sh README.md
git commit -m "fix: install Agent Light at a stable local path"
```

- [ ] **Step 4: Install and run live acceptance**

Run `scripts/install-local.sh`, verify the installed bundle signature, wait for the private `0600` socket, and confirm the running executable and every owned hook command use `~/Applications/Agent Light.app`. Confirm no owned command contains `.worktrees`.

Invoke bounded synthetic events through the commands actually read from each installed config:

```text
Claude Code: UserPromptSubmit -> Stop -> SessionEnd
Codex: UserPromptSubmit -> Stop
Cursor: beforeSubmitPrompt -> stop(completed) -> sessionEnd
```

Expected: source attribution is correct, the light changes for each active/terminal event, all synthetic sessions clear, and the app returns to Idle.
