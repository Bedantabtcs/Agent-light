# Task 8 Lifecycle and Recovery Correction

## Context

Task 8 currently distributes reconnect ownership across a health task, throttle task, apply path, and completion latch. Review found termination paths that can leak completion, deadlock pause or stop, or drop a superseding winner. Conditional recovery clearing also compares only record values, so a later byte-identical file can be mistaken for the original ownership epoch.

## Chosen Design

Use one lifecycle-owned reconnect operation and versioned recovery-store identities.

### Reconnect Operation

The orchestrator owns at most one reconnect operation identified by a monotonic operation ID. Its phases are health check, command-window wait, apply, and terminal resolution.

Every exit—success, no winner, deduplication, supersession, failure, cancellation, pause, or stop—passes through one terminal resolver. The resolver completes waiters exactly once and clears operation state only when the operation is genuinely terminal.

A newer desired event during reconnect apply supersedes only the attempted state. The reconnect operation remains active, keeps the connection disconnected, and schedules the newest winner. It completes successfully only after the current winner applies or no winner requires an apply. Pause and stop cancel and drain the complete reconnect operation before restoration.

Concurrent reconnect calls share the same operation. Caller cancellation removes that caller's waiter. Shared work is cancelled only when the final waiter leaves or a newer lifecycle request invalidates the operation.

### Recovery Revisions

The recovery store returns a record together with an opaque revision identifying the exact stored file generation. The file-backed revision includes stable opened-file identity sufficient for compare-and-swap; the memory store uses a monotonic revision.

Save returns the installed revision. Clear requires the expected revision and record. It quarantines only that exact opened generation, directory-syncs and verifies the parent before declaring the clear committed, and performs tombstone cleanup separately. A later file with identical bytes but a different revision is never removed.

The orchestrator carries the revision with its ownership state and clear-pending state. A failed pre-commit clear can be retried against the same revision; a committed clear is never retried against a replacement.

### Lifecycle Cancellation

Lifecycle transitions use explicit operation ownership rather than actor-retained tasks that strongly hold the actor across dependency suspension. Each request registers a waiter. Cancellation unregisters the waiter and invalidates work only when ownership rules allow it. Every dependency await is followed by operation-ID and cancellation validation before state mutation.

## Error and Safety Semantics

- Generic Tuya business failures remain non-transient.
- Retry sleeps are registered only while the attempted state and lifecycle operation are current.
- Pause and stop cannot return while reconnect apply work can still affect the bulb.
- Recovery-file operations remain descriptor-relative, bounded, mode `0600`, owner/type/link validated, and sanitized.
- Cleanup failures after a durable commit do not turn a successful save or clear into an uncommitted result.

## Verification

Deterministic tests will cover:

- pause and stop during reconnect delay and physical apply;
- reconnect no-winner, deduplication, failure, cancellation, and supersession exits;
- a newer winner during blocked reconnect apply;
- concurrent reconnect callers and individual caller cancellation;
- cancellation of a sole blocked start caller without later activation;
- identical-byte recovery replacement with a different revision;
- pre-commit clear failure, committed clear cleanup failure, and parent replacement;
- repeated race runs under external time bounds.

The full Swift test suite, release build, diff check, and security scan remain required before re-review.

## Rejected Alternatives

- Patching distributed completion latches was rejected because repeated review cycles exposed new uncoordinated exits.
- Removing automatic reconnect apply was rejected because it would violate the approved reconnect behavior.
