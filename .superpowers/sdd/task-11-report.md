# Task 11 Report — Ambient Glass menu-bar UI and settings

Date: 2026-07-07
Base HEAD: `b011a1a70a72773fea04a1c10b5a045b9771f175`

## Scope

- Added the 380-point dark Ambient Glass menu-bar experience for onboarding, verification, integration review, approval, monitoring, pause, repair, settings, startup loading, and startup failure.
- Added centralized theme spacing, radii, surfaces, and approved state-color mapping. The SF Symbol bulb glow is UI-only, supports a static Reduce Motion path, and adds symbol/text distinctions for terminal and idle states.
- Added secure onboarding fields, local HTTPS-origin validation, sanitized errors, Keychain/security copy, exact integration paths and before/after/change summaries, scrollable session presentation, and stable accessibility identifiers.
- Added native Light, Integrations, and General settings with connection/restore, repair, monitoring, and launch-at-login status/action. No custom color or timing controls were added.
- Added production composition for Keychain credentials, login items, integration installation, Tuya verification/control, monitoring recovery, ownership ledger, relay socket, adapters, and coordinator.
- Added recovery-before-relay startup ordering, Keychain hydration through the existing view-model approval path, owned startup cancellation, relay-failure cleanup, and clean quit/disconnect behavior.

## TDD evidence

### UI rendering RED/GREEN

- RED: `swift test --filter ViewRenderingTests` exited 1 because `PreviewViewModel`, `MenuBarContentView`, `OnboardingView`, and `SettingsView` were missing.
- GREEN: the final rendering suite covers all phases at 380x540, long paths and session identifiers, 14-session scrolling, secure secret entry, exact integration paths, approved settings sections, accessibility identifiers, action dispatch counts, and Reduce Motion/high-contrast rendering paths.

### Launch-at-login boundary RED/GREEN

- RED: the focused view-model test failed compilation because `loginItemStatus` and `requestLaunchAtLogin()` did not exist.
- GREEN: status is read through `LoginItemControlling`, retry occurs only through the view-model action, transition ownership is recorded in the shared ledger, and errors remain allowlisted.

### Production adapter RED/GREEN

- RED: `TuyaLightControllerTests` failed compilation because `TuyaDeviceServicing` and `TuyaLightController` were missing.
- GREEN: the credential-backed adapter captures/restores exact baselines, applies schema-derived commands, and compares the current command state without exposing credentials.
- RED: `RelayEventCoordinatorTests` failed compilation because `RelayEventCoordinator` was missing.
- GREEN: relay data is size-bounded, decoded, validated, source-mapped, sequenced, and passed to monitoring; malformed input is ignored.

### App environment RED/GREEN

- RED: `AppEnvironmentTests` failed compilation because `AppEnvironment`, `RelayServing`, and `RelayEventCoordinating` were missing.
- GREEN: recovery completes before Keychain load, ledger synchronization, credential hydration, or relay acceptance. Stored credentials enter the existing connect/approval flow before the relay starts.
- RED: a relay-start failure left the hydrated view model monitoring; the focused test ended with `[approve, relayStart]` instead of cleanup.
- GREEN: startup failure stops the relay and disconnects owned monitoring state before presenting a sanitized failure screen.
- RED: stopping during blocked recovery still allowed one later relay start.
- GREEN: the environment cancels and awaits its owned startup task, with cancellation checkpoints before relay acceptance.
- RED: duplicate Tuya status codes trapped in `Dictionary(uniqueKeysWithValues:)`.
- GREEN: duplicate device status is rejected as `CapabilityError.duplicateStatus` without a process crash.

## Verification

- `swift test --filter ViewRenderingTests`: 9 passed, 0 failures.
- `swift test --filter AgentLightUITests`: 116 passed, 0 failures.
- `swift test`: 396 passed, 0 failures.
- `swift build -c debug`: exit 0.
- `swift build -c release`: exit 0.
- `git diff --check`: exit 0.
- Security/orphan scan: no debug logging, dynamic evaluation, force casts/tries, TODO/FIXME markers, private-key material, production canary credentials, custom state controls, or UI light-command calls in the Task 11 source.

## Review concerns

- The integration installer points at the bundled relay when packaged and falls back to the Application Support relay path during SwiftPM development. Task 12 must place the signed relay at the packaged/fallback path before manual integration approval.
- Automated rendering verifies the static Reduce Motion and increased-contrast paths through deterministic overrides because macOS exposes the corresponding SwiftUI environment values as read-only system settings. Manual acceptance should also toggle both system accessibility settings.

## Review-correction batch

Correction base: `a4331119eaa833eaf989d43a135bbf835a6a2144`

### Security boundary RED/GREEN

- RED: focused credential-store, client, and view-model tests demonstrated that arbitrary HTTPS origins, malicious subdomains, and non-default ports could cross the credential or request boundary.
- GREEN: `TuyaDataCenter` is the single exact allowlist for China, Western America, Eastern America, Central Europe, Western Europe, India, and Singapore. Keychain save/load validation, view-model draft validation, and request construction all reject non-allowlisted origins before signing or transport. Onboarding now exposes only the allowlisted data-center picker.

### Startup ownership RED/GREEN

- RED: retry could create unowned startup work, and lifecycle tests had no proof for concurrent retry coalescing, stop during retry, environment deinitialization during blocked recovery, or retry after a one-shot failure.
- GREEN: `AppEnvironment` owns one synchronously registered startup task, coalesces callers, cancels and awaits startup before stop cleanup, weakly finishes into the environment, clears task ownership for retry, and cancels blocked recovery on deinitialization. Retry invokes that owned entry point directly.
- Stress verification repeated the four critical lifecycle tests 20 times with all 80 executions passing and no orphaned test process.

### Settings and accessibility RED/GREEN

- RED: focused tests failed because masked identifiers, reconnect, replace-device, repair preview/confirmation, safe uninstall, and a native monitoring toggle were absent.
- GREEN: Settings now contains the approved Light, Integrations, and General controls. Credentials are masked to the last four identifier characters; the access secret is never rendered. Repair requires a complete path/before/after preview before confirmation. Uninstall preserves preexisting or uncertain ownership and records the corresponding repair obligation.
- RED: SwiftUI's virtual accessibility tree was empty in the SwiftPM-hosted XCTest process, so identifier-only constants and direct closure calls could not prove rendered controls were reachable or actionable.
- GREEN: critical controls use hosted AppKit buttons, picker, switch, and wrapping text fields. Tests traverse the actual `NSView` hierarchy, invoke rendered controls with `performClick`, verify action counts, verify default Return/Escape keys and initial picker focus, and confirm long sessions and complete integration summaries remain reachable.
- RED: the hosted monitoring-control test could not find an `NSSwitch` because the first native wrapper rendered an AppKit checkbox.
- GREEN: Settings now renders a labeled `NSSwitch`; the hosted test changes its state, sends its real target/action, and observes exactly one monitor pause.

### Correction verification

- `swift test --filter ViewRenderingTests`: 14 passed, 0 failures.
- `swift test --filter AppViewModelTests`: 113 passed, 0 failures.
- Endpoint/security focused suites: 45 passed, 0 failures.
- `AppEnvironmentTests`: 11 passed, 0 failures.
- Critical lifecycle subset repeated 20 times: 80 test executions passed, 0 failures.
- `swift test`: 414 passed, 0 failures.
- `swift build`: exit 0.
- `swift build -c release`: exit 0.
- `git diff --check`: exit 0.
- Static scan: no added TODO/FIXME markers, debug logging, forced casts/tries, fatal traps, private-key material, source credential literals, dynamic evaluation, custom color/timing controls, or direct UI light commands.
- Process scan: no orphaned `xctest` or `AgentLightPackageTests` process.

### Remaining manual checks

- Exercise picker-to-field focus progression and Return/Escape behavior in the packaged menu-bar window with VoiceOver enabled.
- Toggle macOS Reduce Motion and Increase Contrast in System Settings and verify the packaged app follows both settings.

## Final findings correction batch

Correction base: `87ab1cb1ae83f0609ff93f809eed7e271899a8f6`

### Lifecycle serialization and deinit cleanup RED/GREEN

- RED: a start requested while blocked startup cleanup was in progress entered recovery twice and started the relay once before cleanup completed (`2` versus `1` recoveries; `1` versus `0` relay starts). A start requested during ready cleanup was lost (`1` versus `2` final relay starts). Deallocating a ready environment produced no relay stop (`0` versus `1`).
- GREEN: `AppEnvironment` now owns an explicit `idle`, `starting`, `ready`, or `stopping` lifecycle plus one operation ID and tail task. Stop marks `stopping` before its first suspension, retains the tail through dependency cleanup, and coalesces any start requested during stop into one post-cleanup start.
- GREEN: a dependency-only `EnvironmentShutdownController` is armed per lifecycle, coalesces cleanup, and outlives the environment without retaining it. Ready and starting deinitialization stop the relay and invoke view-model disconnect/restoration exactly once.

### Stored credential recovery RED/GREEN

- RED: legacy arbitrary-origin credentials and malformed bytes both ended in permanent generic startup failure, never deleted the unusable item, and never started the relay. A delete failure had no explicit reset state and repeated the same failure.
- GREEN: `CredentialStoreError.malformedData` is handled separately. Startup deletes through `CredentialStoring`, keeps the view model in onboarding without the bad value, and continues recovery and relay startup without connection verification/signing. A failed delete presents the sanitized `credentialResetFailed` state with `Reset Stored Credentials & Retry`; retry reattempts deletion and then starts normally.

### Explicit Settings state RED/GREEN

- RED: focused tests did not compile because explicit integration-installed/status, monitoring-active, and monitoring-enable APIs were absent. The phase-derived switch could not pause or resume during repair, and post-uninstall Settings remained `Installed`.
- GREEN: the protocol and view model expose `integrationInstalled`, `integrationStatus`, and `monitoringActive`. Integration state is projected from the ownership ledger; monitor state changes only at monitor start/pause/resume/cleanup boundaries. Successful uninstall renders `Not Installed` in monitoring and keeps `integrationInstalled == false` when another obligation preserves repair phase.
- GREEN: `setMonitoringEnabled(_:)` pauses and resumes owned monitoring during `repairRequired`, preserves the repair phase and its sanitized error, refreshes observation on resume, and drives the native switch from `monitoringActive`.

### AppKit accessibility and Dynamic Type RED/GREEN

- RED: hosted tests reported unchanged `13`/`11` point fonts, a missing switch font, a picker without label/role/exposure, primary buttons as `AXUnknown` and ignored, and the switch as `AXButton`.
- GREEN: every native wrapper consumes SwiftUI `dynamicTypeSize` and applies deterministic system or monospaced AppKit font scaling. Hosted normal-versus-Accessibility 5 tests cover button, picker, switch, integration path/summary, and session workspace text while retaining finite 380-point layout and scroll reachability.
- GREEN: primary controls now set programmatic identifier, label, role, and accessibility-element exposure. The picker is exposed as `AXPopUpButton` with label `Tuya data center`; the visual switch is exposed with its checkbox accessibility role.

### Final verification

- `AppEnvironmentTests`: 16 passed, 0 failures.
- `AppViewModelTests`: 115 passed, 0 failures.
- `ViewRenderingTests`: 16 passed, 0 failures.
- Critical lifecycle subset repeated 20 times: 120 test executions passed, 0 failures.
- `swift test`: 423 passed, 0 failures.
- `swift build`: exit 0.
- `swift build -c release`: exit 0.
- `git diff --check`: exit 0.
- Static scan: no added TODO/FIXME markers, debug logging, forced casts/tries, fatal traps, private-key material, source credential literals, dynamic evaluation, custom color/timing controls, or direct UI light commands.
- Process scan: no orphaned `xctest` or `AgentLightPackageTests` process.

### Remaining manual checks

- With VoiceOver enabled in the packaged app, traverse the data-center picker and each primary action and confirm the programmed labels and roles are announced once.
- Set the packaged app to the largest supported text size and verify every Settings action and full integration preview remains reachable by scrolling.

## Monitoring status copy correction

Correction base: `ab54cf450e32f1d76643a6916a35b586e476090c`

- RED: the hosted repair-mode switch regression could not find a rendered monitoring-status element, and the phase-derived copy remained enabled while the explicit switch state was Off.
- GREEN: Settings renders the stable `settings.general.monitoringStatus` through `NativeWrappingText` and derives `Monitoring is enabled` or `Monitoring is disabled` solely from `viewModel.monitoringActive`.
- GREEN: the hosted regression verifies Enabled → Disabled → Enabled across repair-mode pause/resume while `phase == .repairRequired` and the original sanitized repair error is preserved.
- Focused hosted regression: 1 passed, 0 failures.
- `swift test`: 423 passed, 0 failures.
- `swift build`: exit 0.
- `swift build -c release`: exit 0.
