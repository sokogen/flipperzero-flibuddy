# macOS app: bring the feed, status bar, sheets and settings to the design

## Overview
Implement `docs/design/macos-ui-spec.md` in the macOS app. The spec is the
distillation of the Claude Design project "FliBuddy mobile app design"
(macOS page and spec page). It changes layout, copy, focus behaviour and a
few view-model rules; it does not change the wire protocol or the Bambuddy
calls. Run this plan after Phase 2 (`phase2-ble-ios`) and the FliBuddy
rename have merged, because both touch the same view and view-model files.

What changes:
- the feed row becomes a one-line macOS row with fixed columns, UID under the
  title, a readout line and a "g" unit;
- focus and keyboard behaviour: newest waiting row focused with the
  suggestion selected, no focus stealing from a touched field, Tab order,
  ⌘S/Return, ⌘⌫ with confirmation, ⌘↑/⌘↓;
- Net/Gross conversion rule; `Saving…` and timeout states; reopening a saved
  row; Created keeps the row open with label + core pre-filled;
- status bar with symbols, tints, phrases and inline actions; blocking
  Spoolman state; empty-state copy;
- New spool sheet and Link picker per the spec;
- Settings labels, test-result phrases, footers, Revert and the
  saved/unsaved line.

## Context (from discovery)
- Views (after Phase 2 and the rename; adjust names if the rename has not
  happened): `host/Sources/SpoolBuddyUI/FeedView.swift` (feed, row, status
  bar), `UnknownRowActions.swift` (New form, Link picker), `SettingsForm.swift`,
  `host/Sources/SpoolBuddyMac/{App,SettingsView}.swift`.
- View models: `host/Sources/SpoolBuddyCore/ViewModels/FeedViewModel.swift`,
  `FeedItem.swift` (status text, `suggested(mode)`, `savedByText`,
  `requestText`), `FlipperLink.swift` (`statusText`), `HostModel.swift`,
  `SettingsViewModel.swift`, `NewSpoolForm.swift`.
- Session: `host/Sources/SpoolBuddyCore/Session/{Session,FeedRow,IntentHandler,LookupBuilder}.swift`
  (`FeedRow.Status`: scanned, awaitingWeight, unknown(prefill), saved,
  created, error; `Side`; `HostRequest`).
- Weight math: `host/Sources/SpoolBuddyCore/Bambuddy/WeightMath.swift`.
- Tests: `host/Tests/SpoolBuddyCoreTests/{FeedViewModelTests,SessionTests,FlipperLinkTests,SettingsViewModelTests}.swift`.
- The spec's prototype model (`flibuddy-core.js` in the design project) is
  the reference for the rules; its copy is quoted in the spec file.

## Development Approach
- **Testing approach**: TDD. Write the failing test, then the code.
- Complete each task fully before moving to the next
- Make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- Run tests after each change
- View logic lives in view models and small pure helpers so it is testable;
  SwiftUI views stay thin
- Follow `AGENTS.md`: English everywhere, one commit per task

## Testing Strategy
- **Unit tests**: required for every task (see Development Approach above)
- `cd host && swift test`; `make test`, `make lint`, `make coverage` at the end
- No UI test framework; the acceptance task runs the app and checks the
  windows by eye against the spec (recorded in the plan)

## Progress Tracking
- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Update plan if implementation deviates from original scope
- Keep plan in sync with actual work done

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): tasks achievable within this codebase - code changes, tests, documentation updates
- **Post-Completion** (no checkboxes): items requiring external action - manual testing, changes in consuming projects, deployment configs, third-party verifications
- **Checkbox placement**: Checkboxes belong only in Task sections (`### Task N:` or `### Iteration N:`). Do not put checkboxes in Success criteria, Overview, or Context — they cause extra loop iterations.

## Implementation Steps

### Task 1: Row view-model rules from the spec
- [ ] `FeedRow.Status`: add `saving` and `savedAfterTimeout` (saved by host after the Flipper reported a timeout); `Session` sets `saving` while the Bambuddy call runs and `savedAfterTimeout` when the `result` went out later than about 10 s after the intent arrived (approximate: the host measures its own latency against the Flipper's constant)
- [ ] `FeedItem`: `suggestion(mode:)` per the spec (base + core for gross, base for net; after Created base = label); `readout(value:mode:core:)` strings; `isEntry` (enter, saving, created, error); `isReopenable` (saved, timeout); `timeoutNote`; status symbol name and tint per state; accessibility header text
- [ ] `FeedViewModel`: a per-row draft (`value`, `touched`, `mode`); Net/Gross switch converts an untouched suggestion and keeps a typed value; `reopen(row)`; Save disabled rules (empty, negative net, saving)
- [ ] write tests: suggestion and readout for gross/net/empty/negative; conversion on mode switch (untouched vs touched); state → symbol/tint/text table; reopen; Created keeps the row open with label + core; a Flipper save clears the host draft and shows `by Flipper`
- [ ] run tests - must pass before task 2

### Task 2: Focus and keyboard model
- [ ] `FeedViewModel.FocusModel` (pure): `focusedRow`, `nextWaitingRow()`, `onRowBecameWaiting(id)` (takes focus unless another row is touched, then marks a hint), `onSaved(id)` (moves to the next waiting row), `moveFocus(.up/.down)`
- [ ] `FeedView`: `@FocusState` bound to the model, the field selects its text on focus, Tab order field → mode → Save, Return saves, `.keyboardShortcut("s", modifiers: .command)` saves the focused row, ⌘↑/⌘↓ move, ← → switch the segmented picker when focused
- [ ] write tests for `FocusModel`: new row focuses when nothing is touched; waits with a hint when a field is touched; after save moves to the newest waiting row; no waiting row keeps the selection; up/down bounds
- [ ] run tests - must pass before task 3

### Task 3: One-line row layout, swatch, readout, unit
- [ ] `FeedView` row: columns swatch 28 · title + UID · colour · remaining · status · field 96 × 34 · segmented ≈150 · Save; `.controlSize(.large)`; row height 60; entry controls only in entry states, space reserved otherwise; swatch with `.separator` stroke and dashed `.tertiary` outline when absent, hidden from VoiceOver; weight value 22 pt rounded bold monospaced digits via `@ScaledMetric`; "g" unit; readout line; timeout note; red status text only for errors
- [ ] write tests: `FeedItem` display strings for every state in the spec table (snapshot-style string tests); the row's accessibility header text
- [ ] run tests - must pass before task 4

### Task 4: Status bar with symbols, tints and actions; empty and blocking states
- [ ] `FlipperLink` and `FeedViewModel.bambuddy`: expose a `StatusItem` (text, symbol, tint, optional action) per the spec tables, including the `nohello` state (link open, no hello within 2 s) and `nocolors`
- [ ] `StatusBar` view: two items in `.footnote.weight(.medium)`, progress indicator for searching/checking, action buttons (Connect, Check, Retry, Settings) wired to `HostModel`
- [ ] `ContentUnavailableView`s: empty feed copy; blocking Spoolman state with Retry that re-runs the startup check; the list hidden while blocking
- [ ] write tests: state → `StatusItem` for all Flipper and Bambuddy states; Retry triggers the check; blocking flag
- [ ] run tests - must pass before task 5

### Task 5: Clear with confirmation, New sheet, Link picker
- [ ] Clear: toolbar button with `.keyboardShortcut(.delete, modifiers: .command)` opening `confirmationDialog("Clear the feed?")` with the spec copy; destructive Clear
- [ ] New spool sheet: title/subtitle, Material menu with the spec list and "Choose…", Subtype, Colour, Brand, Label weight (digits, default 1000), footer copy, Cancel · Create (disabled without material); the Bambu-tag **New** button creates directly, the no-prefill one is labelled "New…"
- [ ] Link picker: filter placeholder, row subtitle "colour · brand · n g left", note, "Tag <uid>" badge, empty copy, move-link warning text and "Move link" label when the pick carries another tag, Link disabled without a pick
- [ ] write tests: `NewSpoolForm` validation and label defaults; `LinkPickerModel` filtering over material/colour/brand/note, warning text and button label, empty state
- [ ] run tests - must pass before task 6

### Task 6: Settings per the spec
- [ ] `SettingsForm`: labels "Server URL", "API key"; test result phrases ("Not tested", "Testing…", "Ready · inventory access OK", "Unreachable: no answer within 5 s") with symbols; New items footer; Weighing title "I type the weight as" and footer; Flipper section with the Connection picker (USB only until Phase 2's Bluetooth lands; then USB | Bluetooth with Scan for Flipper and the connection line) and Forget (destructive); save row with "Unsaved changes" / "All changes saved", Revert and Save (default action, disabled when clean)
- [ ] write tests: `SettingsViewModel.hasChanges` drives the text and buttons; Revert restores the saved draft; test-result mapping
- [ ] run tests - must pass before task 7

### Task 7: Verify acceptance criteria
- [ ] every item of "Differences from the shipped macOS app" in the spec is implemented
- [ ] `swift run SpoolBuddyMac` (or the renamed target): main window and Settings compared with the spec by eye in light and dark; findings recorded in this plan
- [ ] `make test`, `make lint`, `make coverage` pass

### Task 8: Documentation
- [ ] `host/README.md`: keyboard shortcuts, row states, status bar actions
- [ ] `docs/design/macos-ui-spec.md`: mark anything implemented differently and why

## Technical Details
See `docs/design/macos-ui-spec.md` for every string, symbol, size and rule.
Core weight for the readout comes from the matched spool (`core_weight`), not
from the settings, except for Created rows where it is the settings value
just sent.

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

- Owner: run the app on the bench with the Flipper; check that focus lands
  on the newest row after a scan, that ⌘S saves without touching the mouse,
  and that the readout matches the scale arithmetic.
- The iPhone, iPad and watch pages of the design get their own spec files
  and plans once Phase 2's targets exist.
