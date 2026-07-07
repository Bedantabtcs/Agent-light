# Task 10 Review Corrections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct Task 10 ownership, cleanup, transition, observation, error-mapping, and deterministic concurrency behavior without deleting state Agent Light did not create.

**Architecture:** Task 9 exposes explicit login status and transition ownership. Integration previews carry whether each source already contained Agent Light entries. Task 10 persists attempt ownership and a typed set of outstanding obligations, applies guarded serialized transitions, and owns one weakly-retaining monitor subscription identified by an epoch and ID.

**Tech Stack:** Swift 6.2, Swift Package Manager, Observation, ServiceManagement, XCTest.

## Global Constraints

- Strict RED/GREEN TDD for every correction.
- No real credentials; test data uses explicit `CANARY_*` values.
- No polling, `Task.yield()`, arbitrary sleeps, debug output, or underlying error descriptions.
- No push. Update Task 9 and Task 10 reports and commit locally.

---

### Task 1: Login transition ownership

**Files:**
- Modify: `Sources/AgentLightCore/Platform/LoginItemController.swift`
- Modify: `Tests/AgentLightCoreTests/LoginItemControllerTests.swift`

**Interfaces:**
- Produces: `LoginItemStatus`, `LoginItemTransition`, `LoginItemControlling.status()`, and `setEnabled(_:) -> LoginItemTransition`.

- [ ] Write tests proving enabled, pre-enabled, newly approval-pending, preexisting approval-pending, unknown, and failure transitions report prior/current status plus exact registration ownership.
- [ ] Run `swift test --filter LoginItemControllerTests` and record the missing-interface RED.
- [ ] Implement the public status/outcome boundary without exposing adapter errors.
- [ ] Run the focused suite and record GREEN.

### Task 2: Integration preview ownership

**Files:**
- Modify: `Sources/AgentLightCore/Integrations/IntegrationInstaller.swift`
- Modify: `Tests/AgentLightCoreTests/IntegrationInstallerTests.swift`

**Interfaces:**
- Produces: `IntegrationPreview.hadOwnedEntries`, computed by the same exact owned-command parser used by install/uninstall.

- [ ] Write fresh, fully-preexisting, and partial-preexisting preview tests.
- [ ] Run the focused preview tests and record RED.
- [ ] Add ownership metadata to each actual preview without string guessing in UI code.
- [ ] Run `swift test --filter IntegrationInstallerTests` and record GREEN.

### Task 3: Typed cleanup obligations and attempt ownership

**Files:**
- Modify: `Sources/AgentLightUI/AppViewModel.swift`
- Modify: `Tests/AgentLightUITests/AppViewModelTests.swift`
- Modify: `Tests/AgentLightUITests/Support/ViewModelHarness.swift`

**Interfaces:**
- Produces: `OutstandingObligation` and `AppViewModel.outstandingObligations`.
- Consumes: login transition outcomes and integration preview ownership.

- [ ] Add failing matrices for prior credential restore, new credential delete, restoration/deletion failure, login registration ownership, and fresh/preexisting/partial integration cleanup.
- [ ] Add failing tests proving uncertain reapproval performs zero installs and repair clears only integration obligations.
- [ ] Implement persisted credential/login/integration attempt ownership and reverse-order retryable cleanup.
- [ ] Run each focused matrix to GREEN.

### Task 4: Guarded async state and observation lifecycle

**Files:**
- Modify: `Sources/AgentLightUI/AppViewModel.swift`
- Modify: `Tests/AgentLightUITests/AppViewModelTests.swift`
- Modify: `Tests/AgentLightUITests/Support/ViewModelHarness.swift`

**Interfaces:**
- Public transitions accept only explicitly allowed phases.
- One observation task is identified by epoch and subscription ID and clears only its own handle.

- [ ] Add failing phase-guard tests for connect from verifying, monitoring, paused, and repair-required.
- [ ] Add deterministic stream completion, resubscribe, deinit cancellation, and stale-stream tests.
- [ ] Replace all polling and scheduler yields with continuation barriers and call-number waiters.
- [ ] Complete typed mapping tests for 401/403, 408, 429, 5xx, transport, selected `URLError`, capability, integration, and unknown failures.
- [ ] Implement minimal state/observation/error changes and run UI tests to GREEN.

### Task 5: Verification and handoff

**Files:**
- Modify: `.superpowers/sdd/task-9-report.md`
- Modify: `.superpowers/sdd/task-10-report.md`

- [ ] Run `swift test --filter AgentLightUITests`.
- [ ] Run the selected overlap/concurrency tests 20 times under a shell timeout bound.
- [ ] Run `swift test` and `swift build -c release`.
- [ ] Run staged diff, security, canary, and orphaned-API scans.
- [ ] Append exact RED/GREEN and final verification evidence to both reports.
- [ ] Commit locally with no push.
