# Task 12 Report — App bundle packaging, fixtures, and end-to-end acceptance

Date: 2026-07-07
Base HEAD: `b8b83f6`

## Scope

- Added three socket-level end-to-end tests using the existing sanitized Codex, Claude Code, and Cursor relay fixtures.
- Each test sends fixture bytes through `UnixDatagramSender` and `UnixDatagramServer`, then uses the production `RelayEventCoordinator`, source adapter selection, session orchestration, throttle boundary, and a fake Tuya light controller.
- Added a macOS 14 menu-bar-only bundle plist and deterministic local build script that compiles and packages both `AgentLight` and `AgentLightRelay`, sets executable modes, and applies an ad-hoc signature.
- Added an explicit local installer that copies the release bundle to `~/Applications` and opens it. It does not register the login item; the approved in-app setup flow remains the owner of that change.
- Added setup, privacy, integration ownership, recovery, local verification, expected-failure, and manual acceptance documentation.

## TDD evidence

### End-to-end pipeline RED

- `swift test --filter EndToEndPipelineTests` exited 1 after the new tests were introduced because the sanitized fixture loader was not yet implemented (`cannot find 'fixtureData' in scope`).
- The first RED run also exposed invalid use of XCTest's synchronous autoclosure around async polling; the test was corrected before GREEN.

### End-to-end pipeline GREEN

- Added a bundle-resource fixture loader and bounded async polling around the one-second production throttle boundary.
- `swift test --filter EndToEndPipelineTests`: 3 passed, 0 failures.
- Verified mappings through the real local pipeline:
  - Codex `UserPromptSubmit` -> Thinking.
  - Claude Code `PermissionRequest` -> Needs You.
  - Cursor `stop` with sanitized `error` status -> Error.

## Packaging evidence

- `./scripts/build-app.sh debug`: exit 0.
- The debug bundle contained executable `Contents/MacOS/AgentLight` and `Contents/MacOS/AgentLightRelay` plus the required Info.plist and code-signature resources.
- Both scripts have mode `0755` and pass `bash -n`.
- Calling `build-app.sh` without a configuration exits with usage status 64.
- Two consecutive release packaging runs produced identical SHA-256 manifests for every file in the app bundle.
- `codesign -d --verbose=4` reports bundle identifier `com.bbatchas.agentlight` and an ad-hoc signature.
- The build script contains no credential lookup and the installer contains no login-item registration.

## Complete verification

- `swift test --parallel`: 426 tests executed, exit 0.
- `swift build -c release`: exit 0.
- `./scripts/build-app.sh release`: exit 0; both release products packaged.
- `codesign --verify --deep --strict "build/Agent Light.app"`: exit 0.
- `plutil -lint "build/Agent Light.app/Contents/Info.plist"`: `OK`.
- `git diff --check`: exit 0.
- Static scan: no debug logging or dynamic evaluation in production sources/scripts, and no private-key or credential-assignment patterns in the Task 12 files.
- App metadata check: `CFBundleExecutable` is `AgentLight` and `LSUIElement` is true.

## Intentionally unperformed manual acceptance

The following actions were not authorized for automation and were not performed:

- The app was not installed or opened.
- `install-local.sh` was not executed.
- No real Tuya credential was read, entered, or persisted.
- No Wipro bulb command was sent and no live device DP code was recorded.
- The actual `~/.codex/hooks.json`, `~/.claude/settings.json`, and `~/.cursor/hooks.json` files were not modified or inspected.
- Login launch was not registered.
- Live newest-event arbitration, terminal hold timing, powered-on/off baseline restoration, closed-app relay latency, and real integration semantic preservation remain manual checks.
- The final readiness gate requires repeating complete verification from a clean checkout after those device and integration checks.

## Limitations

- The local app bundle is ad-hoc signed and not notarized.
- Automated tests use a fake Tuya controller and sanitized fixtures; they do not prove the specific Wipro bulb's advertised schema or cloud behavior.
- This task does not establish production readiness. It produces a local package ready for review and manual testing after independent review.
- No GitHub push or pull request was performed.
