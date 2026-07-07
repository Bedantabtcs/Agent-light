# Task 9 Report: Secure Credentials and Login Launch

## Status

Implemented and verified; ready for review/testing.

## Implementation

- Added a Swift 6 `CredentialStoring` boundary and `KeychainCredentialStore` backed by one Security generic-password item.
- Used the exact supplied service/account identity for add, update, load, and delete; production defaults are `AppIdentity.keychainService` and `AppIdentity.bundleIdentifier`.
- JSON-encoded `TuyaCredentials`, applied `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, updated duplicate items with `SecItemUpdate`, requested one data result, and treated delete-not-found as success.
- Revalidated decoded endpoints against the existing Tuya request boundary: HTTPS, a nonempty host, no user info/query/fragment, and only an empty or root path.
- Reduced credential failures to operation plus `OSStatus`, or a generic malformed-data error. No credential fields, endpoint, encoded JSON, query attributes, returned Keychain bytes, or underlying decoding errors are retained in errors.
- Added an injected synchronous Security seam covering deterministic status, result-type, query, duplicate-race, and redaction behavior.
- Added the main-actor `LoginItemControlling` boundary and a small `SMAppService.mainApp` adapter/status seam.
- `isEnabled()` maps only `.enabled` to true. Registration occurs only from `.notRegistered` or `.notFound`; unregistration occurs only from `.enabled` or `.requiresApproval`; approval-pending and already-desired states do not repeat operations.
- Wrapped login-item adapter failures in generic typed errors and left default auto-launch policy/application wiring for Task 10.

## TDD Evidence

### Initial RED

Command:

```sh
swift test --filter CredentialStoreTests
```

Result: exit 1. Compilation failed because `KeychainCredentialStore`, `SecurityOperations`, `CredentialStoreError`, and the login-item seam/controller types did not exist. Log: `/tmp/task9-credential-red.log`.

### Focused GREEN

Commands:

```sh
swift test --filter CredentialStoreTests
swift test --filter LoginItemControllerTests
```

Results:

- Credential store: exit 0; 14 tests passed, 0 failures. The uniquely named real Keychain round-trip ran and passed in this environment. Log: `/tmp/task9-credential-green-final.log`.
- Login item: exit 0; 7 tests passed, 0 failures. Every test used the fake adapter and did not mutate the user's login-item state. Log: `/tmp/task9-login-item-green-final.log`.

The first focused implementation run exposed an incorrect test-only expected dictionary count of six; the asserted add query contains the required five attributes. Correcting that expectation produced the focused green result without a production-code change.

## Verification

- `swift test`: exit 0; 255 tests passed, 0 failures. Log: `/tmp/task9-full-test-final.log`.
- `swift build -c release`: exit 0. Log: `/tmp/task9-release-build-final.log`.
- `git diff --cached --check`: exit 0 with no output.
- Source scan found no debug output, TODO/FIXME markers, dynamic evaluation, force casts, forced tries, commented-out code, or credential values outside explicit test canaries.

## Security Review

- Production source contains no credential literals or hidden auto-registration side effects.
- Security errors preserve only a fixed operation enum and numeric `OSStatus`; JSON failures and invalid/unexpected Keychain data collapse to `.malformedData`.
- The store is checked `Sendable` with immutable identity and operation dependencies; the production Security adapter is stateless.
- Login-item APIs and their adapter are main-actor isolated. Unknown future service statuses fail closed without registration changes.

## Concerns

- The real Keychain test passed in the current unsigned test environment, but other CI environments may deny Keychain access; the test skips only entitlement, UI-interaction, authentication, or service-availability denial statuses and always attempts cleanup.
- Real `SMAppService.mainApp` registration was intentionally not exercised because tests must not change the user's login-item state. App-bundle wiring and manual System Settings approval checks remain Task 10/packaging acceptance work.
- `.requiresApproval` is registered but not enabled: requesting enable again is a no-op until the user approves it; requesting disable unregisters it.

## Next Step

Next phase: Task 10 — onboarding and monitoring view model.

Test this batch with:

```sh
swift test --filter CredentialStoreTests
swift test --filter LoginItemControllerTests
swift test
swift build -c release
```

Expected failure mode: a restricted runner may skip the real Keychain round-trip with an allowed Keychain-denial status; deterministic seam tests must still pass. Login-item tests must never prompt for approval or change the real service.

Ready-to-paste prompt for a fresh agent:

```text
Implement Task 10 from docs/superpowers/plans/2026-07-06-agent-light-macos-implementation.md using strict TDD. Read the approved design, Task 9 report, and the new CredentialStoring/LoginItemControlling boundaries first. Build onboarding and monitoring view-model behavior with fake dependencies, run focused and full verification, append the Task 10 report, and commit locally without pushing.
```

---

## Review Fix: Symmetric Credential Validation and Unknown Login Status

### Corrections

- Extracted one `TuyaCredentialValidator` used by both `save()` and `load()` so the accepted credential boundary cannot drift.
- Moved save validation ahead of JSON encoding and every Security operation. Invalid credentials now return the sanitized `.malformedData` error without add or update calls.
- The shared boundary rejects empty Access ID, Access Secret, and Device ID values. It rejects non-HTTPS or missing schemes, empty hosts, user info, query strings, fragments, and non-root paths.
- Added a stateful Security fake proving an invalid save cannot overwrite an existing valid credential record and that the original remains loadable.
- Added `.unknown` to the `isEnabled`, enable-transition, and disable-transition matrices. Both transitions fail closed without adapter calls.

### Review RED

Command:

```sh
swift test --filter CredentialStoreTests
```

Result: exit 1; invalid endpoint saves did not throw, each reached Security, and the stateful fake recorded one add plus one update that replaced the valid credential. Log: `/tmp/task9-review-credential-red.log`.

Command:

```sh
swift test --filter CredentialStoreTests/testSaveAndLoadRejectEmptyCredentialFieldsUsingTheSameBoundary
```

Result: exit 1; save and load accepted empty Access ID, Access Secret, and Device ID values. Log: `/tmp/task9-review-empty-fields-red.log`.

### Review GREEN and Final Verification

- `swift test --filter CredentialStoreTests`: exit 0; 17 tests passed, 0 failures. Log: `/tmp/task9-review-credential-green.log`.
- `swift test --filter LoginItemControllerTests`: exit 0; 7 tests passed, 0 failures. Log: `/tmp/task9-review-login-green.log`.
- `swift test`: exit 0; 258 tests passed, 0 failures. Log: `/tmp/task9-review-full-test-final.log`.
- `swift build -c release`: exit 0. Log: `/tmp/task9-review-release-build-final.log`.
- `git diff --cached --check`: exit 0 with no output.
- Source scan found no debug output, TODO/FIXME markers, dynamic evaluation, force casts, forced tries, commented-out code, or production credential literals. Credential strings found by the scan were explicit test canaries only.

### Review Concerns

- The validator intentionally rejects empty credential fields but does not normalize or trim them; Task 10 owns form normalization and pre-verification UX.
- The real login service remains intentionally untouched. Unknown future `SMAppService` statuses map to `.unknown` and cause no registration change.
