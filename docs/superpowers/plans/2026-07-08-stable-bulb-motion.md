# Stable Bulb Motion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove apparent bulb resizing while preserving ambient motion and prove the new activity colours reach the real light.

**Architecture:** `AmbientBulbView` will use a small internal motion model so animation geometry is explicit and testable. The glow keeps a constant scale and pulses only its opacity; SF Symbols render as resizable, aspect-fit images inside one square frame. Existing protocol, coordinator, and Tuya paths remain unchanged and are verified through focused pipeline tests plus a live relay colour cycle.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, Swift Package Manager, XCTest, Unix datagram relay, Tuya cloud control.

## Global Constraints

- Keep the menu panel fixed at `380 × 540` points.
- Preserve Reading cyan `#06B6D4`, Editing teal `#14B8A6`, Testing pink `#EC4899`, and Cancelled orange `#F97316`.
- Preserve the 2.4-second pulse cadence, state symbols, high-contrast treatment, and Reduce Motion behavior.
- Do not change relay classification, lifecycle holds, credentials, integrations, or Tuya capability resolution.
- Do not log or persist raw tool names, commands, paths, prompts, credentials, or device identifiers.

---

### Task 1: Make bulb motion geometry stable

**Files:**
- Modify: `Tests/AgentLightUITests/ViewRenderingTests.swift`
- Modify: `Sources/AgentLightUI/Views/AmbientBulbView.swift`

**Interfaces:**
- Consumes: `AmbientBulbView(state:)`, `AgentState.bulbSymbolName`, SwiftUI Reduce Motion environment.
- Produces: internal `AmbientBulbMotion.glowScale`, `glowOpacity(isPulsing:reduceMotion:)`, `duration`, and `iconFrameSide` values used directly by the view and its tests.

- [ ] **Step 1: Add failing motion-model tests**

Add these tests to `ViewRenderingTests`:

```swift
func testAmbientBulbPulseChangesOnlyOpacity() {
    XCTAssertEqual(AmbientBulbMotion.glowScale, 1)
    XCTAssertEqual(
        AmbientBulbMotion.glowOpacity(isPulsing: true, reduceMotion: true),
        1
    )
    XCTAssertEqual(
        AmbientBulbMotion.glowOpacity(isPulsing: false, reduceMotion: true),
        1
    )
    XCTAssertLessThan(
        AmbientBulbMotion.glowOpacity(isPulsing: false, reduceMotion: false),
        AmbientBulbMotion.glowOpacity(isPulsing: true, reduceMotion: false)
    )
}

func testAmbientBulbUsesFixedIconFrame() {
    XCTAssertEqual(AmbientBulbMotion.iconFrameSide, 48)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter 'ViewRenderingTests/testAmbientBulb'
```

Expected: compilation fails because `AmbientBulbMotion` does not exist.

- [ ] **Step 3: Add the minimal motion model and use it in the view**

Add beside `AmbientBulbView`:

```swift
enum AmbientBulbMotion {
    static let glowScale: CGFloat = 1
    static let restingGlowOpacity = 0.62
    static let activeGlowOpacity = 1.0
    static let duration = 2.4
    static let iconFrameSide: CGFloat = 48

    static func glowOpacity(isPulsing: Bool, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return activeGlowOpacity }
        return isPulsing ? activeGlowOpacity : restingGlowOpacity
    }
}
```

Update the glow modifiers to use a fixed scale and opacity-only pulse:

```swift
.scaleEffect(AmbientBulbMotion.glowScale)
.opacity(AmbientBulbMotion.glowOpacity(
    isPulsing: isPulsing,
    reduceMotion: shouldReduceMotion
))
```

Render the symbol inside a stable square:

```swift
Image(systemName: state.bulbSymbolName)
    .resizable()
    .scaledToFit()
    .frame(
        width: AmbientBulbMotion.iconFrameSide,
        height: AmbientBulbMotion.iconFrameSide
    )
```

Use `AmbientBulbMotion.duration` in the existing repeating animation and retain all current colour, shadow, accessibility, and outer-frame modifiers.

- [ ] **Step 4: Run focused and complete UI tests**

Run:

```bash
swift test --filter ViewRenderingTests
```

Expected: all `ViewRenderingTests` pass, including stable `380 × 540` panel sizing and accessibility rendering.

- [ ] **Step 5: Commit the motion fix**

```bash
git add Sources/AgentLightUI/Views/AmbientBulbView.swift Tests/AgentLightUITests/ViewRenderingTests.swift
git commit -m "fix: stabilize ambient bulb motion"
```

### Task 2: Verify activity colours through the full light path

**Files:**
- Verify: `Tests/AgentLightCoreTests/AgentStateTests.swift`
- Verify: `Tests/AgentLightCoreTests/EndToEndPipelineTests.swift`
- Verify: `Tests/AgentLightCoreTests/TuyaLightControllerTests.swift`
- Verify: `Tests/AgentLightProtocolTests/RelayEncodingTests.swift`
- Build: `scripts/build-app.sh`

**Interfaces:**
- Consumes: relay activity classification, `AgentState.color`, monitoring coordination, `TuyaLightController`, and the configured local app.
- Produces: automated evidence for exact RGB mappings and fixture-to-Tuya desired states, followed by live device-command evidence for every new state.

- [ ] **Step 1: Run focused activity-colour tests**

Run:

```bash
swift test --filter 'AgentStateTests|EndToEndPipelineTests|TuyaLightControllerTests|RelayEncodingTests'
```

Expected: all selected tests pass. In particular, Reading resolves to `#06B6D4`, Editing to `#14B8A6`, Testing to `#EC4899`, and Cancelled to `#F97316`, and every fixture reaches the fake light through the production socket/coordinator path.

- [ ] **Step 2: Run the full regression suite**

Run:

```bash
swift test --parallel
```

Expected: all tests pass with no crashes, failures, or unexpected warnings.

- [ ] **Step 3: Rebuild and relaunch the signed local app**

Run:

```bash
scripts/build-app.sh release
```

Expected: `build/Agent Light.app` is assembled and ad-hoc signed successfully. Quit the prior AgentLight process and launch this bundle before the live cycle.

- [ ] **Step 4: Send a live colour cycle through the bundled relay**

With monitoring active, pipe these bounded synthetic hook payloads to `build/Agent Light.app/Contents/MacOS/AgentLightRelay`, using integration ID `com.bbatchas.agentlight.hook.v1`, source `cursor`, and the listed event. Wait at least two seconds between commands so each one clears the one-second light throttle.

```json
{"conversation_id":"manual-colour-cycle","workspace":"/Fixture","toolName":"Read"}
{"conversation_id":"manual-colour-cycle","workspace":"/Fixture","toolName":"apply_patch"}
{"conversation_id":"manual-colour-cycle","workspace":"/Fixture","command":"swift test --parallel"}
{"conversation_id":"manual-colour-cycle","workspace":"/Fixture","status":"aborted"}
```

Use events `preToolUse`, `preToolUse`, `beforeShellExecution`, and `stop` respectively. Expected sequence on the app and light: Reading cyan, Editing teal, Testing pink, Cancelled orange. Cancelled remains orange for eight seconds before lifecycle recovery.

- [ ] **Step 5: Verify the real panel remains fixed during the cycle**

Use macOS Accessibility to sample the AgentLight window at 200 ms intervals for at least 3.2 seconds. Expected: every sample is `380 × 540`; the glow changes opacity without changing size and state glyphs stay inside the fixed icon frame.

- [ ] **Step 6: Record the verification result**

Do not claim production readiness. Report exact automated test counts, build/signing status, window-size samples, live state sequence, and any state that did not reach the configured light. If the physical device or Tuya service rejects a command, report that failure without changing credentials or retrying unboundedly.
