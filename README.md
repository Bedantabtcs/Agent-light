# Agent Light

Agent Light is a dark-mode macOS menu-bar app that turns a Tuya-compatible color light into a real-time activity indicator for Codex, Claude Code, and Cursor. It maps reading, editing, testing, completion, errors, and other agent states to distinct colors, then restores the light's previous state.

The current build has been tested with a Wipro RGB bulb connected through the Tuya cloud. Compatibility with other models depends on their advertised Tuya datapoints, described below.

The app bundle is built and ad-hoc signed on the user's Mac. It is not notarized or distributed as a prebuilt release.

## Prerequisites

- macOS 14 or newer.
- Xcode with Swift 6.2 or newer and Command Line Tools selected.
- A Tuya Developer Platform cloud project containing the target light, with permission to read its specification, read its status, and send commands.
- The Tuya Access ID, Access Secret, Device ID, and data center that match that project. Keep these values out of source files and terminal commands.
- Codex, Claude Code, or Cursor only for the corresponding manual integration checks. The automated suite uses sanitized fixtures.

Agent Light currently runs only on macOS. Windows and Linux are not supported.

## Supported smart lights

Agent Light supports Tuya cloud-connected RGB, RGBW, and other HSV-capable color lights that expose the standard lighting datapoints below. Brand name alone does not determine compatibility.

Required datapoints:

| Code | Tuya type | Purpose |
| --- | --- | --- |
| `switch_led` | Boolean | Turn the light on or off. |
| `colour_data_v2` or `colour_data` | JSON | Set HSV color and brightness. |

Optional datapoints:

- `work_mode`, as an Enum containing `colour`.
- `bright_value_v2` or `bright_value`.
- `temp_value_v2` or `temp_value`.

The light can connect directly over Wi-Fi or through a Tuya-compatible gateway, provided the individual light appears in the cloud project's device list and advertises the required datapoints. The setup verifier reads the live specification and status before saving credentials.

Commonly unsupported devices include:

- White-only or dimmable lights without an HSV color datapoint.
- Bluetooth-only lights that are not reachable through the Tuya cloud.
- Non-Tuya lights, local-only devices, or models using proprietary datapoint codes instead of the standard codes above.
- Devices whose project region, app account, or API permissions do not match the selected Tuya data center.

## Set up Tuya Developer Platform

1. Pair the light in the **Smart Life** or **Tuya Smart** mobile app. Confirm that power and color control work there before continuing.
2. Sign in to the [Tuya Developer Platform](https://developer.tuya.com/) using a developer account.
3. Open **Cloud > Cloud Project > Project Management**, upgrade or activate the IoT Core plan if Tuya requests it, and create a cloud project.
4. Set **Development Method** to **Smart Home**. Choose the data center that matches the region of the mobile-app account; this must also match the data center selected in Agent Light.
5. In the project's cloud services, subscribe to and authorize **IoT Core**, **Smart Home Basic Service**, and **Country and City Info**. Tuya may add other default services automatically.
6. Open **Devices > Link App Account**, choose **Add App Account** and **Tuya App Account Authorization**, then scan the QR code with the same Smart Life or Tuya Smart account that owns the light.
7. Open **Devices > All Devices** and confirm the light appears. Copy its **Device ID**.
8. Open the project's overview or authorization-key section and copy the **Access ID/Client ID** and **Access Secret/Client Secret**. Do not place these values in source files, shell commands, screenshots, or GitHub issues.

Tuya's current walkthrough is available in [Request Tuya Cloud API Key](https://developer.tuya.com/en/docs/developer/apply-cloud-api-key?id=Kff30z8sv62ah). The broader project flow is documented in [Smart Home Quick Start](https://developer.tuya.com/en/docs/iot/smart-home-quick-start?id=Kbvwrxn6mngbd).

## Build and run on a Mac

Clone the repository:

```bash
git clone https://github.com/Bedantabtcs/Agent-light.git
cd Agent-light
```

Confirm the active Swift toolchain:

```bash
swift --version
xcode-select -p
```

Run the automated tests:

```bash
swift test --parallel
```

Build and install the release app:

```bash
./scripts/install-local.sh
```

The installer builds `AgentLight` and `AgentLightRelay`, signs the bundle locally, installs it at `~/Applications/Agent Light.app`, replaces only an earlier install at that path, and opens the app. Agent Light appears in the macOS menu bar rather than the Dock.

For a debug bundle without installing it:

```bash
./scripts/build-app.sh debug
```

The debug app is written to `build/Agent Light.app`. The build scripts accept only `debug` or `release`; they do not read Tuya credentials.

### Complete setup in Agent Light

1. Open the menu-bar lightbulb icon.
2. Select the Tuya data center matching the cloud project.
3. Enter the Access ID, Access Secret, and Device ID.
4. Select **Verify & Connect**. Verification discovers and validates the light's advertised power and color capabilities without sending a light command.
5. Review the proposed Codex, Claude Code, and Cursor hook changes, then approve them if the paths are correct.
6. For Codex, run `/hooks`, review and trust the Agent Light hook, then select **I Confirmed in Codex** in Agent Light. Claude Code and Cursor do not use this Codex-specific trust step.
7. Run an agent prompt or a test command and confirm the light changes color. Pausing monitoring or quitting the app restores the captured pre-monitoring light state when it is still safe to do so.

The installer does not register a login item. Agent Light enables launch at login only after the user verifies the bulb and approves the in-app integration review. Settings can disable launch at login without disconnecting the bulb, removing hooks, or stopping monitoring.

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

### State colors and activity classification

| State | Color | Hex |
| --- | --- | --- |
| Thinking | Violet | `#8B5CF6` |
| Working | Blue | `#3B82F6` |
| Reading | Cyan | `#06B6D4` |
| Editing | Teal | `#14B8A6` |
| Testing | Pink | `#EC4899` |
| Needs You | Amber | `#F59E0B` |
| Completed | Green | `#22C55E` |
| Cancelled | Orange | `#F97316` |
| Error | Red | `#EF4444` |

All monitoring colors use 80% value/brightness.

Activity classification is local and ephemeral. The bundled relay inspects a tool name or shell command only long enough to classify it as Reading, Editing, Testing, or generic Working, then discards the raw value and sends only the sanitized category to the app. Unknown and generic activity falls back to Working blue. Explicit cancellation is currently supported only for Cursor's `stop` event with `aborted` status; the owned Codex and Claude Code hook event sets do not report an explicit cancellation state.

Rapid states inside the one-second outbound-command throttle window may collapse to the newest state, so a brief intermediate color may not reach the bulb.

## Privacy and security boundaries

- Tuya connection values are stored in Keychain, never in project files, hook arguments, UserDefaults, or logs.
- Signed Tuya requests can go only to an allowlisted regional HTTPS origin. The Access Secret is used for local request signing and is not sent as a request field.
- Hook input is reduced to source, event, session identifier, workspace basename, status, emission time, and an optional sanitized activity category. Prompt text, response text, reasoning, raw tool names, commands, tool arguments, and source code are neither persisted nor sent to the app or Tuya.
- The relay accepts at most 1 MiB of hook input and emits a validated envelope of at most 2,048 bytes.
- Relay delivery uses a nonblocking Unix datagram send with a 100 ms monotonic transport budget. Missing, refused, or overloaded sockets fail open; process launch, scheduling, and bounded input parsing are outside that transport-only budget and remain part of the manual end-to-end 200 ms check.
- The local Unix datagram socket is created with mode `0600` inside `~/Library/Application Support/Agent Light`.
- If the app or socket is unavailable, the relay exits successfully so the source agent is not blocked.
- The recovery record contains bulb state and command metadata, not credentials. Its directory is restricted to the current user.
- Completed/Cancelled/Error recovery metadata contains only the physical apply timestamp and deadline. The 8/8/12-second holds begin when the bulb command succeeds; slow or failed persistence cannot extend them.
- Outbound Tuya command attempts, including retries, authentication-retry command POSTs, and baseline restoration, begin no less than one second apart. Token requests are exempt. Obsolete retries are discarded when a newer desired state wins.
- Monitoring recovery is bounded to the active record, one previous record, one tombstone, one lock, and a transient fixed staging slot. Unknown files in the directory are not removed.

Agent Light stores a durable, non-secret ownership receipt at `~/Library/Application Support/Agent Light/setup-ownership-v1.json`. It records only setup ownership, integration fingerprints, login registration state, and repair obligations. It contains no Tuya credentials or prior credential values; credentials and any rollback backup remain in Keychain.

## Recovery and maintenance

- **Pause Monitoring** or ordinary **Quit** requests restoration of the captured pre-monitoring bulb state. Quit is non-destructive: it retains Keychain credentials, verified integration ownership, the durable receipt, and an owned login registration for the next launch.
- **Disconnect** (including the Replace Device removal flow) is the explicit destructive action. It restores the bulb when safe and removes only credentials, hooks, and login registration that the durable receipt and current files still prove Agent Light owns.
- **Reconnect Light** retries health checks and applies only the newest desired state; it does not replay old events.
- **Replace Device** stops monitoring, restores the owned baseline when safe, and returns to onboarding.
- **Preview Repair** shows proposed hook changes before **Confirm Repair** writes them.
- **Uninstall Integrations** removes only Agent Light-owned hook commands.
- Turning **Launch at login** off unregisters the login item and updates its ownership receipt while retaining credentials, hooks, the selected device, and monitoring. If saving fails, Agent Light first restores the registration. When macOS confirms the item is absent, **Retry saving disabled login state** repairs only the receipt without unregistering again; Unknown or Approval required status instead offers a read-only **Retry Status**. Relaunch derives the same state without enabling anything automatically.
- After an unclean exit, relaunch the app. It restores the recorded baseline only if the bulb still matches Agent Light's last command; an external bulb change is preserved as the new baseline.
- Stored Keychain credentials without a valid durable ownership receipt may be verified to rebuild the integration preview, but Agent Light does not install hooks or register login automatically. Approval remains explicit.
- If startup reports that invalid stored credentials could not be reset, resolve Keychain access and use **Reset & Retry**. If integration repair fails, inspect the reported path and permissions before retrying; do not delete unrelated hooks.
- If Tuya or the bulb is offline, leave the bulb untouched, restore connectivity, and use **Reconnect Light**.
- If launch-at-login shows approval pending, open **System Settings > General > Login Items**, allow Agent Light, then use **Retry Status**. The pending registration is retained for recovery and is not repeatedly registered; explicit Disconnect can remove it when ownership is still verified.

## Manual acceptance checklist

These checks intentionally are not performed by build or test scripts because they modify user configuration, access local credentials, launch the app, or operate a real bulb.

1. Run `./scripts/install-local.sh`, then confirm `~/Applications/Agent Light.app` appears only in the menu bar.
2. Enter deliberately invalid Tuya credentials and confirm nothing is saved.
3. Verify valid credentials, record the discovered power, mode, and color DP codes without recording credentials, review all hook changes, and approve installation.
4. Start local Codex, Claude Code, and Cursor sessions and confirm the newest accepted event controls the bulb across sources. Within those sessions:
   - Read a file and confirm Reading cyan.
   - Edit a file and confirm Editing teal.
   - Run a test command and confirm Testing pink.
   - Run a generic tool or unclassified command and confirm fallback Working blue.
   - Abort a Cursor run and confirm Cancelled orange; do not expect an explicit Cancelled transition from the current Codex or Claude Code hook event sets.
5. Trigger supported permission waits, completion, error, pause, quit, and reconnect behavior.
6. Confirm Completed holds for 8 seconds, Cancelled holds for 8 seconds, Error holds for 12 seconds, and the original bulb state is restored from both powered-on and powered-off baselines.
7. Open macOS Accessibility Inspector, select the bulb element `ambientBulb.status`, and for Reading, Editing, Testing, and Cancelled confirm label `Light state` and the matching state name as its accessibility value.
8. Close the app and invoke every installed hook. Each must exit successfully within 200 ms.
9. Inspect all three config files and confirm unrelated hooks remain semantically unchanged after install, repair, and uninstall.
10. Confirm launch at login is enabled only after approved setup and that relaunch resumes monitoring.
11. If macOS requires login-item approval, complete it in System Settings, select **Retry Status**, and confirm the app transitions from pending approval without registering a second item.
12. Turn **Launch at login** off from both Enabled and Approval required states; confirm monitoring, credentials, device selection, and hooks remain intact. If receipt saving fails after unregistering, confirm the switch returns On, an absent item offers **Retry saving disabled login state**, or an ambiguous status offers read-only **Retry Status**; verify both retries avoid register/unregister calls.
13. Quit and relaunch after approved setup; confirm masked Access ID and Device ID appear without another interactive connection attempt.

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
