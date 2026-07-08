# Agent Light Menu Panel Height Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent the menu-bar popup from collapsing to 380 × 10 points and verify a visible 380 × 540 panel in the packaged app.

**Architecture:** Keep SwiftUI `MenuBarExtra(.window)` and all existing phase views. Add one shared height token and constrain the root `MenuBarContentView`; internal phase `ScrollView`s continue handling overflow.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit, XCTest, macOS 14+; no dependencies.

## Global Constraints

- Preserve the existing 380-point width and set the content panel height to exactly 540 points.
- Do not alter startup failure/loading sizing.
- Do not touch real credentials, HOME hook files, login-item state, bulb state, or GitHub.
- Keep the branch local and unpushed.

---

### Task 1: Stabilize the MenuBarExtra content height

**Files:**
- Modify: `Sources/AgentLightUI/Views/AmbientTheme.swift`
- Modify: `Sources/AgentLightUI/Views/MenuBarContentView.swift`
- Modify: `Tests/AgentLightUITests/ViewRenderingTests.swift`

**Interfaces:**
- Produces: `AmbientTheme.windowHeight == 540` and an intrinsic `MenuBarContentView` size of 380 × 540.
- Consumes: existing phase views and their internal scrolling behavior.

- [ ] **Step 1: Write the failing intrinsic-size regression**

Add a helper that creates an `NSHostingView` without assigning the existing forced `380 × 540` test frame. Assert onboarding and representative scroll-root phases report the production shell size:

```swift
func testMenuBarContentProvidesStableIntrinsicPanelSize() async {
    let viewModels = [
        PreviewViewModel.onboarding(),
        await PreviewViewModel.integrationReview(),
        await PreviewViewModel.monitoring(state: .working)
    ]

    for viewModel in viewModels {
        let hosting = NSHostingView(rootView: MenuBarContentView(viewModel: viewModel))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.fittingSize.width, 380, accuracy: 1)
        XCTAssertEqual(hosting.fittingSize.height, 540, accuracy: 1)
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter ViewRenderingTests/testMenuBarContentProvidesStableIntrinsicPanelSize
```

Expected: onboarding reports approximately 10 points of intrinsic height instead of 540.

- [ ] **Step 3: Add the shared height token and root frame**

Add:

```swift
static let windowHeight: CGFloat = 540
```

Apply it only to `MenuBarContentView`:

```swift
.frame(width: AmbientTheme.windowWidth, height: AmbientTheme.windowHeight)
```

Do not add nested fixed heights to onboarding, monitoring, integration, or settings content.

- [ ] **Step 4: Run focused and full UI GREEN tests**

Run:

```bash
swift test --filter ViewRenderingTests/testMenuBarContentProvidesStableIntrinsicPanelSize
swift test --filter AgentLightUITests
swift test --parallel
```

Expected: the new size test and all existing tests pass.

- [ ] **Step 5: Build and inspect the packaged menu window**

Run:

```bash
./scripts/build-app.sh release
codesign --verify --deep --strict "build/Agent Light.app"
plutil -lint "build/Agent Light.app/Contents/Info.plist"
git diff --check
```

Restart the locally built app, click its status item, and inspect its accessibility window bounds. Expected: one popup window with size `{380, 540}` and visible onboarding controls rather than `{380, 10}`.

- [ ] **Step 6: Commit locally without pushing**

```bash
git add Sources/AgentLightUI/Views/AmbientTheme.swift Sources/AgentLightUI/Views/MenuBarContentView.swift Tests/AgentLightUITests/ViewRenderingTests.swift
git commit -m "fix: stabilize menu panel height"
git status --short --branch
```

Expected: clean local branch; no push or pull request.
