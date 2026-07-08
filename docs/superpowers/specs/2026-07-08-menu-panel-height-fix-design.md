# Agent Light Menu Panel Height Fix

**Date:** 2026-07-08  
**Status:** Approved design; written-spec review pending

## Problem

The menu-bar icon receives clicks and creates an `AXWindow`, but the onboarding popup is sized to `380 × 10` points. The visible result is the thin black rounded bar shown in the user screenshot.

`MenuBarContentView` fixes only its width. Its onboarding, integration-review, and monitoring phases use root `ScrollView` content, which does not provide a useful intrinsic height to `MenuBarExtra(.window)`. Existing rendering tests force an external `380 × 540` host frame, masking the production sizing failure.

## Selected fix

- Define an approved menu-panel height of `540` points alongside the existing `380`-point width token.
- Apply the stable `380 × 540` shell at `MenuBarContentView`, while keeping each phase's internal scrolling behavior.
- Leave startup failure/loading content at its existing minimum size because it already supplies intrinsic height.
- Add a regression that hosts `MenuBarContentView` without injecting an external frame and asserts a `380 × 540` fitting size for onboarding and the other scroll-root phases.
- Rebuild the local app and manually verify the real menu window reports `380 × 540` and exposes the onboarding controls.

## Alternatives rejected

- Phase-specific minimum heights: more state-dependent and can reintroduce collapse in a new phase.
- Custom `NSStatusItem`/`NSPopover`: unnecessary architectural replacement for a sizing defect.

## Acceptance criteria

- Clicking the menu-bar icon opens a visible 380 × 540 panel.
- Onboarding, integration review, monitoring, paused, repair, and settings content remains reachable by scrolling.
- Keyboard, accessibility, Dynamic Type, and existing UI tests remain green.
- No live credentials, hooks, login items, bulb, or GitHub state is touched during automated verification.
