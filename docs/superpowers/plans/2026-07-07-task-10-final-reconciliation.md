# Task 10 Final Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make shared-ledger reconciliation, queued repair cancellation, and presentation commits atomic across replacement view models.

**Architecture:** The ownership ledger retains FIFO durable and cancellable lease modes. Approval, repair, and disconnect derive decisions from a snapshot taken under the lease and commit main-actor presentation state before releasing it; hydration reconciles empty final snapshots to onboarding when no local transaction owns the phase.

**Tech Stack:** Swift 6, actors, Observation, XCTest.

## Global Constraints

- Strict RED/GREEN TDD.
- Preserve source compatibility.
- Run focused, 20x race, full, release, diff, security, and orphan verification.
- Commit locally without pushing.

---

### Task 1: Empty-ledger reconciliation and stale repair no-op

**Files:**
- Modify: `Tests/AgentLightUITests/AppViewModelTests.swift`
- Modify: `Sources/AgentLightUI/AppViewModel.swift`

- [x] Add a failing replacement synchronization test proving an empty ledger clears stale repair presentation to onboarding.
- [x] Add failing sequential and queued two-view-model repair tests proving a disappeared uninstall obligation triggers zero new integration calls.
- [x] Re-read obligations after repair acquires its lease and return the final snapshot without selecting `.health` when no actionable obligation remains.
- [x] Run the focused reconciliation tests green.

### Task 2: Cancellable transaction acquisition and ordered commits

**Files:**
- Modify: `Tests/AgentLightUITests/AppViewModelTests.swift`
- Modify: `Tests/AgentLightUITests/Support/ViewModelHarness.swift`
- Modify: `Sources/AgentLightUI/AppViewModel.swift`

- [x] Add failing cancellation tests for approval and repair queued behind a held lease, with dependency and lease-order barriers.
- [x] Add failing cross-instance approval, repair, and disconnect commit-order tests.
- [x] Use cancellable acquisition for approval/repair and check cancellation before the first external dependency or ledger mutation.
- [x] Commit presentation state on the main actor while the lease remains held; release every token on all result paths.
- [x] Run focused transaction tests green and repeat the race/cancellation subset 20 times.

### Task 3: Compatibility, report, and verification

**Files:**
- Modify: `Sources/AgentLightUI/AppViewModel.swift`
- Modify: `.superpowers/sdd/task-10-report.md`

- [x] Add a default no-op `AppViewModeling.synchronizeOwnership()` implementation and compile coverage.
- [x] Run UI, installer, login, full, release, diff, security, and orphan checks.
- [x] Record RED/GREEN and verification evidence in the report.
- [x] Commit locally without pushing.
