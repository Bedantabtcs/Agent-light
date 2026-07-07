# Task 11 Final Findings Implementation Plan

> **For agentic workers:** Execute inline with strict RED/GREEN checkpoints; no subagents are authorized for this task.

**Goal:** Correct lifecycle serialization and deinit cleanup, recover unusable stored credentials, expose independent Settings state/actions, and make native AppKit controls fully accessible and Dynamic Type aware.

**Architecture:** Keep `AppEnvironment` main-actor isolated, but replace loose task flags with an explicit lifecycle state and operation identity. Move dependency-only shutdown into a controller that can outlive the environment without retaining it. Keep ownership truth in the ledger and monitor lifecycle, then project it through explicit view-model properties. Native wrappers receive SwiftUI `dynamicTypeSize` and apply deterministic AppKit fonts and complete accessibility metadata.

**Tech Stack:** Swift 6, Swift Concurrency, Observation, SwiftUI, AppKit, XCTest.

## Global Constraints

- Strict test-first RED/GREEN for every behavior change.
- No secrets, debug logging, force casts/tries, or direct UI light commands.
- Run the critical lifecycle race set 20 times, full tests, debug/release builds, scans, and update `.superpowers/sdd/task-11-report.md`.
- Commit locally; do not push.

---

### Task 1: Serialized environment lifecycle and ready deinit shutdown

**Files:**
- Modify: `Sources/AgentLightApp/AppEnvironment.swift`
- Modify: `Tests/AgentLightAppTests/AppEnvironmentTests.swift`

- [ ] Add failing tests for blocked start plus start-during-stop, ready stop plus start, concurrent retries, and ready deinit with blocked relay/monitor cleanup.
- [ ] Verify focused RED failures demonstrate overlapping starts or missing cleanup.
- [ ] Implement explicit `idle/starting/ready/stopping` state, operation ID/tail, queued restart, and dependency-only exactly-once shutdown controller.
- [ ] Verify focused GREEN and restoration ordering.

### Task 2: Recover malformed or legacy stored credentials

**Files:**
- Modify: `Sources/AgentLightApp/AppEnvironment.swift`
- Modify: `Tests/AgentLightAppTests/AppEnvironmentTests.swift`

- [ ] Add failing tests for legacy arbitrary-origin JSON, malformed bytes, and delete failure followed by retry.
- [ ] Verify RED shows startup failure loops or skipped relay startup.
- [ ] On `CredentialStoreError.malformedData`, delete through `CredentialStoring`, synchronize onboarding, and continue relay start. Surface sanitized failed status when deletion fails; retry must reattempt reset without signing.
- [ ] Verify focused GREEN and no permanent loop.

### Task 3: Explicit Settings ownership and monitoring state

**Files:**
- Modify: `Sources/AgentLightUI/AppViewModel.swift`
- Modify: `Sources/AgentLightUI/Views/SettingsView.swift`
- Modify: `Tests/AgentLightUITests/AppViewModelTests.swift`
- Modify: `Tests/AgentLightUITests/ViewRenderingTests.swift`
- Modify: `Tests/AgentLightUITests/Support/ViewModelHarness.swift`

- [ ] Add failing tests for `integrationInstalled`, `integrationStatus`, `monitoringActive`, post-uninstall Not Installed, and repair-required pause/resume while preserving phase/error.
- [ ] Verify focused RED failures show phase-derived state and no-op toggle.
- [ ] Add explicit protocol/model properties derived from ledger and monitor lifecycle plus `setMonitoringEnabled(_:)`.
- [ ] Bind Settings to explicit state and verify focused GREEN.

### Task 4: Native AppKit accessibility and Dynamic Type

**Files:**
- Modify: `Sources/AgentLightUI/Views/NativeControls.swift`
- Modify: `Tests/AgentLightUITests/ViewRenderingTests.swift`

- [ ] Add failing hosted tests for picker/control identifier, label, role, non-ignored exposure, and normal-versus-accessibility5 fonts for buttons, picker, switch, summaries, paths, and sessions.
- [ ] Verify focused RED identifies missing metadata and unchanged fonts.
- [ ] Pass `dynamicTypeSize` into wrappers, apply deterministic system/monospaced scaling, and set complete AX metadata.
- [ ] Verify hosted GREEN, finite layout, and scroll reachability.

### Task 5: Verification, report, and local commit

**Files:**
- Modify: `.superpowers/sdd/task-11-report.md`

- [ ] Run lifecycle race tests 20 times and confirm no orphan test process.
- [ ] Run hosted rendering, UI tests, full tests, debug/release builds, `git diff --check`, and security scans.
- [ ] Record exact RED/GREEN and final counts in the Task 11 report.
- [ ] Review staged scope, commit locally, and do not push.
