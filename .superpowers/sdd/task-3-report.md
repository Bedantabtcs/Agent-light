# Task 3 Report: Bounded Relay Delivery and Concurrent Socket Draining

## Status

Implemented and verified from base `1953f2653c214bdd8b154e8bc92af0c5cb75ef85`.

## RED evidence

Tests were added before production edits.

- `swift test --filter RelayDeadlineTests` failed with the expected missing `DatagramSendingSystem`, `DatagramSendResult`, `UnixDatagramSender.deliveryBudget`, initializer, and `sendFailOpen` API errors.
- `swift test --filter UnixDatagramTests` failed with the expected missing bounded handler-registry initializer/API.
- A second RED cycle for receive-order preservation failed on the absent owned-task count boundary before handler chaining was added.

## Implementation

- Replaced the blocking sender with a nonblocking Unix datagram sender.
- Added an injectable syscall and monotonic-clock boundary.
- Computes one 100 ms `ContinuousClock` deadline before transport and reuses it across every interrupted poll.
- Attempts one immediate send, waits only after `EAGAIN`/`EWOULDBLOCK`, and performs one final send attempt when writable.
- Missing/refused sockets, queue pressure, transport errors, incomplete sends, and deadline expiry return non-delivery without output; the relay process exits successfully.
- Rejects invalid socket paths and payloads larger than `RelayEnvelope.maximumEncodedBytes` before socket creation.
- Closes every successfully opened sender descriptor exactly once through one `defer` path.
- The server receive loop registers handler tasks without awaiting handler execution.
- Handler tasks are lock-registered before they can remove themselves, eliminating completion-before-registration and actor-reentrancy registry races.
- Handler work is chained in receive order so `RelayEventCoordinator` remains the sequence authority.
- Outstanding handler work is capped at 64 in production. Excess datagrams are dropped under overload rather than creating unbounded tasks.
- `stop()` first cancels and awaits the receive task, then cancels and awaits the stable owned-handler snapshot, and only then unlinks the socket inode if ownership still matches.

## Verification

- `swift test --filter RelayDeadlineTests`: 8 tests, 0 failures.
- `swift test --filter UnixDatagramTests`: 11 tests, 0 failures.
- `swift test --filter EndToEndPipelineTests`: 3 tests, 0 failures.
- Relay deadline suite stress: 20/20 runs passed.
- `swift test --parallel`: 502 tests completed, command exited 0.
- `swift build -c release`: passed.
- `./scripts/build-app.sh release`: passed.
- `codesign --verify --deep --strict "build/Agent Light.app"`: passed.
- `plutil -lint "build/Agent Light.app/Contents/Info.plist"`: OK.
- `git diff --check`: passed.
- Changed-source scans found no debug logging, credential material, unsafe dynamic evaluation, forbidden external-mutation paths, or unowned task creation.

The subprocess test invokes the built relay through `/usr/bin/time`, uses an isolated `CFFIXED_USER_HOME`, verifies exit status 0 and empty stdout/stderr, and observes total child runtime below 200 ms. Deterministic fake-system tests, not wall-clock timing, own the exact 100 ms deadline assertion.

## Concerns

- The 64-task cap intentionally drops excess datagrams while handlers are saturated. This is the bounded fail-open overload behavior; it prevents the relay server from accumulating unbounded work.
- Explicit `stop()` provides the await guarantee. Deinitialization can only cancel synchronously, so application lifecycle code must continue calling `stop()` before releasing a running server.
