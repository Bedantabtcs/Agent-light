# Agent Light Stable Bulb Motion

**Date:** 2026-07-08  
**Status:** Approved

## Problem

The menu panel remains fixed at `380 × 540` points, but the central status illustration appears to shrink and grow. Its blurred glow currently scales between `0.92` and `1.08` on a repeating 2.4-second animation. The activity-colour update also introduced state-specific bulb glyphs with different optical bounds, making the existing scale pulse and state transitions newly conspicuous.

## Selected fix

- Keep the glow geometry fixed at `122 × 122` points.
- Replace the glow's scale pulse with a subtle opacity pulse so activity remains visible without apparent resizing.
- Keep the large top illustration as `lightbulb.led.fill` for every state.
- Show state-specific glyphs only beside the Thinking, Reading, Editing, Testing, and other state labels.
- Preserve the current state colours, 2.4-second cadence, high-contrast treatment, and Reduce Motion behavior.
- Keep the menu panel shell and surrounding layout unchanged.

## Alternatives rejected

- Disable all motion: removes useful ambient feedback and is broader than required.
- Reduce the scale range: still produces visible size changes.
- Change the large top glyph by state: duplicates the state-label icon and creates avoidable visual jumps.

## Testing

- Add a regression that describes the glow animation as opacity-only and verifies its scale remains constant.
- Add a regression that verifies the top illustration always uses `lightbulb.led.fill` while state-label icons remain distinct.
- Run the focused UI tests, then the full Swift test suite.
- Rebuild and open the local app, confirm the panel remains `380 × 540`, and visually verify the glow fades without growing or shrinking through Reading, Editing, and Testing transitions.

## Acceptance criteria

- The bulb illustration no longer appears to grow or shrink.
- The glow continues to pulse through opacity when Reduce Motion is off.
- Reduce Motion keeps the glow fully static.
- Activity colours remain unchanged, and state-specific symbols appear only beside their labels.
- The panel remains fixed at `380 × 540` points.
