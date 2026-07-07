# Task 10 Ownership Finalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve authoritative cleanup ownership through repair, clear harmless repaired presence, and bound weak presentation-handle storage.

**Architecture:** Repair recording receives the leased ownership snapshot and changes integration cleanup ownership only for authoritative uninstall, rollback, or adoption outcomes. The ledger prunes dead weak presentation handles whenever the registry is touched or inspected.

**Tech Stack:** Swift 6, actors, Observation, XCTest.

## Global Constraints

- Strict RED/GREEN TDD.
- Preserve existing source compatibility and process-memory security boundaries.
- Run focused tests, 20 repeated ownership/lifecycle runs, full tests, release build, scans, report update, and a local commit without pushing.

---

### Task 1: Repair ownership semantics

**Files:**
- Modify: `Tests/AgentLightUITests/AppViewModelTests.swift`
- Modify: `Sources/AgentLightUI/AppViewModel.swift`

- [x] Add failing health-repair committed-cleanup tests covering legacy and receipt-bearing errors followed by disconnect.
- [x] Add failing rollback and mixed-adoption repair-to-approval tests plus replacement reconciliation coverage.
- [x] Pass leased integration ownership into repair recording and preserve it for health/artifact-only outcomes.
- [x] Clear cleanup ownership after successful rollback repair and mixed adoption.
- [x] Run the focused ownership tests green.

### Task 2: Weak presentation-handle lifecycle

**Files:**
- Modify: `Tests/AgentLightUITests/AppViewModelTests.swift`
- Modify: `Sources/AgentLightUI/AppViewModel.swift`

- [x] Add a failing repeated replacement/deallocation test with a live-handle-count assertion.
- [x] Add weak-owner liveness and prune dead handles on registration, broadcast/read, and count.
- [x] Verify cleanup broadcasts affect only live handles.
- [x] Run focused lifecycle tests green and repeat the ownership/lifecycle subset 20 times.

### Task 3: Report, verify, and commit

**Files:**
- Modify: `.superpowers/sdd/task-10-report.md`

- [x] Run UI, installer, full, release, diff, security, and orphan verification.
- [x] Record RED/GREEN evidence and final counts.
- [x] Commit locally without pushing.
