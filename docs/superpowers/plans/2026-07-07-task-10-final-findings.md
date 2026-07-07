# Task 10 Final Findings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve all committed cleanup failures, rehydrate cleanup ownership across view-model replacement, and make shared-operation ordering tests deterministic.

**Architecture:** Normalize committed cleanup errors into one artifact obligation result. Inject a process-owned Sendable ledger into view models and asynchronously hydrate state from it. Extend debug barriers to prove caller entry and ordering before releasing blocked dependencies.

**Tech Stack:** Swift 6, Swift Concurrency, Observation, XCTest, Swift Package Manager.

## Global Constraints

- Strict RED/GREEN TDD.
- Ledger remains process memory only; no secrets in UserDefaults or files.
- Local commit only; no push.

---

### Task 1: Committed error normalization and mixed validation

**Files:** `Sources/AgentLightUI/AppViewModel.swift`, `Tests/AgentLightUITests/AppViewModelTests.swift`

- [ ] Add failing tests for all three committed cleanup errors through compensation/disconnect and malformed mixed-adoption receipts.
- [ ] Run focused tests and confirm incorrect uninstall retry/obligation clearing.
- [ ] Normalize all committed cleanup forms to artifact cleanup and validate adoption receipts.
- [ ] Re-run focused tests green.

### Task 2: Injected ledger rehydration

**Files:** `Sources/AgentLightUI/AppViewModel.swift`, `Tests/AgentLightUITests/AppViewModelTests.swift`, `Tests/AgentLightUITests/Support/ViewModelHarness.swift`

- [ ] Add failing shared-ledger replacement tests covering credential, login, integration, and artifact failures.
- [ ] Run focused tests and confirm replacement view models cannot recover state.
- [ ] Make the ledger an explicit injectable environment dependency and add async hydration.
- [ ] Retry cleanup from a replacement view model and re-run focused tests green.

### Task 3: Cancellation presentation and deterministic ordering

**Files:** `Sources/AgentLightUI/AppViewModel.swift`, `Tests/AgentLightUITests/AppViewModelTests.swift`

- [ ] Add failing canceled-approval cleanup-error and caller-entry ordering tests.
- [ ] Confirm repair-required can present nil and ordering is not proven.
- [ ] Add sanitized fallback presentation and DEBUG action-entry barriers.
- [ ] Re-run focused tests and 20 bounded repetitions.

### Task 4: Verification and report

**Files:** `.superpowers/sdd/task-10-report.md`

- [ ] Document process-crash limitation and RED/GREEN evidence.
- [ ] Run focused suites, full suite, release build, diff/security/orphan scans.
- [ ] Commit locally without pushing.
