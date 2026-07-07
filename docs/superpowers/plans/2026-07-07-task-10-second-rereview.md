# Task 10 Second Re-review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct integration receipt/artifact handling and make application cleanup independent of `AppViewModel` lifetime.

**Architecture:** Add validated integration receipts and a read-only artifact verification boundary in `AgentLightCore`. Replace view-model-owned approval/cleanup state with a Sendable ledger and dependency-only transaction drivers that return typed outcomes for weak main-actor commits. Keep shared operation waiting deterministic and cancellation-safe.

**Tech Stack:** Swift 6, Swift Concurrency, Observation, XCTest, Swift Package Manager.

## Global Constraints

- Strict test-first RED/GREEN cycles for every behavior change.
- Never delete retained artifacts automatically; scan only known Agent Light artifact names in known integration directories.
- Never hardcode secrets or expose dependency error descriptions in presentation state.
- No polling, scheduler yields, debug logs, force casts/tries, or TypeScript-style untyped state.
- Commit locally and do not push.

---

### Task 1: Validated receipts and source-compatible errors

**Files:**
- Modify: `Sources/AgentLightCore/Integrations/IntegrationInstaller.swift`
- Test: `Tests/AgentLightCoreTests/IntegrationInstallerTests.swift`

**Interfaces:**
- Produces: `IntegrationInstallReceipt.validated(sources:) throws`, `validatedOwnership`, legacy `committedWithCleanupFailure([String])`, and receipt-bearing committed error.

- [ ] Add failing tests for duplicate, omitted, and complete source receipt sets and legacy error construction.
- [ ] Run `swift test --filter IntegrationInstallerTests` and confirm the new tests fail for missing validation/legacy construction.
- [ ] Add the source-compatible factory/validation and separate receipt-bearing error case.
- [ ] Re-run the focused suite and confirm green.

### Task 2: Read-only retained-artifact verification

**Files:**
- Modify: `Sources/AgentLightCore/Integrations/IntegrationInstaller.swift`
- Test: `Tests/AgentLightCoreTests/IntegrationInstallerTests.swift`

**Interfaces:**
- Produces: `IntegrationInstalling.verifyArtifactCleanup() async throws -> Bool` with a conservative default and concrete known-location scanner.

- [ ] Add failing present, absent, unrelated-file, and scan-error tests.
- [ ] Run focused tests and confirm failure because the protocol/concrete behavior is absent.
- [ ] Implement non-destructive verification restricted to `.agent-light-staged-` and `.agent-light-rollback-` names beside configured destinations.
- [ ] Re-run focused tests and confirm green.

### Task 3: Cleanup result preservation across every path

**Files:**
- Modify: `Sources/AgentLightUI/AppViewModel.swift`
- Test: `Tests/AgentLightUITests/AppViewModelTests.swift`
- Modify: `Tests/AgentLightUITests/Support/ViewModelHarness.swift`

**Interfaces:**
- Produces: typed cleanup outcomes that distinguish ordinary uninstall retry from retained artifact cleanup.

- [ ] Add failing abandon, compensation, disconnect, and retry tests for `artifactCleanupFailure`.
- [ ] Run those tests and confirm each currently downgrades or swallows the artifact result.
- [ ] Implement one cleanup result mapper used by all paths.
- [ ] Add artifact verification present/absent/error view-model tests and implement repair clearing only on confirmed absence.
- [ ] Re-run focused tests and confirm green.

### Task 4: Dependency-owned approval and cleanup ledger

**Files:**
- Modify: `Sources/AgentLightUI/AppViewModel.swift`
- Test: `Tests/AgentLightUITests/AppViewModelTests.swift`
- Modify: `Tests/AgentLightUITests/Support/ViewModelHarness.swift`

**Interfaces:**
- Produces: Sendable ledger actor, dependency-only approval/disconnect transactions, and typed `ApprovalResult`/cleanup result values.

- [ ] Add blocked monitor-start, stop, compensation, uninstall, and deinit tests.
- [ ] Confirm RED where the view model is retained or cleanup stops after deallocation.
- [ ] Implement ledger recording immediately after every completed install/credential/login/monitor step.
- [ ] Move all approval and cleanup awaits into dependency-only drivers; weakly commit returned outcomes.
- [ ] Add disconnect-canceled-while-awaiting-approval coverage and confirm ledger cleanup completes after view-model deallocation.
- [ ] Re-run the ownership/deinit subset and confirm green.

### Task 5: Pause cancellation safety and shared-operation determinism

**Files:**
- Modify: `Sources/AgentLightUI/AppViewModel.swift`
- Test: `Tests/AgentLightUITests/AppViewModelTests.swift`
- Modify: `Tests/AgentLightUITests/Support/ViewModelHarness.swift`

**Interfaces:**
- Produces: explicit pause outcome and cancellation-safe waiter registration/count barriers.

- [ ] Add failing pause-cancellation/resume-failure test and pre-canceled waiter test.
- [ ] Confirm RED for incorrect monitoring phase and zero-waiter driver cancellation race.
- [ ] Implement explicit pause outcome and register-before-cancellation waiter logic.
- [ ] Add deterministic two-waiter approval/pause/resume/repair/disconnect tests for initiating and noninitiating cancellation.
- [ ] Re-run focused tests and 20 bounded repetitions.

### Task 6: Report and verification

**Files:**
- Modify: `.superpowers/sdd/task-10-report.md`

- [ ] Update obsolete protocol descriptions and add RED/GREEN evidence.
- [ ] Run UI, installer, and login focused suites.
- [ ] Run the shared/deinit subset 20 times with a bounded command.
- [ ] Run `swift test`, `swift build -c release`, diff/security/orphan scans, and `git diff --check`.
- [ ] Commit all scoped changes locally without pushing.
