# Agent Light for macOS — Design Specification

Date: 2026-07-06
Status: Approved conversational design; ready for written-spec review

## 1. Product Summary

Agent Light is a native macOS menu-bar utility that connects to one Wipro smart bulb through the Tuya Developer Platform. It observes local Codex, Claude Code, and Cursor agent lifecycle events and maps the most recently active session to a physical bulb color.

The app uses a compact, dark Ambient Glass interface. After setup it launches at login, monitors automatically, and restores the bulb's previous state whenever monitoring stops or no agent state remains active after a terminal-state indication.

## 2. Goals

- Provide an ambient, glanceable signal for local coding-agent activity.
- Reliably support Codex, Claude Code, and Cursor through independent adapters.
- Distinguish thinking, concrete work, user attention, completion, and failure when the source tool exposes the required event.
- Ensure monitoring never blocks or changes agent behavior.
- Keep Tuya credentials and local agent metadata private.
- Preserve and restore the user's pre-monitoring bulb state.
- Behave as a polished macOS utility rather than a dashboard that demands attention.

## 3. Non-Goals for Version 1

- Monitoring agents running exclusively in remote or cloud environments when no lifecycle event reaches this Mac.
- Supporting more than one bulb.
- Direct LAN control or LocalTuya-compatible protocols.
- Mobile, Windows, or Linux apps.
- User-defined state rules, animation timelines, or custom color palettes.
- Capturing or displaying agent prompts, responses, tool arguments, source code, or reasoning content.

## 4. Platform and Experience

- Native SwiftUI macOS application targeting macOS 14 or later.
- `MenuBarExtra` is the primary surface, with a compact auxiliary window for onboarding and settings when required.
- The application is available in the menu bar and does not require a persistent Dock presence.
- Login-item registration starts the app automatically after the first successful setup.
- The selected visual direction is **Ambient Glass**: deep navy-black surfaces, restrained translucent layers, state-colored illumination, generous spacing, and native system typography.
- The light illustration uses an SF Symbol or another licensed system asset. It is not a custom-drawn approximation.

## 5. Core User Flows

### 5.1 First-Run Setup

1. The app explains that it needs Tuya cloud credentials and local agent-hook access.
2. The user chooses the Tuya data-center endpoint and enters Access ID, Access Secret, and Device ID.
3. **Verify & Connect** obtains a token, fetches device status and capabilities, and validates color control.
4. The app displays the exact Codex, Claude Code, and Cursor hook entries it will add.
5. The user approves installation. The installer merges only Agent Light-owned entries into the existing global configuration files.
6. The app verifies the relay and hook configuration, enables launch at login, captures the bulb baseline, and begins monitoring.
7. If any step fails, the app reports the failing layer and leaves existing agent configuration intact.

### 5.2 Normal Monitoring

1. A supported agent emits a lifecycle hook event.
2. The installed relay validates and forwards a sanitized event through a local Unix socket.
3. The app normalizes the source event into the shared state model.
4. The session coordinator chooses the newest meaningful event across all sessions.
5. The UI updates immediately and the Tuya client sends a deduplicated bulb command.
6. Completion and failure colors remain visible for their defined hold time, then the coordinator resumes another active session or restores the bulb baseline.

### 5.3 Pause, Quit, and Recovery

- Pausing monitoring ignores incoming relay events but leaves integrations installed.
- Pausing or quitting performs a best-effort baseline restore.
- Hooks always fail open and exit successfully when the app or socket is unavailable.
- The app persists a recovery marker, the captured baseline, and its last commanded state.
- After an unclean exit, the next launch restores the baseline only when the bulb still matches Agent Light's last command. A manual change made outside Agent Light is respected and becomes the new baseline.

## 6. State and Color Model

The physical bulb receives one static command per meaningful state transition. Ambient pulsing is limited to the app UI so the cloud API is not used as an animation channel.

| Normalized state | Intended meaning | Color | Physical behavior |
| --- | --- | --- | --- |
| Thinking | A prompt was submitted and the agent is reasoning or deciding its next action. | Violet `#8B5CF6` | Hold until a newer event. |
| Working | A tool, command, file edit, or other concrete action is executing. | Blue `#3B82F6` | Hold until a newer event. |
| Needs You | The agent explicitly reports that it needs permission, confirmation, or input. | Amber `#F59E0B` | Hold until the session continues or ends. |
| Completed | The latest turn completed successfully. | Green `#22C55E` | Hold for 8 seconds. |
| Error | The latest turn failed or was aborted. | Red `#EF4444` | Hold for 12 seconds. |
| Idle | No session has an active or held terminal state. | No monitoring color | Restore the captured baseline. |
| Disconnected | Tuya or the bulb cannot be reached. | No new command | Leave the bulb untouched and show an offline UI state. |

### 6.1 Source Mapping

- **Codex:** `UserPromptSubmit` maps to Thinking; `PreToolUse` maps to Working; `PostToolUse` returns to Thinking; `PermissionRequest` maps to Needs You; `Stop` maps to Completed; reported failures map to Error. When the terminal hold expires, the session becomes Idle because the current Codex hook surface does not expose a separate session-end event.
- **Claude Code:** `UserPromptSubmit` maps to Thinking; `PreToolUse` maps to Working; `PostToolUse` returns to Thinking; `PermissionRequest` or `Notification.agent_needs_input` maps to Needs You; `Stop` or `Notification.agent_completed` maps to Completed; `StopFailure` maps to Error; session end maps to Idle.
- **Cursor:** `beforeSubmitPrompt` maps to Thinking; `preToolUse` and concrete before-execution hooks map to Working; post-execution hooks return to Thinking; `stop.status` maps to Completed or Error; session end maps to Idle. Needs You is reported only when Cursor exposes an explicit waiting or approval signal. Version 1 does not infer a permission wait from process state.

Adapter mappings are capability-driven and versioned. Missing optional events reduce state granularity without breaking monitoring.
Error and Needs You states are emitted only from explicit source events or statuses. Version 1 does not infer either state from process activity, elapsed time, response text, or tool arguments.

### 6.2 Arbitration

- Events receive an app-side monotonic sequence when accepted by the socket.
- The session with the newest meaningful accepted event controls the bulb.
- A completion or error hold cannot override a newer event from another session.
- When a terminal hold expires, the coordinator selects the newest still-active session; otherwise it restores the baseline.
- After app restart, sessions are inactive until a new valid hook event arrives.

## 7. Architecture

```text
Codex hooks ---------\
Claude Code hooks ----> signed relay CLI -> Unix socket -> event normalizer
Cursor hooks --------/                                  -> session coordinator
                                                          -> SwiftUI state
                                                          -> Tuya client -> Wipro bulb
```

### 7.1 Application Modules

- **App shell:** menu-bar lifecycle, login-item registration, windows, and shared application state.
- **Onboarding and settings:** Tuya connection, integration review, health checks, and recovery actions.
- **Integration installer:** source-aware, atomic merge and removal for the three global hook configurations.
- **Relay protocol:** strict, versioned JSON envelope containing only source, event type, session ID, workspace label, status, and timestamp metadata.
- **Event normalizer:** converts tool-specific events into a typed shared event enum.
- **Session coordinator:** owns session state, precedence, terminal timers, and baseline-restore decisions.
- **Tuya client:** authentication, request signing, token refresh, capability discovery, status reads, commands, retry policy, and color conversion.
- **Credential store:** Keychain-backed storage for Tuya endpoint, Access ID, Access Secret, and Device ID.

Each module exposes a protocol suitable for deterministic unit tests. UI code depends on protocols and observable view models, not network or file-system implementations.

### 7.2 Relay

- A small signed command-line executable is bundled with the app and installed under the user's Application Support directory.
- Agent configs invoke the relay with the event source and event name; event JSON is read from standard input.
- The relay allowlists fields, rejects oversized or malformed payloads, and connects only to the user-owned Unix socket.
- The socket and its parent directory use user-only permissions.
- The relay accepts at most 1 MiB of raw hook input and emits a normalized envelope no larger than 2 KiB.
- The relay uses a 100 ms connection timeout and a 200 ms total delivery timeout, then exits with status 0 whether delivery succeeds or fails.
- No TCP listener, privileged helper, kernel extension, or long-running daemon is required in version 1.

### 7.3 Integration Installation

- Global user hooks are used so Agent Light works across repositories.
- Existing configuration is parsed and preserved. Only entries carrying Agent Light's stable identifier are added, updated, or removed.
- Writes use a same-directory temporary file and atomic replacement while preserving file permissions.
- Original bytes remain available in memory and in a protected temporary file until parse and verification checks succeed; temporary rollback material is deleted immediately afterward.
- Installation is idempotent and supports a **Repair Integrations** action.
- The user sees a human-readable summary before the first modification.
- Version 1 writes Agent Light entries to `~/.codex/hooks.json`, `~/.claude/settings.json`, and `~/.cursor/hooks.json` while preserving unrelated configuration semantics.

## 8. Tuya Integration

### 8.1 Authentication

- Requests use the regional Tuya endpoint chosen during onboarding.
- The client implements Tuya cloud HMAC-SHA256 request signing and token acquisition/refresh.
- Secrets are read from Keychain only when signing and are never placed in command-line arguments, user defaults, project files, or logs.

### 8.2 Capability Discovery

On verification, the app queries device information, status, functions, and specification. It matches known standardized lighting functions only after validating each function's schema and range. Expected candidates include power, work mode, color data, brightness, and color temperature, but the app does not assume one fixed Wipro data-point layout.

If the device cannot express color safely, setup stops with an unsupported-device message and sends no command.

### 8.3 Commands and Color Conversion

- Normalized RGB colors convert to the bulb's advertised HSV or color-data format and range.
- Monitoring uses 80% value/brightness unless the device schema requires a different safe range.
- A state transition may turn on the bulb and select color mode as part of the same logical command batch.
- Identical desired states are deduplicated.
- Commands are coalesced and limited to one request per second; the newest desired state wins.
- The baseline records every available restorable field, including power, work mode, color, brightness, and temperature.

## 9. UI Structure

### 9.1 Connected Monitor

- Connection status and current controlling agent.
- State-colored bulb illustration and Ambient Glass glow.
- Current normalized state and active workspace label.
- Lightweight list of Codex, Claude Code, and Cursor sessions.
- **Pause Monitoring** control.
- Entry point to settings and integration health.

### 9.2 Settings

- **Light:** connection health, masked identifiers, reconnect, and replace-device actions.
- **Integrations:** installed/needs-repair status for each agent and a previewable repair action.
- **General:** launch at login, monitoring enabled, and uninstall integrations.

The app does not expose custom colors or timing controls in version 1.

## 10. Error Handling

- **Invalid credentials or endpoint:** remain in onboarding; do not store unverified values.
- **Expired token:** refresh once and retry the original request once.
- **Rate limit or transient network error:** make at most three total attempts, using 500 ms and 1 second exponential delays plus jitter.
- **Bulb offline:** stop sending commands, retain only the latest desired state, and expose reconnect guidance.
- **Unsupported device schema:** send no control command and identify the missing capability.
- **Malformed relay event:** reject it without changing session or bulb state.
- **Hook configuration conflict:** leave the file unchanged and show the specific source and repair action.
- **Socket unavailable:** relay exits successfully without affecting the agent.
- **Reconnect:** apply only the current winning desired state, never replay historical events.

## 11. Security and Privacy

- Tuya tokens are transmitted only to the configured Tuya HTTPS endpoint as required for authenticated API requests. Access secrets and passwords are never transmitted.
- Prompt text, response text, reasoning content, tool arguments, and source code are never persisted or transmitted by Agent Light.
- Inputs are validated at the relay, socket, adapter, configuration, and Tuya-response boundaries.
- The event envelope uses typed allowlists and explicit size limits.
- Keychain holds all Tuya connection values.
- The Unix socket is available only to the current macOS user.
- Hook config commands reference the installed relay by an absolute quoted path and never interpolate event content into a shell command.
- No dynamic evaluation, debug logging, commented-out code, or untyped escape hatches are permitted.

## 12. Testing Strategy

### 12.1 Unit Tests

- Event decoding and normalization for all documented source events.
- Session arbitration, monotonic ordering, terminal holds, and stale-timer cancellation.
- State-to-color conversion across advertised Tuya ranges.
- Request canonicalization, HMAC signing, token state, deduplication, and throttling.
- Atomic config merge, idempotency, removal, rollback, and permission preservation.
- Baseline capture, conditional crash recovery, and restore behavior.

### 12.2 Integration Tests

- A local fake Tuya service covers token acquisition, status and specification reads, successful commands, authentication failures, refresh, rate limits, timeouts, and malformed responses.
- Recorded, sanitized hook fixtures cover Codex, Claude Code, and Cursor without requiring the tools during the automated suite.
- A real relay process sends events over a temporary user-only socket to verify timeout and fail-open behavior.

### 12.3 UI Tests

- First-run validation and secure-field behavior.
- Failed and successful Tuya verification.
- Integration review, installation failure, and repair states.
- Multi-session precedence, pause, reconnect, and offline presentation.
- Login-item preference persistence.

### 12.4 Manual Acceptance

- Verify the real Wipro bulb's discovered function schema and every state color.
- Run overlapping local sessions in Codex, Claude Code, and Cursor and confirm newest-event arbitration.
- Trigger a permission wait where supported, a successful completion, a failure, a pause, a quit, and a simulated reconnect.
- Confirm the original bulb state is restored and no agent workflow is delayed or blocked.

## 13. Acceptance Criteria

- A user can connect the existing Tuya-visible Wipro bulb without placing credentials in a project file.
- The app launches at login and resumes monitoring automatically after successful setup.
- Valid local lifecycle events update the UI within 250 ms and schedule the newest bulb state within one second, excluding Tuya network latency.
- The newest accepted event controls the bulb across simultaneous sessions.
- Completed and Error holds last 8 and 12 seconds respectively and never override a newer event.
- Pausing, clean quitting, and idle completion restore the captured bulb state.
- An unavailable app, socket, Tuya service, or bulb does not block an agent hook.
- The app sends no more than one Tuya command request per second and never replays obsolete state transitions.
- Existing unrelated hook configuration remains semantically unchanged across install, repair, and uninstall.
- Automated tests cover the state machine, adapters, config edits, signing, retries, throttling, and restoration logic.

## 14. Primary Technical References

- Codex hooks: <https://developers.openai.com/codex/hooks>
- Claude Code hooks: <https://code.claude.com/docs/en/hooks-guide>
- Cursor hooks: <https://cursor.com/docs/hooks>
- Tuya device control: <https://developer.tuya.com/en/docs/cloud/industrial-general-device-control?id=Kaiuyaapcr4lo>
- Tuya command API: <https://developer.tuya.com/en/docs/cloud/e2512fb901?id=Kag2yag3tiqn5>
- Tuya request signing: <https://developer.tuya.com/en/docs/iot/new-singnature?id=Kbw0q34cs2e5g>
