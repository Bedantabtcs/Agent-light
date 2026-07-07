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
