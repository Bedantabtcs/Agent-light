# Stable Startup Panel Size Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the Agent Light menu-bar panel at 380×540 points from its first visible startup frame through the ready monitoring state.

**Architecture:** `StartupStatusView` will adopt the same exact frame contract already used by `MenuBarContentView`. A focused AppKit hosting test will cover every startup status, while the existing menu rendering test continues to protect the ready-state size.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, XCTest, Swift Package Manager, macOS `System Events` for live frame sampling.

## Global Constraints

- Preserve the top bulb icon, state-side icons, activity colors, glow behavior, and state classification.
- Do not change startup sequencing, hook reconciliation, relay behavior, or Tuya behavior.
- Every startup status and ready menu content must report a 380×540 fitting size.
- Implement test-first and verify the live canonical app at `~/Applications/Agent Light.app`.

---

### Task 1: Enforce one startup panel size

**Files:**
- Modify: `Tests/AgentLightAppTests/AppEnvironmentTests.swift`
- Modify: `Sources/AgentLightApp/AgentLightApp.swift`

**Interfaces:**
- Consumes: `StartupStatusView(status:retry:quit:)` and `AppEnvironmentStatus` cases `.loading`, `.failed`, and `.credentialResetFailed`.
- Produces: an exact 380×540 intrinsic frame contract for every `StartupStatusView` state.

- [ ] **Step 1: Write the failing regression test**

Add this test to `AppEnvironmentTests`:

```swift
func testEveryStartupStateUsesStablePanelSize() {
    for status: AppEnvironmentStatus in [.loading, .failed, .credentialResetFailed] {
        let hosting = NSHostingView(rootView: StartupStatusView(
            status: status,
            retry: {},
            quit: {}
        ))
        hosting.layoutSubtreeIfNeeded()

        XCTAssertEqual(hosting.fittingSize.width, 380, accuracy: 1)
        XCTAssertEqual(hosting.fittingSize.height, 540, accuracy: 1)
    }
}
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
swift test --filter AppEnvironmentTests.testEveryStartupStateUsesStablePanelSize
```

Expected: FAIL because the current startup fitting height is 240 rather than 540.

- [ ] **Step 3: Apply the minimal fixed-frame implementation**

In `StartupStatusView.body`, replace:

```swift
.frame(minWidth: 380, maxWidth: 380, minHeight: 240)
```

with:

```swift
.frame(width: 380, height: 540)
```

Do not change any startup content, menu content, icon, color, or animation code.

- [ ] **Step 4: Run focused rendering verification**

Run:

```bash
swift test --filter AppEnvironmentTests.testEveryStartupStateUsesStablePanelSize
swift test --filter ViewRenderingTests.testMenuBarContentProvidesStableIntrinsicPanelSize
swift test --filter ViewRenderingTests.testAmbientBulbUsesOneStableTopIcon
swift test --filter ViewRenderingTests.testAmbientBulbPulseChangesOnlyOpacity
```

Expected: all four selected test commands exit 0.

- [ ] **Step 5: Run full verification**

Run:

```bash
swift package clean
swift test --parallel
git diff --check
```

Expected: all tests pass, including the new startup-size regression, with no whitespace errors.

- [ ] **Step 6: Commit the implementation**

```bash
git add Sources/AgentLightApp/AgentLightApp.swift Tests/AgentLightAppTests/AppEnvironmentTests.swift
git commit -m "fix: keep startup panel size stable"
```

### Task 2: Install and live-check the canonical app

**Files:**
- No source changes.

**Interfaces:**
- Consumes: `scripts/install-local.sh` and the canonical bundle at `~/Applications/Agent Light.app`.
- Produces: a locally installed app whose visible startup and ready frames remain 380×540.

- [ ] **Step 1: Install the verified local build**

Run:

```bash
./scripts/install-local.sh
codesign --verify --deep --strict "$HOME/Applications/Agent Light.app"
plutil -lint "$HOME/Applications/Agent Light.app/Contents/Info.plist"
```

Expected: installation, signature verification, and property-list validation exit 0.

- [ ] **Step 2: Sample the window from launch through ready state**

Quit and relaunch the canonical app, open the menu item immediately, and use `System Events` to sample `size of window 1` every 50 milliseconds for two seconds. Collect every visible size and reduce the samples to unique values.

Expected: the only unique visible size is `380540`; neither `380240` nor another intermediate size appears.

- [ ] **Step 3: Confirm unchanged behavior and clean repository state**

Open the panel after startup and confirm it shows Monitoring without changing size. Then run:

```bash
git status --short
pgrep -x AgentLight >/dev/null
```

Expected: the repository is clean and Agent Light is running from the canonical bundle.
