# Task 10 Ledger Lease Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serialize hydration and external ownership mutations across replacement view models while restoring source compatibility.

**Architecture:** `AppOwnershipLedger` provides a FIFO single-flight lease. Every public action hydrates through that lease before dependency access; approval and cleanup hold it until final ledger state is committed.

**Tech Stack:** Swift 6, actors, Observation, XCTest.

## Global Constraints

- Strict RED/GREEN TDD; process-memory ledger only; no push.

---

### Task 1: Mandatory hydration and transaction lease

**Files:** `Sources/AgentLightUI/AppViewModel.swift`, `Tests/AgentLightUITests/AppViewModelTests.swift`

- [x] Add blocked cross-instance tests and confirm no new action runs before old cleanup completes.
- [x] Add FIFO ledger lease and wrap approval/cleanup ownership transactions.
- [x] Gate every public action on hydration and serialize explicit synchronization with local work.
- [x] Re-run focused tests green.

### Task 2: Source compatibility

**Files:** `Sources/AgentLightCore/Integrations/IntegrationInstaller.swift`, `Sources/AgentLightUI/AppViewModel.swift`, focused tests.

- [x] Add compile tests for four-argument preview and five-dependency view-model initializers.
- [x] Add compatibility overloads while retaining recommended explicit-ledger construction.
- [x] Re-run focused tests green.

### Task 3: Verify and report

**Files:** `.superpowers/sdd/task-10-report.md`

- [x] Run 20 race repetitions, focused suites, full suite, release build, and scans.
- [x] Document hydration/lease behavior and convenience-initializer limitation.
- [x] Commit locally without pushing.
