# FliBuddy Apple Watch: UI specification from the design

Source: the Claude Design project "FliBuddy mobile app design"
(`docs/design/source/FliBuddy Watch.dc.html`, the shared prototype model
`docs/design/source/flibuddy-core.js`, and the Spec page
`docs/design/source/FliBuddy Spec.dc.html`), imported on 2026-10-27. The
watch page is drawn at 46 mm (208 × 248 pt); sizes below are in points at
that size.

This file covers the watch app (`host/Apple/Watch`, views in
`host/Sources/FliBuddyUI/Watch`). Copy and the row states follow
`ios-ui-spec.md` (and through it the core's `vm`) unless stated here.

Precedence: as in the iPhone spec. Where this file and the shipped code
disagree, this file wins; where it is silent, keep the shipped behaviour.
The owner decisions outrank the design; `protocol/PROTOCOL.md`,
`docs/design/flipper-ui-spec.md` and the approved design document outrank
this file on behaviour. Where the watch page and the Spec page differ, the
watch page wins (it is the drawn, interactive mock-up).

## Assumptions and owner decisions, as they apply to the watch

The eight assumptions and their answers are in `ios-ui-spec.md`. For the
watch:

- **Assumption 4:** the watch creates Bambu tags in one tap and cannot fill
  the form. The page: **New** only for a tag with prefill (material); a
  tag without material reads `Create it on iPhone or Mac.`; a Flipper
  request to link reads `Link it on iPhone or Mac.`. There is no Link to
  existing on the watch.
- **Auto-save new off (owner):** a `Not in Bambuddy` Bambu row also gets
  the weight entry (Save creates the spool, then records the weight), with
  **New** under Save. The page shows New alone there; the owner rule adds
  the entry.
- **Assumption 7:** dark only.
- **Net/Gross (owner):** switching converts the number, crowned or not: to
  net `n − core`, to gross `n + core`, clamped at 0. The core's `setMode`
  keeps a touched number; the owner overrides that.
- **Order (owner):** newest on top; a rescan moves the row to the top and
  reopens it.
- **Colour facts (owner):** the watch page shows no colour name or tag
  facts; the colour name, colour code, UID, filament id, diameter and
  nozzle range go in a Details section at the bottom of the row detail,
  never in the list row.
- **Known spools (owner):** a save from the Flipper shows `Saved … · by
  Flipper`; Mark as new / Mark as empty / Delete from the Flipper show with
  the macOS phrases; an archived spool shows `archived`.

## App structure (watch page)

```swift
NavigationStack {
  List(feed) { WatchFeedRow($0) }
    .navigationTitle("FliBuddy")
    .toolbar { ToolbarItem(placement: .topBarLeading) { ConnectionGlyph() } }  // tap → Settings
    .navigationDestination(for:) { RowDetail($0) }
}
// RowDetail
Text(grams, format: .number)
  .font(.system(size: 50, weight: .semibold, design: .rounded))
  .monospacedDigit()
  .focusable()
  .digitalCrownRotation($grams, from: 0, through: 5000, by: 1,
                        sensitivity: .low, isHapticFeedbackEnabled: true)
// 5 g per detent above ~6 detents/s
// save: WKInterfaceDevice.play(.success)   error: .play(.failure)
// AOD: @Environment(\.isLuminanceReduced)
```

Screens: Feed → Row detail; Feed → (glyph) Settings → Scan for Flipper.
Every screen but the feed has the system back button (`chevron.left`) top
leading; the time is top trailing.

## Connection glyph (feed only, top leading)

A 30 pt circular button (white 16 % fill) holding one 16 pt symbol in its
tint; a 13 pt spinner instead while searching. Tap opens Settings. Its
accessibility label is the phrase. One state shows (core `statusVM.watch`):
the Flipper's problem if the Flipper is not connected, else Bambuddy's
problem, else `antenna.radiowaves.left.and.right` in green labelled
`Flipper connected`.

| State | Symbol | Tint | Label |
|---|---|---|---|
| No Flipper | spinner | gray `#8E8E93` | `No Flipper · searching` |
| Flipper nearby, not connected | `antenna.radiowaves.left.and.right` | orange `#FF9F0A` | `Flipper nearby` |
| Connected, no hello | `app.dashed` | orange | `Open FliBuddy on the Flipper` |
| Bambuddy not checked | `server.rack` | gray | `Bambuddy not checked` |
| Bambuddy unreachable | `wifi.exclamationmark` | red `#FF453A` | `Bambuddy unreachable` |
| API key lacks permission | `lock.trianglebadge.exclamationmark` | red | `Key lacks inventory permission` |
| Spoolman mode | `nosign` | red | `Bambuddy is in Spoolman mode` |
| Colour names unavailable | `paintpalette` | orange | `Colour names unavailable` |
| All healthy | `antenna.radiowaves.left.and.right` | green `#30D158` | `Flipper connected` |

The page draws no blocking view for Spoolman mode on the watch; the red
glyph says it and saves fail with the error.

## Feed list

Title `FliBuddy` (17 sb). Rows are platters (`#222224`, corner 20, minimum
height 52, padding 9 × 12, 5 apart), a grid of swatch 16 · text · glyph 22:

| Part | Spec |
|---|---|
| Swatch | 16 pt `Circle()`, 0.5 pt light stroke; dashed outline without colour |
| Title | 15 sb, one line, tail truncation: `PLA Basic`; blank tags shortened to `NTAG 04A2…` |
| Sub line | 13 `.secondary`: `590 g left` (known), `label 1000 g` (tag with prefill), `Unknown tag` (no material); `archived` for an archived spool (owner) |
| Status glyph | 19 pt, centred in its 22 pt column: `scalemass` blue `#0A84FF` (Enter weight), `checkmark.circle.fill` green (Saved, Timeout), `plus.circle.fill` green (Created), `questionmark.circle` gray (Not in Bambuddy, both kinds), `exclamationmark.triangle.fill` red (Error), `dot.radiowaves.left.and.right` blue (Flipper asks); a 14 pt spinner for Looking up, Saving, Creating and Updating. The marked and deleted states use their iPhone symbols. Accessibility label: the status phrase. |

Empty feed: only a centred line, 14 `.secondary`: `Hold a spool’s tag to
the Flipper running FliBuddy.`

**Auto-open (core `onFocus`):** when a row starts waiting for a weight
(scan, rescan, Created, a reopen) and the feed list is the screen showing,
its detail opens on its own. If a detail, Settings or the scan screen is
showing, nothing opens; the row only moves to the top.

## Row detail

A header line: swatch 12 · title 15 sb (one line). Then one of four bodies,
by state:

**Entry** (Enter weight, Saving, Created, Error; and Not in Bambuddy for a
Bambu tag, owner):

| Part | Spec |
|---|---|
| Weight | centred, 54 high: value 50 sb rounded tabular digits, `g` 20 sb `.secondary` (the Spec table's 24 is superseded by the page) |
| Line | 13, centred, one line: `Saves 590 g left`; `Turn the crown` when empty; red `Below the core weight (325 g)`; red `Error: <message>` in the error state |
| Net / Gross | two pills side by side, 30 high, 4 apart, 13 sb; the selected one white with black text, the other white 16 % with white text |
| Save | full width, 40 high capsule, `#0A84FF`, white 16 sb: `Save` / `Saving…`; 45 % when it cannot save |
| New | Not in Bambuddy, Bambu tag only: under Save, same size, white 16 % fill (Save is the prominent action here) |
| Crown indicator | the page's 4 × 40 green-thumb bar on the right edge stands in for the system's crown indicator; use the system one |

**Saved** (Saved, Timeout; also Marked as new / Marked as empty): the state
symbol 34 pt in its tint, the remaining `590 g` at 34 sb rounded tabular,
the status phrase 13 `.secondary` centred (`Saved 590 g left · by host`),
and at the bottom **Weigh again** (40 high, white 16 % fill, 16 sb), which
reopens the entry and focuses it.

**Unknown** (Not in Bambuddy without material, Flipper asks to create /
link, Deleted): the sub line (13 `.secondary`), the status symbol 17 pt +
phrase 15, a hint 13 `.secondary`: `Create it on iPhone or Mac.` for a tag
without material, `Link it on iPhone or Mac.` for a link request, none
otherwise; at the bottom **New** (40 high, `#0A84FF`) when the tag has
prefill. New creates the spool from the tag in one tap (`Creating in
Bambuddy…`, then the Created entry).

**Busy** (Looking up, Creating): a 26 pt spinner and the phrase 15
`.secondary`, centred.

**Details** (owner; not on the page): below the body, reached by scrolling
(the crown scrolls when no weight is focused): colour name, colour code,
UID, filament id, diameter, nozzle range, spool id, each when known, as
`LabeledContent` rows.

## Digital Crown and haptics

- The crown moves the value 1 g per detent with the detent haptic; turned
  faster than about 6 detents per second it moves 5 g per detent.
  `sensitivity: .low`. Range: the shared 0…9999 (the page's snippet says
  `through: 5000`; no spool reaches either limit).
- A crown turn makes the value touched; Net/Gross still converts it
  (owner).
- Save succeeds: `WKInterfaceDevice.current().play(.success)`, the status
  reads `Saved 590 g left · by host`, and one second later the detail pops
  back to the feed (when it was opened from the feed). The page's green
  ring and "Haptic · success" toast only simulate the haptic; do not build
  them.
- Save fails: `.play(.failure)`, the red error line, the value stays for a
  retry.
- After a save, focus moves to the newest waiting row; with the feed
  showing again, that row's detail auto-opens.

## Always-On (`isLuminanceReduced`)

The page draws the feed list: no swatches, no status glyphs, no platters,
no connection glyph; title at 55 % white, sub line at 35 %, time at 50 %;
rows do not respond to taps. Other screens are not drawn in AOD: keep their
layout and let the system dim them.

## Settings (read-only, from the iPhone)

Title `Settings`. Platters as in the feed (`#222224`, corner 20, padding
8 × 12), each a 15 pt label over a 13 pt `.secondary` value:

- Header `From iPhone` (12 `.secondary`): `Server` (`bambuddy.local:8000`,
  host and port of the URL), `Core weight` (`325 g`), `Weight as`
  (`Gross` / `Net`). Footer (12 `.secondary`): `Received 2 min ago. Change
  these on iPhone.` (the relative time of the last received settings).
- Header `Flipper`: a platter with the Flipper's name (`Workshop`) over the
  glyph's symbol and phrase in its tint (`Connected`, `nearby`, …), then a
  **Scan for Flipper** button (44 high capsule, `#222224`, `#0A84FF` 15 sb).

**Scan for Flipper** (its own screen): title `Scan for Flipper`, a 12 pt
spinner with `Searching…` (13 `.secondary`), then one platter per Flipper
found: `antenna.radiowaves.left.and.right` 18 pt blue, the name 15, the
signal 13 `.secondary` (`Nearby · strong`, `Nearby`). Tapping one connects
to it and returns to Settings.

Settings sync: the iPhone applies its settings on change and sends each
applied change through WatchConnectivity (`updateApplicationContext`,
latest wins); the watch applies what arrives at once and keeps its own
Flipper choice. The iPad sends nothing.

## Tokens (watch page)

Weight 50 sb rounded tabular · unit `g` 20 sb · screen title 17 sb · row
and detail title 15 sb · sub lines, readout line, hints 13 · section
headers and footers 12 · buttons 40 high (Scan 44), 16 sb (Scan 15 sb),
capsules · pills 30 high 13 sb · platter `#222224` corner 20 · background
black. Colours: blue `#0A84FF`, red `#FF453A`, green `#30D158`, orange
`#FF9F0A`, gray `#8E8E93`, secondary `rgba(235,235,245,0.6)`, fills white
16 %.

## Differences from what ships

Checked against the code on 2026-10-27.

1. **Navigation.** `host/Apple/Watch/App.swift` is a vertical-page
   `TabView` (feed, settings); the page wants one `NavigationStack` with
   Settings behind the leading glyph.
2. **Status.** `WatchStatus` (`host/Sources/FliBuddyUI/Watch/WatchFeedView.swift`)
   is a list section with two coloured dots and phrases, not the single
   glyph button.
3. **List row.** `WatchFeedRow` uses a 24 pt swatch, `.headline`, and the
   status as text; the page wants a 16 pt swatch, 15 sb title, the short
   sub line (`590 g left`, `Unknown tag`) and a 19 pt trailing glyph. The
   empty state is a `ContentUnavailableView` with a different text.
4. **Auto-open and pop.** Rows open only on a tap; nothing opens on focus,
   and the detail does not pop a second after a save.
5. **Entry.** `WatchWeightEntry`
   (`host/Sources/FliBuddyUI/Watch/WatchRowDetail.swift`) shows `.title2`
   (≈ 22 pt) `"\(grams) g"`, a `Toggle("Gross")`, a plain Save and no
   readout line; the page wants 50 pt + 20 pt unit, the line (`Saves … g
   left` / `Turn the crown`), the two pills and the 40 pt blue Save.
6. **Crown.** `CrownWeight` (`host/Sources/FliBuddyCore/ViewModels/CrownWeight.swift`)
   switches to 5 g at 20 g/s, and the view uses `sensitivity: .medium`;
   the page says about 6 detents per second and `.low`.
7. **Net / Gross.** Switching does not convert a crowned value
   (`FeedViewModel.setMode`,
   `host/Sources/FliBuddyCore/ViewModels/FeedViewModel.swift:157`).
8. **Haptics.** Only the crown's detent haptic; no `.success` / `.failure`.
9. **Saved and unknown screens.** A saved row shows `Re-weigh` under the
   status, not the 34 pt result and `Weigh again`. `WatchUnknownActions`
   opens a full `WatchNewSpool` form for every tag without a spool; the
   page has one-tap New for prefill tags only and the two hints. On a `Not
   in Bambuddy` Bambu row the detail shows the entry but no New.
10. **Details.** Colour code, UID, filament id, diameter and nozzle range
    are shown nowhere.
11. **AOD.** No `isLuminanceReduced` handling.
12. **Settings.** `WatchSettingsView` lists URL, `API key Set/Missing`,
    Core, Weight and the Bambuddy status, and scans inline with RSSI in
    dBm and Stop scanning; the page has Server / Core weight / Weight as,
    the `Received … Change these on iPhone.` footer, the Flipper platter,
    and a separate scan screen with `Searching…` and signal words. The
    empty text says "save its settings".
13. **Sync cadence.** `WatchSettingsSender` sends after an explicit Save on
    the iPhone (`host/Sources/FliBuddyCore/Session/WatchSettingsSync.swift`);
    with apply-on-change it must send after each applied change.

## Open questions for the owner

None: the watch page and the owner decisions settle the watch.
