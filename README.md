# Agent Light

Agent Light is a dark-mode macOS menu-bar app that reflects the newest local Codex, Claude Code, or Cursor agent state on one Wipro bulb through the Tuya Developer Platform. It maps Thinking, Working, Needs You, Completed, and Error to the approved palette, then restores the bulb's previous state.

This repository is under local development. The app bundle is ad-hoc signed, not notarized, and is ready for local testing only after the manual acceptance checks below. Building or installing the app never pushes to GitHub; no GitHub push occurs automatically.

## Prerequisites

- macOS 14 or newer.
- Xcode with the Swift 6.2 toolchain and Command Line Tools selected.
- A Tuya Developer Platform cloud project containing the Wipro bulb, with permission to read its specification and control it.
- The Tuya Access ID, Access Secret, Device ID, and data center that match that project. Keep these values out of source files and terminal commands.
- Codex, Claude Code, or Cursor only for the corresponding manual integration checks. The automated suite uses sanitized fixtures.

## Build and test

Run the complete automated suite:

```bash
swift test --parallel
```

Build an ad-hoc-signed debug app at `build/Agent Light.app`:

```bash
./scripts/build-app.sh debug
```

The build script accepts only `debug` or `release`, compiles both `AgentLight` and `AgentLightRelay`, replaces the previous local bundle, and signs it ad hoc. It does not read Tuya credentials or modify agent configuration.

To build a release bundle, copy it to `~/Applications`, and open it:

```bash
./scripts/install-local.sh
```

The installer does not register a login item. Agent Light enables launch at login only after the user verifies the bulb and approves the in-app integration review.

## Tuya setup

1. In the Tuya Developer Platform, confirm the Wipro bulb is online and linked to the intended cloud project.
2. Confirm the project's data center. Agent Light permits only the listed Tuya API origins shown in onboarding; arbitrary endpoints are rejected before signing.
3. Open Agent Light and choose the matching data center.
4. Enter the Access ID, Access Secret, and Device ID in the app. Do not paste them into this repository, a shell command, or an issue.
5. Select **Verify & Connect**. Agent Light validates credentials and discovers the bulb's advertised power, mode, and color capabilities without issuing a light command.
6. Review the exact hook paths and before/after summaries. Approve only if the changes are expected.

Invalid credentials, unsupported schemas, and invalid endpoints remain in onboarding and are not saved. Verified values are stored in the user's macOS Keychain under the Agent Light service only after the integration review is approved.

## Agent integrations

Agent Light reviews and, after approval, updates these global user configuration files:

- Codex: `~/.codex/hooks.json`
- Claude Code: `~/.claude/settings.json`
- Cursor: `~/.cursor/hooks.json`

Existing JSON is parsed and unrelated hook semantics are preserved. Agent Light owns only commands containing its stable integration identifier. The installed commands use an absolute, shell-quoted path to the bundled `AgentLightRelay`. Repair and uninstall actions apply the same ownership rule.

Codex trust remains a separate manual decision after installation:

1. Open Codex and run `/hooks`.
2. Review the exact Agent Light hook command and integration identifier `com.bbatchas.agentlight.hook.v1`.
3. Trust the hook in Codex, then return to Agent Light and select **I Confirmed in Codex**.

Agent Light records only that the user confirmed this step; it cannot verify or modify Codex trust. Until the hook is trusted, Codex may silently skip it—untrusted hooks are skipped rather than treated as active monitoring. Claude Code and Cursor do not use this Codex-specific trust step.

## Privacy and security boundaries

- Tuya connection values are stored in Keychain, never in project files, hook arguments, UserDefaults, or logs.
- Signed Tuya requests can go only to an allowlisted regional HTTPS origin. The Access Secret is used for local request signing and is not sent as a request field.
- Hook input is reduced to source, event, session identifier, workspace basename, status, and emission time. Prompt text, response text, reasoning, tool arguments, and source code are neither persisted nor sent by Agent Light.
- The relay accepts at most 1 MiB of hook input and emits a validated envelope of at most 2,048 bytes.
- The local Unix datagram socket is created with mode `0600` inside `~/Library/Application Support/Agent Light`.
- If the app or socket is unavailable, the relay exits successfully so the source agent is not blocked.
- The recovery record contains bulb state and command metadata, not credentials. Its directory is restricted to the current user.

## Recovery and maintenance

- **Pause Monitoring** or quit Agent Light to request restoration of the captured pre-monitoring bulb state.
- **Reconnect Light** retries health checks and applies only the newest desired state; it does not replay old events.
- **Replace Device** stops monitoring, restores the owned baseline when safe, and returns to onboarding.
- **Preview Repair** shows proposed hook changes before **Confirm Repair** writes them.
- **Uninstall Integrations** removes only Agent Light-owned hook commands.
- After an unclean exit, relaunch the app. It restores the recorded baseline only if the bulb still matches Agent Light's last command; an external bulb change is preserved as the new baseline.
- If startup reports that invalid stored credentials could not be reset, resolve Keychain access and use **Reset & Retry**. If integration repair fails, inspect the reported path and permissions before retrying; do not delete unrelated hooks.
- If Tuya or the bulb is offline, leave the bulb untouched, restore connectivity, and use **Reconnect Light**.

## Manual acceptance checklist

These checks intentionally are not performed by build or test scripts because they modify user configuration, access local credentials, launch the app, or operate a real bulb.

1. Open `build/Agent Light.app` and confirm it appears only in the menu bar.
2. Enter deliberately invalid Tuya credentials and confirm nothing is saved.
3. Verify valid credentials, record the discovered power, mode, and color DP codes without recording credentials, review all hook changes, and approve installation.
4. Start local Codex, Claude Code, and Cursor sessions and confirm the newest accepted event controls the bulb across sources.
5. Trigger supported permission waits, completion, error, pause, quit, and reconnect behavior.
6. Confirm Completed holds for 8 seconds, Error holds for 12 seconds, and the original bulb state is restored from both powered-on and powered-off baselines.
7. Close the app and invoke every installed hook. Each must exit successfully within 200 ms.
8. Inspect all three config files and confirm unrelated hooks remain semantically unchanged after install, repair, and uninstall.
9. Confirm launch at login is enabled only after approved setup and that relaunch resumes monitoring.

Expected failure modes:

- An unsupported bulb schema stops setup before any light command.
- Cursor versions without an explicit wait signal continue to report Thinking or Working instead of Needs You.
- An offline Tuya service leaves the bulb untouched, retains only the newest desired state, and displays reconnect guidance.
- A missing app socket never blocks the source agent.

## Local release verification

```bash
swift test --parallel
swift build -c release
./scripts/build-app.sh release
codesign --verify --deep --strict "build/Agent Light.app"
plutil -lint "build/Agent Light.app/Contents/Info.plist"
git diff --check
```

Before any readiness assessment, repeat those commands from a clean checkout, complete every manual acceptance item, review the local commit history, and confirm no credentials or generated recovery data are tracked. A separate formal readiness assessment is required before calling the app production ready.
