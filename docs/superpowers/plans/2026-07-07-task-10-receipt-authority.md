# Task 10 Receipt Authority Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Require a valid authoritative install receipt before committed-cleanup repair can clear or replace integration cleanup ownership.

**Architecture:** Repair results carry receipt validity and authoritative ownership when a receipt-bearing committed cleanup error occurs. Recording fails closed for malformed receipts, preserving the prior cleanup obligation while independently tracking artifact cleanup.

**Tech Stack:** Swift 6, actors, Observation, XCTest.

## Global Constraints

- Strict RED/GREEN TDD.
- Preserve source compatibility and existing ownership safety.
- Run focused, UI, full, release, diff, security, and orphan verification.
- Commit locally without pushing.

---

### Task 1: Receipt-authoritative repair

**Files:**
- Modify: `Tests/AgentLightUITests/AppViewModelTests.swift`
- Modify: `Sources/AgentLightUI/AppViewModel.swift`

- [x] Add a failing malformed receipt mixed-adoption test through artifact verification and valid retry.
- [x] Bind and validate the receipt in the committed-cleanup catch.
- [x] Preserve prior cleanup ownership and obligation for malformed receipts across every repair plan.
- [x] Apply authoritative ownership transitions only for valid complete receipts.
- [x] Run focused and UI tests green.

### Task 2: Verify, report, and commit

**Files:**
- Modify: `.superpowers/sdd/task-10-report.md`

- [x] Run full tests, release build, diff, security, and orphan scans.
- [x] Update report with RED/GREEN evidence and final counts.
- [x] Commit locally without pushing.
