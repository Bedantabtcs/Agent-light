# Agent Light Owned Hook Path Reconciliation

**Date:** 2026-07-08  
**Status:** Approved

## Problem

Agent Light currently writes the absolute path of its bundled relay into the Claude Code, Codex, and Cursor hook files. The app was first run from a feature worktree, so every owned hook still points into `.worktrees/codex-agent-light`. After the worktree was removed and the app moved to the main checkout, those commands became non-executable. Agent events therefore never reached the live Unix socket.

The apparent Cursor/Working state was separate test residue: a synthetic Cursor session ended with a Working event and no `sessionEnd`. That session has been explicitly cleared and is not a product integration event.

## Selected design

### Stable local runtime

- Treat `~/Applications/Agent Light.app` as the canonical local runtime location.
- Update the local installer to quit the currently running Agent Light instance, atomically replace the canonical bundle, verify its signature, and relaunch only that bundle.
- Continue deriving the relay executable from `Bundle.main`; the canonical bundle therefore produces one stable hook path.

### Receipt-verified startup reconciliation

- Add a dedicated launch-time reconciliation operation after ownership hydration and before relay acceptance completes.
- Reconcile only when a valid persisted integration receipt proves Agent Light owns the existing hook entries.
- Verify the fingerprint of each owned hook set before preparing any mutation.
- Generate the desired commands using the relay path from the currently running bundle.
- If all owned commands already match, perform no filesystem writes and leave the receipt unchanged.
- If only the owned relay path is stale, atomically update all three hook files, preserve unrelated entries and file permission bits, verify the committed files, and persist the updated receipt before reporting success.
- If an owned hook was externally changed, a file is unsafe, an atomic write fails, or the updated receipt cannot be persisted, fail closed into the existing repair-required flow. Do not overwrite unverified content or report integrations as healthy. The local socket may still start afterward so the repair UI and fail-open agent hooks remain operational.

### Existing manual repair

- Keep the Settings repair action available.
- Route both manual health repair and launch-time path reconciliation through the same receipt-verified installer primitive so they cannot diverge.
- Do not reinstall credentials, change Tuya settings, alter unrelated hooks, or reset ownership as part of path reconciliation.

## Data flow

```text
Launch canonical app
  -> hydrate ownership receipt
  -> verify current owned hook fingerprints
  -> compare owned commands with Bundle.main relay path
       -> match: no write
       -> stale path: atomic three-file update + new receipt
       -> mismatch/failure: repair-required, no blind mutation
  -> start the local relay socket after reconciliation resolves
```

## Alternatives rejected

- One-time manual rewrite: repairs today’s files but fails again after another bundle move.
- Keep running directly from repository build folders: branch and worktree changes make those paths inherently unstable.
- Copy only the relay into Application Support: introduces a second executable lifecycle, signing/version skew, and additional cleanup authority.
- Stable symlink or wrapper: weakens the existing no-symlink file-safety model and can silently redirect hook execution.

## Testing

- Start with hooks installed for an old bundle path and a valid receipt; launch reconciliation must replace only Agent Light-owned commands with the new path and return an updated receipt.
- Run reconciliation twice; the second run must perform no writes.
- Add unrelated hooks and fields; they must remain byte-equivalent in decoded JSON after reconciliation.
- Modify one owned command externally; reconciliation must fail without mutating any source.
- Inject failures at prepare, commit, verification, and receipt persistence boundaries; the app must expose repair-required state and retain recovery authority.
- Verify reconciliation finishes before relay acceptance during launch.
- Build and install the app at `~/Applications/Agent Light.app`, verify the bundle signature and private socket, and confirm every owned command points to that bundle.
- Send bounded synthetic hook fixtures through the installed Claude Code, Codex, and Cursor commands and verify source attribution, terminal cleanup, and live light switching.

## Acceptance criteria

- Claude Code, Codex, and Cursor hooks execute the relay from `~/Applications/Agent Light.app`.
- Moving from a development bundle to the canonical local bundle repairs verified owned paths automatically on the next launch.
- A normal relaunch with matching paths writes no hook files.
- Externally changed owned hooks are never overwritten automatically.
- Unrelated hook configuration and original permission bits are preserved.
- Startup never reports integrations healthy before any required path reconciliation and receipt persistence completes.
- Completed or ended sessions do not leave synthetic test sessions active.
