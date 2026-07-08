# Stable Startup Panel Size

**Date:** 2026-07-09  
**Status:** Approved

## Problem

Agent Light's menu-bar window uses two different intrinsic heights during launch. `StartupStatusView` renders at 380×240 while startup work is running, then `MenuBarContentView` renders at 380×540 when the environment becomes ready. The latest startup reconciliation makes the smaller state visible long enough for macOS to animate the panel from 240 to 540 points.

Live reproduction recorded nine consecutive 380×240 samples before the panel changed to 380×540.

## Selected design

- Give every `StartupStatusView` state an exact 380×540 frame.
- Keep `MenuBarContentView` at its existing exact 380×540 frame.
- Center the existing startup content inside the larger fixed frame; do not add or redesign content.
- Add regression coverage that asserts loading, ordinary failure, credential-reset failure, and ready menu content all report the same 380×540 fitting size.

## Alternatives rejected

- Fix the frame only at the scene root: this is broader than required and makes the startup view's own size contract less explicit.
- Disable animation: the panel would still change size and could visibly jump.
- Reduce the ready panel to 240 points: monitoring content requires the established 540-point viewport.

## Non-goals

- Do not change the top bulb icon.
- Do not change state-side icons, activity colors, glow behavior, or state classification.
- Do not change startup sequencing, hook reconciliation, or relay behavior.

## Verification

- A regression test must fail against the current 240-point startup height before production code changes.
- The focused startup and menu rendering tests must pass after the frame is fixed.
- The full Swift test suite must pass.
- A live quit/relaunch sample must remain 380×540 from the first visible startup frame through the ready monitoring frame.

## Acceptance criteria

- Opening Agent Light immediately after launch never exposes a 380×240 panel.
- The visible panel remains 380×540 while startup transitions to monitoring.
- Existing bulb and state presentation tests remain unchanged and pass.
