# Agent Activity Colors — Design Specification

Date: 2026-07-08
Status: Approved conversational design; ready for written-spec review

## 1. Summary

Agent Light will distinguish reading/searching, editing/writing, testing/building, generic work, and explicit cancellation while preserving its existing lifecycle colors. Classification occurs locally in the relay. Only a bounded activity category enters the relay envelope; raw tool names, commands, arguments, paths, prompts, source text, and tool output remain excluded.

The existing one-second command throttle, newest-event arbitration, brightness, terminal holds, and bulb-baseline restoration remain unchanged except for the new Cancelled terminal state defined below.

## 2. Goals

- Show useful differences between common agent activities without turning every tool into a separate bulb state.
- Preserve the current privacy boundary: no raw tool or command data leaves the relay process or enters logs, persistence, the socket payload, or the Tuya API.
- Remain compatible with existing version-1 relay envelopes and installed hook commands.
- Degrade safely to the existing blue Working state whenever a source omits activity details or classification is uncertain.
- Distinguish an explicit user or source cancellation from a failure when the source exposes that outcome.

## 3. Non-Goals

- Inferring agent intent from prompts, response text, reasoning, file contents, paths, or tool output.
- Parsing arbitrary shell syntax or trying to recognize every test and build tool.
- Assigning colors by agent source, repository, language, or individual tool.
- Adding animations or increasing Tuya command frequency.
- Guessing that a session was cancelled when the source reports only a generic failure or stop.

## 4. State and Color Model

The normalized `AgentState` model gains four cases. Existing cases and colors remain unchanged.

| Normalized state | Meaning | Color | Behavior |
| --- | --- | --- | --- |
| Thinking | Reasoning after a prompt or tool result | Violet `#8B5CF6` | Hold until a newer event |
| Reading | Reading, listing, fetching, browsing, or searching | Cyan `#06B6D4` | Hold until a newer event |
| Editing | Creating, editing, writing, or patching content | Teal `#14B8A6` | Hold until a newer event |
| Testing | A recognized test, build, lint, type-check, or validation command | Pink `#EC4899` | Hold until a newer event |
| Working | Unclassified concrete tool or command activity | Blue `#3B82F6` | Hold until a newer event |
| Needs You | Explicit permission, confirmation, or input request | Amber `#F59E0B` | Hold until the session continues or ends |
| Completed | Successful turn completion | Green `#22C55E` | Hold for 8 seconds |
| Cancelled | Explicitly aborted or cancelled turn | Orange `#F97316` | Hold for 8 seconds |
| Error | Failed turn | Red `#EF4444` | Hold for 12 seconds |
| Idle | No active or held state | No monitoring color | Restore the captured baseline |

All monitoring colors continue to use the existing 80% value setting.

Cancelled uses the same eight-second terminal hold as Completed. A newer accepted event supersedes the hold. When the hold expires, normal arbitration resumes another active session or restores the baseline.

## 5. Activity Data Flow

```text
hook JSON on stdin
  -> source-aware local field extraction
  -> bounded activity classifier
  -> discard raw hook object
  -> RelayEnvelope(activity: reading|editing|testing|working)
  -> source adapter
  -> AgentState
  -> existing coordinator and Tuya command path
```

### 5.1 Relay Protocol

`RelayEnvelope` gains an optional, Codable activity category with these wire values:

- `reading`
- `editing`
- `testing`
- `working`

The field is optional so existing version-1 fixtures and older relay senders remain valid. The envelope version stays at 1 because the change is additive and old consumers ignore unknown JSON keys. The existing 2,048-byte encoded-envelope limit remains unchanged.

Only tool-start events may carry an activity category. Other events ignore activity data even if unexpected input fields are present.

### 5.2 Source-Aware Extraction

The relay reads only the documented tool-name field for each source and the minimum command field needed for strict test/build recognition. Extraction is implemented behind a source-aware API so each source can evolve independently.

The extractor must:

- inspect tool identifiers only when they are at most 256 UTF-8 bytes;
- inspect command strings only when they are at most 4,096 UTF-8 bytes;
- never place extracted raw strings in errors, logs, status messages, persistence, or the relay envelope;
- ignore unknown shapes, arrays, objects, duplicate aliases, and oversized values;
- return no category when required data is absent or ambiguous;
- keep existing prompt, response, reasoning, code, path, and argument sanitization behavior unchanged.

Source payload shapes must be covered by sanitized fixtures before enabling classification for that source. A source without a verified fixture falls back to Working.

## 6. Classification Rules

Classification is deterministic, case-normalized, and allowlist-based.

### 6.1 Reading

Known read-only tool identifiers map to Reading. Initial families include:

- file read, list, glob, find, and grep tools;
- codebase and text search tools;
- web search, fetch, and browser-open/read tools;
- MCP tools whose final normalized operation name is explicitly allowlisted as read, list, search, find, fetch, get, inspect, or view.

Generic MCP names are not classified by substring alone. The classifier uses normalized exact names or tested suffix rules to avoid treating mutating tools such as `get_and_delete` as read-only.

### 6.2 Editing

Known mutating content tools map to Editing. Initial families include:

- edit, write, create-file, and apply-patch tools;
- notebook or structured-document edit operations when the tool identifier explicitly denotes mutation.

Broad terms such as `update`, `create`, or `set` are not sufficient by themselves because they may represent external side effects unrelated to file editing. Unknown mutating tools remain Working.

### 6.3 Testing

Testing is emitted only for command-execution tools whose command begins with a strict recognized invocation after trimming surrounding ASCII whitespace. Commands containing newlines, shell control operators (`;`, `&&`, `||`, `|`), substitutions, or redirections are not classified as Testing. Initial families include:

- Swift and Xcode test/build commands;
- common JavaScript package-manager test, build, lint, and type-check scripts;
- direct test runners such as `pytest`, `go test`, `cargo test`, and `dotnet test`;
- common build and validation entry points such as `cargo build`, `make test`, Gradle test, and Maven test.

The classifier does not interpret shell expansions, aliases, variables, redirections, pipelines, or chained commands. Unsupported or ambiguous forms remain Working. False negatives are preferred over reading more command content or producing a misleading color.

Command inspection is local and ephemeral. The classifier returns only a category and immediately releases the raw input with the decoded hook object.

### 6.4 Generic Working

Any tool-start event that is valid but does not meet a Reading, Editing, or Testing rule maps to Working. Missing activity metadata also maps to Working, preserving current behavior.

## 7. Source Mapping

### 7.1 Codex

- `PreToolUse` maps its activity category to Reading, Editing, Testing, or Working.
- `PostToolUse` returns to Thinking.
- Existing prompt, permission, and completion mappings remain unchanged.
- Codex has no Cancelled mapping until an explicit, documented cancellation outcome is available in the installed hook surface.

### 7.2 Claude Code

- `PreToolUse` maps its activity category to Reading, Editing, Testing, or Working.
- `PostToolUse` returns to Thinking.
- Existing prompt, permission, completion, failure, notification, and session-end mappings remain unchanged.
- `StopFailure` remains Error unless its sanitized status explicitly and unambiguously identifies cancellation in a supported payload fixture.

### 7.3 Cursor

- `preToolUse` maps verified activity metadata when available; otherwise it remains Working.
- `beforeShellExecution` maps a recognized validation command to Testing and otherwise remains Working.
- Post-tool and post-shell events return to Thinking.
- `stop.status == "aborted"` maps to Cancelled.
- `stop.status == "error"` remains Error and `stop.status == "completed"` remains Completed.

## 8. UI Changes

The menu-bar presentation adds labels and symbols for the new states:

- Reading: `Reading` with `book.closed.fill`.
- Editing: `Editing` with `pencil`.
- Testing: `Testing` with `checkmark.seal.fill`.
- Cancelled: `Cancelled` with `xmark.octagon.fill`.

Symbols must use SF Symbols available on macOS 14. Existing accessibility identifiers and state-driven rendering patterns are extended rather than replaced. Text remains the primary accessible state indicator; color is supplemental.

## 9. Coordination and Persistence

- Reading, Editing, and Testing behave like Working in arbitration and have no timer.
- Cancelled behaves like a terminal state with an eight-second hold.
- Recovery metadata continues to persist desired RGB state and terminal deadlines, not raw activity inputs.
- Existing newest-event precedence, deduplication, one-second throttle, retry spacing, disconnect handling, and baseline restore rules remain unchanged.
- Rapid events inside the throttle window may still collapse to the newest state. This feature does not address the separately identified real-time latency behavior.

## 10. Security and Privacy Requirements

- Do not add raw tool names, commands, arguments, paths, prompts, outputs, or source text to `RelayEnvelope`.
- Do not log raw hook JSON or classification inputs, including in test failure descriptions.
- Bound every inspected string before classification.
- Use enum values for the wire category and reject unknown encoded categories during validated decoding.
- Maintain the relay's fail-open behavior and existing maximum input and output sizes.
- Include canary tests proving sensitive strings never appear in encoded envelopes, persisted recovery records, or surfaced errors.
- Do not use dynamic code execution or shell evaluation to classify commands.

## 11. Testing Strategy

### 11.1 Unit Tests

- Verify each new `AgentState` color and UI label.
- Verify exact allowlisted tool-name mappings for Reading and Editing.
- Verify exact recognized validation commands for Testing.
- Verify ambiguous, oversized, malformed, chained, or unknown inputs fall back to Working.
- Verify no raw classifier input appears in encoded envelopes or error descriptions.
- Verify old version-1 envelopes without activity still decode and map to Working.
- Verify unknown activity wire values are rejected as sanitized invalid payloads.
- Verify Cursor aborted maps to Cancelled while Cursor error remains Error.
- Verify Cancelled holds for eight seconds from successful physical apply and obeys newer-event arbitration.

### 11.2 Integration Tests

- Add sanitized Codex, Claude Code, and Cursor fixtures for every payload shape used by classification.
- Exercise fixture -> relay sanitizer -> socket -> adapter -> coordinator -> fake light for each new state.
- Confirm existing hook configuration ownership and merge behavior remains semantically unchanged.
- Confirm relay execution stays inside the existing transport budget with maximum-sized bounded inputs.

### 11.3 Manual Checks

- Trigger one representative read, edit, validation, generic tool, and explicit Cursor cancellation event.
- Confirm the bulb displays cyan, teal, pink, blue, and orange respectively.
- Confirm PostToolUse returns to violet and terminal cancellation restores the baseline after eight seconds.
- Confirm rapid transitions retain newest-event behavior and do not exceed the existing Tuya command cadence.
- Inspect installed hook files and recovery records to confirm raw tool and command data is absent.

## 12. Acceptance Criteria

- The five activity/outcome states display the approved colors when their explicit detection rules match.
- Existing lifecycle colors, brightness, and source mappings continue to work.
- Unrecognized or unsupported activity safely displays generic blue Working.
- Cursor cancellation is distinct from Cursor error; unsupported sources do not guess cancellation.
- No raw tool or command data crosses the relay socket or is persisted.
- Existing version-1 relay fixtures and hook installations remain compatible.
- Automated tests cover classification, privacy, adapters, coordination, UI, and end-to-end delivery.
- The live-bulb manual checks pass before the change is described as ready for review.
