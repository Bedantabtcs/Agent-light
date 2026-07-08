# Task 4 Report: Integration Trust, Pending Login Approval, and Permission Preservation

## Status

Implemented from base `1d9a416acd9fe77b1618b14489a23816ddb89cf9`; ready for review/testing.

## RED evidence

Tests were added and observed failing before production edits.

- `swift test --filter IntegrationInstallerTests`: 9 assertion failures. Installed receipts had no trust field, and existing `0640`/`0644` files were replaced as `0600`.
- `swift test --filter AppViewModelTests`: 7 assertion failures. A newly registered `.requiresApproval` item was unregistered by compensation, its receipt was deleted, monitoring did not start, and status retry could not promote ownership.
- `swift test --filter ViewRenderingTests`: 8 assertion failures. Codex trust copy, `/hooks`, the exact integration ID, pending-login guidance, hosted controls, and README instructions were absent.

## Implementation

- Integration receipts now record Codex trust as `required`; Claude Code and Cursor record `notRequired`.
- Legacy receipts without trust metadata decode conservatively to Codex `required` and other-source `notRequired`.
- Codex trust confirmation is presentation-only and labeled `User confirmed`; it does not write Codex files or claim verified trust.
- Settings and README instruct the user to run `/hooks`, inspect integration ID `com.bbatchas.agentlight.hook.v1`, and trust the hook manually. README warns that untrusted hooks are skipped.
- A newly registered `.requiresApproval` login item persists as `pendingApproval`, continues safe monitoring, and is not unregistered as approval compensation.
- Retry Status reads login status only. An enabled status promotes durable ownership to `registered` without calling registration again.
- Explicit Disconnect still unregisters a verified pending registration. Other transaction failures still use existing reverse-order compensation.
- Legacy durable login value `owned` decodes as `registered`.
- Atomic replacement applies the pinned regular file's original permission bits to the staged inode before swap and verifies the final mode. Missing files remain `0600`; rollback artifacts remain protected and restore original bytes/mode.
- Existing symlink, non-regular-file, destination-race, atomic-swap, cleanup, and rollback protections remain in the same code paths.
- New actions use the existing hosted AppKit-backed button wrapper and stable accessibility identifiers. Guidance is fixed sanitized copy.

## Verification

- `swift test --filter IntegrationInstallerTests`: 40 tests, 0 failures.
- `swift test --filter AppViewModelTests`: 143 tests, 0 failures.
- `swift test --filter ViewRenderingTests`: 21 tests, 0 failures.
- `swift test --parallel`: full suite completed without failures on rerun.
- One earlier full-parallel run hit the pre-existing wall-clock relay subprocess assertion at 0.68 s under load; its isolated rerun passed at 0.073 s, and the complete parallel rerun passed.
- `swift build -c release`: passed.
- `./scripts/build-app.sh release`: passed.
- `codesign --verify --deep --strict "build/Agent Light.app"`: passed.
- `plutil -lint "build/Agent Light.app/Contents/Info.plist"`: OK.
- `git diff --check`: passed.
- Documentation scan found `/hooks`, `Trust required`, `User confirmed`, exact integration ID, and skipped-hook warning in the intended UI/README locations.
- Added-source scans found no debug logging, dynamic evaluation, credential/private-key material, hardcoded secrets, direct Codex trust mutation, or trust storage writes.

No live HOME config, login registration, credentials, hooks, bulb, installed application, browser, or GitHub state was accessed or mutated.

## Concerns

- User confirmation is intentionally process-local presentation state. Relaunch returns Codex to `Trust required` because Agent Light cannot verify Codex's independent trust store.
- Live System Settings approval and Codex `/hooks` trust remain manual acceptance checks.

## Next Step

Next phase: Task 5 after review of this correction. Use a fresh agent because Task 5 changes independent adapter behavior.

Test this batch with:

```bash
swift test --filter IntegrationInstallerTests
swift test --filter AppViewModelTests
swift test --filter ViewRenderingTests
swift test --parallel
swift build -c release
./scripts/build-app.sh release
codesign --verify --deep --strict "build/Agent Light.app"
plutil -lint "build/Agent Light.app/Contents/Info.plist"
git diff --check
```

Expected failure modes: a pending login registration being unregistered during approval, a retry that registers again, Codex shown as trusted without a user declaration, or an existing config changing away from its original `0600`/`0640`/`0644` mode must fail the regressions.

Ready-to-paste prompt:

```text
Implement Task 5 from .superpowers/sdd/task-5-brief.md using strict TDD. Preserve Task 1 durable ownership, Task 2 lifecycle guarantees, Task 3 relay bounds, and Task 4 pending-login/trust/permission boundaries. Do not access or mutate live credentials, HOME hooks, login items, bulbs, installed applications, or GitHub. Run focused and full verification, write the Task 5 report, and commit locally without push.
```
