# FliBuddy iPhone: UI specification from the design

Source: the Claude Design project "FliBuddy mobile app design"
(`docs/design/source/FliBuddy Spec.dc.html` and
`docs/design/source/FliBuddy iPhone.dc.html`), imported on 2026-10-27. The
page imports the shared prototype model `flibuddy-core.js` (session, row
view-model, connection texts: `docs/design/source/flibuddy-core.js`, saved
the same day). The row copy comes from the core's `vm`, the banner from its
`statusVM` (`FLIP` / `BAMBU` tables), the Link picker rows from `invVM`, the
keypad and focus behaviour from its `Session`.

This file is the implementation-ready distillation for the iPhone app
(`host/Apple/iOS`, views in `host/Sources/FliBuddyUI`). The iPad uses it for
its portrait (compact) layout, see `ipados-ui-spec.md`; the watch has
`watchos-ui-spec.md`; the Mac has `macos-ui-spec.md`.

Precedence: where this file and the shipped code disagree, this file wins;
where it is silent, keep the shipped behaviour. The owner decisions below
outrank the design pages. The approved design document
(`docs/superpowers/specs/…design.md`), `protocol/PROTOCOL.md` (wire v2) and
`docs/design/flipper-ui-spec.md` outrank this file on behaviour; this file
only says how that behaviour looks and feels on the iPhone. Deviations made
while building it go into an "Implemented differently" section at the end,
as in the macOS spec.

## Assumptions the designer asked the owner to confirm

The Spec page's "Assumptions to confirm" lists eight; the macOS spec
recorded the owner's answers (2026-10-26) and the decisions below update
them:

1. *The suggestion is gross; switching Net/Gross converts an untouched
   suggestion and keeps a typed number.* The suggestion is gross by default
   (Settings decide). **Overridden:** switching converts the number whether
   typed or not (see "Owner decisions").
2. *After New the row stays open for a first weight, "Created in Bambuddy"
   pre-filled to label + core.* Adopted, and extended by Auto-save new.
3. *Saved rows reopen on tap for a re-weigh; last save wins; the status
   says who saved.* Adopted.
4. *The watch creates Bambu tags in one tap but cannot fill the form; other
   tags say "Create it on iPhone or Mac".* Adopted, see the watch spec.
5. *iPhone and iPad settings apply on change; macOS keeps the explicit
   Save.* Adopted: the iPhone Settings have no Save / Revert row.
6. *Link to existing warns when the chosen spool carries a different tag and
   offers to move the link.* Adopted.
7. *Watch is dark only; every other surface light and dark.* Adopted: the
   iPhone follows the system appearance.
8. *Open icons stand in for SF Symbols; hover shows the real name.* The SF
   Symbol names below are the ones to use.

## Owner decisions (2026-10-26, 2026-10-27)

They apply to every platform and override the design where they conflict.

- **Rows strictly in scan order, newest on top.** A rescan of a tag already
  in the feed moves its row to the top and reopens it for a weight; no
  duplicate row. Several scans per session, every row stays editable.
- **Auto-save new lives on the Flipper** (protocol v2, `scan.autosave`,
  default Off). The host has no switch of its own.
  - On: an unknown Bambu tag (one with material) is created at once with the
    tag's defaults; the row reads `Created in Bambuddy`, the weight entry is
    pre-filled to label + core and focused; Save records the weight.
  - Off: the row reads `Not in Bambuddy` with the weight entry pre-filled to
    label + core and **New** and **Link to existing…** under it. Save
    creates the spool from the tag, then records the weight. Nothing reaches
    Bambuddy until New, Link or Save.
- **Known spools:** a weight that comes in (from the Flipper) is saved at
  once. The Flipper's actions Mark as new (`full`), Mark as empty (`empty`,
  archives) and Delete (`delete`) show on the row. An archived spool
  scanned again shows as archived; a weight saved on it restores it.
- **Colour facts on new tags** (`tag_info`): Bambuddy's colour name (else
  Bambu's English name from `tools/data/bambu_color_codes.json`), Bambu's
  colour code (e.g. `11803`, stored as `material_number`), filament id,
  diameter, nozzle range. The row shows the colour name and the colour
  code; UID, filament id, diameter and nozzle range live in a details view,
  not in the row.
- **Net/Gross converts the number**, typed or not: gross → net subtracts
  the core, net → gross adds it.

## Stance (from the Spec page)

- **One number per row.** The newest row that needs a weight takes focus
  with the suggestion pre-filled and selected; the first key replaces it. A
  correct suggestion costs one tap (Save).
- **Readable at a metre.** The weight value is the only custom-sized type:
  34 pt on iPhone, monospaced digits. Everything else is a system text style
  and follows Dynamic Type; the weight uses `@ScaledMetric(relativeTo:
  .largeTitle)` and caps at AX3 so it stays on one line.
- **Status is a word first.** Every state is a short sentence-case phrase
  plus an SF Symbol; colour never carries meaning alone. The swatch always
  sits next to the title and colour name.
- **Stock parts only.** `TabView`, `NavigationStack`, `List`, `Form`, sheets,
  `ContentUnavailableView`, `confirmationDialog`. Liquid Glass only where
  the system puts it, plus the connection banner.
- **One-handed at the bench.** The number pad rises on its own with the
  suggestion selected and Save stays above it.

## App structure

```swift
TabView {
  Tab("Feed", systemImage: "list.bullet") {
    NavigationStack {
      FeedList()                       // List { ForEach(feed) { Section { FeedRow($0) } } }
        .listSectionSpacing(.compact)
        .navigationTitle("Feed")       // large title
        .toolbar { Button("Clear", systemImage: "trash") }   // leading, icon only
        .safeAreaInset(edge: .top) { ConnectionBanner() }
        .overlay { ContentUnavailableView }                  // empty or blocking
        .sheet(item: $newRow)  { NewSpoolForm() }
        .sheet(item: $linkRow) { LinkPicker().searchable(…) }
        .sheet(item: $detailsRow) { TagDetails() }           // owner decision, not in the design
        .confirmationDialog("Clear the feed?")
    }
  }
  Tab("Settings", systemImage: "gearshape") {
    NavigationStack { SettingsForm() }                       // applies on change
      .fullScreenCover { QRScanner() }
  }
}
// weight field
TextField("Weight", value: $grams, format: .number)
  .keyboardType(.numberPad)
  .focused($focus, equals: row.id)
  // select-all on focus via TextSelection (iOS 18+)
```

The tab bar hides while the number pad is up and comes back when it lowers.
The Clear button sits at the leading end of the navigation bar, icon only
(`trash`), accessibility label "Clear feed"; disabled while the feed is
empty.

## Connection banner (top safe-area inset, under the large title)

One compact capsule replaces the macOS status bar. When both sides are
healthy it reads `Flipper connected · Bambuddy ready` with
`checkmark.circle.fill` in green. Otherwise it shows each side that has a
problem, as that state's short phrase, symbol, tint and action: one line
when one side is down, two lines in the same capsule (Flipper first, then
Bambuddy, each with its own chip) when both are (owner decision
2026-10-27; the core's `statusVM` shows only the Flipper's).

| Part | Spec |
|---|---|
| Shape | `Capsule()`, height 40, `.glassEffect()` on iOS 26+ (`.regularMaterial` below), 0.5 pt hairline, horizontal padding 14 leading / 6 trailing, 16 pt outer margin |
| Symbol | 16 pt, in the state's tint; a 12 pt spinner in its place while searching |
| Text | `.footnote.weight(.medium)` (13), `.primary`, one line, tail truncation |
| Action | capsule chip height 28, padding 12, `.tint` fill, white `.footnote.weight(.semibold)` label |

Short phrases (core `FLIP` / `BAMBU`, field `short`):

| Side | State | Phrase | Symbol | Tint | Action |
|---|---|---|---|---|---|
| Flipper | none | `No Flipper · searching` | spinner (`antenna.radiowaves.left.and.right.slash` for VoiceOver) | gray | |
| Flipper | adv | `Flipper nearby` | `antenna.radiowaves.left.and.right` | orange | Connect |
| Flipper | ble | `Flipper connected` | `antenna.radiowaves.left.and.right` | green | |
| Flipper | nohello | `Open FliBuddy on the Flipper` | `app.dashed` | orange | |
| Bambuddy | unchecked | `Bambuddy not checked` | `server.rack` | gray | Check |
| Bambuddy | ready | `Bambuddy ready` | `server.rack` | green | |
| Bambuddy | unreachable | `Bambuddy unreachable` | `wifi.exclamationmark` | red | Retry |
| Bambuddy | noperm | `Key lacks inventory permission` | `lock.trianglebadge.exclamationmark` | red | Settings |
| Bambuddy | spoolman | `Bambuddy is in Spoolman mode` | `nosign` | red | Retry |
| Bambuddy | nocolors | `Colour names unavailable` | `paintpalette` | orange | |

USB is macOS only; the iPhone never shows `Flipper · USB`.

The `ble` and `ready` rows only appear inside the combined healthy text.
Spoolman mode is blocking anyway (the feed is replaced). The states the shipped `StatusItem` adds beyond the table keep their macOS
phrases and tints (`Bambuddy not set up` orange + Settings, `Bambuddy
rejected the API key` red + Settings, `Checking Bambuddy…` with a spinner,
a link problem such as `Bluetooth is off` orange with the slash symbol, the
protocol version mismatch). Tapping the banner outside the chip does
nothing; the detail the phrase leaves out is its accessibility hint.
Settings switches to the Settings tab.

## Feed row (stacked card, one `Section` per row)

Card: `secondarySystemGroupedBackground`, inset-grouped corner (≈ 24),
padding 16, 12 between cards (`.listSectionSpacing(.compact)`).

Header, left to right: swatch · (title with the UID trailing on the same
line → colour line → status) . The owner decision moves the UID out of the
row: the title line holds the title alone (see "Tag details").

| Part | Spec |
|---|---|
| Swatch | 28 pt `Circle()` from the tag or spool RGBA, 0.5 pt `.separator` stroke; no colour: 1.5 pt dashed `.tertiary` outline. Hidden from VoiceOver. 12 pt to the text. |
| Title | material + subtype, `.headline` (17 sb). Blank tags: `NTAG 7-byte UID 04A2…`. |
| Colour line | `.subheadline` `.secondary` (15), 2 pt under the title: colour name, Bambu colour code, amount, joined by ` · `: `Bambu Green · 10501 · 590 g left of 1000`, `Bambu Green · 10501 · label 1000 g` (no spool yet), `Jade White · archived`. Parts that are unknown are left out; never the hex. While Bambuddy's colour names are unavailable the name is left out. The code comes from the spool's `material_number` or the tag's `tag_info.code`. |
| Status | symbol 17 pt in its tint + phrase, `.subheadline` (15), 6 pt under the colour line; `.secondary`, `.red` only for errors. |
| Timeout note | `exclamationmark.triangle.fill` 15 pt orange + `.footnote` (13) `.secondary`: `Flipper timed out after 10 s and showed an error; the save went through.` |

Entry block (12 pt under the header, 10 pt between its parts), present in
the entry states of the table below:

| Part | Spec |
|---|---|
| Weight field | full width, height 64, `tertiarySystemFill`, `.rect(cornerRadius: 14)`, padding 16; focus ring 2 pt `.tint`. Value `.system(.largeTitle, design: .rounded).bold().monospacedDigit()` scaled to 34 pt; the selected suggestion is highlighted (system selection); an empty field shows `0` in `.tertiary`. Unit `g` `.title2.weight(.semibold)` `.secondary` (22) after the value. The mode word (`gross` / `net`) right-aligned inside the field, `.footnote` `.secondary` (13). Accessibility label `Gross weight, grams` / `Net weight, grams`. |
| Net / Gross | segmented, full width, height 32, capsule track; labels 14 sb. |
| Readout | `.footnote.monospacedDigit()` `.secondary` (13): `Saves 590 g left · 915 − 325 g core` (gross), `Saves 590 g left` (net), `Type the scale reading` (empty), `Below the core weight (325 g)` in `.red`. |
| Save | full width, height 50, `.borderedProminent`, capsule, `.headline` (17 sb): `Save` / `Saving…`; disabled (45 % look) when empty, below the core or saving. |
| Actions | when the state offers New / Link: a row of two equal capsules, height 44, 10 apart, 15 sb. The prominent one is `.tint` with white text, the other `tertiarySystemFill` with `.tint` text. |

A row without an entry block or actions has a minimum height of 76.

VoiceOver reads the header as one element: "PLA Basic, Bambu Green, 590
grams left of 1000, Enter weight" (the colour code is not read). Rows that
can reopen get a "Re-weigh" action; every row gets a "Tag details" action.

### Row states and copy

Same model and texts as the macOS table; only the entry column differs.

| State | Status text | Symbol | Tint | Entry block / actions |
|---|---|---|---|---|
| Looking up | `Looking up` | spinner | secondary | none |
| Enter weight | `Enter weight` | `scalemass` | blue | entry, focused when newest |
| Saving | `Saving…` | spinner | secondary | entry, disabled |
| Saved | `Saved 590 g left · by host` / `· by Flipper` | `checkmark.circle.fill` | green | none; tap reopens |
| Timeout | `Saved 590 g left · by host` + timeout note | `checkmark.circle.fill` | green | none; tap reopens |
| Creating (after New) | `Creating in Bambuddy…` | spinner | secondary | none |
| Created (Auto-save new on, or after New) | `Created in Bambuddy` | `plus.circle.fill` | green | entry pre-filled label + core, focused; `Link to existing…` as a plain `.footnote` button right of the readout (moves the tag, deletes the created spool) |
| Error | `Error: Bambuddy unreachable` (any message) | `exclamationmark.triangle.fill` | red text | entry, value kept for retry |
| Not in Bambuddy, Bambu tag (Auto-save new off) | `Not in Bambuddy` | `questionmark.circle` | secondary | entry pre-filled label + core, focused; Save creates the spool, then records the weight; actions **New** (prominent) · **Link to existing…** under Save |
| Not in Bambuddy, no material | `Not in Bambuddy; tag has no material` | `questionmark.circle` | secondary | actions **New…** (prominent, opens the form) · **Link to existing…** |
| Flipper asks to create | `Flipper asks to create it here` | `dot.radiowaves.left.and.right` | blue | as Not in Bambuddy, **New** / **New…** prominent |
| Flipper asks to link | `Flipper asks to link it here` | `dot.radiowaves.left.and.right` | blue | as Not in Bambuddy, **Link to existing…** first and prominent |
| Updating (a Flipper action under way) | `Updating…` | spinner | secondary | entry disabled, if it was open |
| Marked as new | `Marked as new · 1000 g left · by Flipper` | `arrow.counterclockwise.circle.fill` | green | none; tap reopens |
| Marked as empty | `Marked as empty · archived · by Flipper`; colour line ends `· archived` | `archivebox` | secondary | none; tap reopens (a Save restores the spool) |
| Deleted | `Deleted from Bambuddy · by Flipper` | `trash` | secondary | actions **New** · **Link to existing…**, no entry |
| Archived spool scanned | `Enter weight`; colour line ends `· archived` | `scalemass` | blue | entry; Save restores the spool, then records the weight |

A weight saved from the Flipper on a row the iPhone shows as waiting turns
it into `Saved … · by Flipper` and drops the iPhone's draft.

### Weight rules

- Suggestion = `base + (mode == gross ? core : 0)`; `base` is the spool's
  remaining grams, for a tag without a spool its label weight. `core` is the
  spool's core weight, for a tag without a spool the Settings value.
- **Switching Net/Gross converts the field's number, typed or not**: to net
  `n − core`, to gross `n + core`. An untouched suggestion stays untouched
  (it is still selected and the first key replaces it); a typed number
  stays typed. The readout follows. (The core's `setMode` keeps a touched
  number as is; the owner overrides that.) A conversion below 0 clamps to 0 (see
  "Open questions").
- Digits only, 0…9999. Save sends what the shipped `FeedViewModel.save`
  sends today (gross to Bambuddy).
- After a successful save the row shows `Saved n g left · by host`, keeps
  the value as the new base, and focus moves to the newest row that still
  waits for a weight. With none, the pad lowers.
- Focus never steals from a field the user is typing in (`touched`): the
  new row only gets a 2 pt `.tint` outline and waits.

## Number pad and focus (from the iPhone flow)

"Correct suggestion: 1 tap. Otherwise: digits + 1 tap."

1. A row turns Enter weight (or Created, or Not in Bambuddy for a Bambu
   tag). The list scrolls it to the top and its field takes focus; the
   system number pad (`.numberPad`) rises with the suggestion selected.
2. The first key replaces the selection (a lone `0` is replaced too); ⌫
   (`delete.left`) deletes one digit; at most four digits (0…9999).
3. Net/Gross sits under the field and converts the number.
4. Tap Save, which always stays above the pad (the list scrolls the
   focused row's entry block, Save included, clear of the keyboard). Saving…
   → Saved, then a light success haptic (`.sensoryFeedback(.success, …)`);
   an error gives `.error`.
5. If another row waits, focus moves there and its suggestion is selected;
   otherwise the pad lowers. Tapping any field reopens it with its value
   selected; tapping a saved card reopens it. Tapping the list background
   lowers the pad.

The tab bar is hidden while the pad is up. While a sheet is open no row
takes focus.

## Tag details (owner decision; not in the design)

The design shows the UID in the row; the owner moved the technical facts
out of it. Long-press a card (`.contextMenu`) → **Tag details**
(`info.circle`), also a VoiceOver action, opens a sheet (medium detent) with
a grouped `Form` of `LabeledContent` rows, each present only when known:
UID (monospaced, as read), Bambuddy tag UID (with the `00000100` suffix),
tray UUID, colour name, colour code, filament id, diameter (`1.75 mm`),
nozzle (`190–230 °C`), label weight, core weight, spool (`#42`, archived or
not). Title: the row title. UID values are selectable for copying. Layout
beyond this is the builder's call.

## Empty and blocking states (`ContentUnavailableView`)

- Empty feed: `wave.3.right` (58 pt, `.secondary`), `No scans yet`,
  `Hold a spool's tag to the Flipper running FliBuddy.`
- Spoolman mode (blocking, replaces the list even with rows): `nosign` in
  red, `Bambuddy is in Spoolman mode`, `FliBuddy works with Bambuddy's own
  inventory. Switch it back from Spoolman in Bambuddy's settings, then
  retry.`, button Retry.

## Clear

Toolbar trash → `confirmationDialog` titled `Clear the feed?`, message
`This clears the session log only. Nothing changes in Bambuddy.`, buttons
**Clear feed** (destructive) · Cancel.

## Sheets

**New spool** (tags without material only; Bambu tags create from the
tag): navigation bar with Cancel (`xmark`, leading) and Create (`checkmark`,
trailing, `.tint` when a material is chosen, disabled otherwise), title
`New spool`; under it `NTAG 7-byte` and the UID in monospaced
`.secondary`. Grouped `Form`:

- Section "Required": Material, menu `Choose` / PLA, PETG, ABS, ASA, TPU,
  PA, PC, PVA.
- Section "Optional": Subtype (placeholder `Basic, Matte, HF…`), Colour
  (`ColorPicker`, the swatch RGBA), Colour name (placeholder `Lilac`),
  Brand (placeholder `Elegoo`), Label weight (digits, default 1000, `g`).
- Footer: `FliBuddy creates the spool in Bambuddy, then asks for its weight.`

**Link to existing**: navigation bar with Cancel (`xmark`) and Link
(`checkmark`, disabled without a pick), title `Link to existing`, the UID
under it. A `.searchable` field (`magnifyingglass`, placeholder `Material,
colour, brand or note`). Rows (core `invVM`): swatch,
title, `colour · brand · n g left`, the note on its own line, a `Tag <tag>`
badge when the spool carries a tag other than this one, a `checkmark` on
the pick. The filter matches material, subtype, colour, brand and note. Empty: `No spools match “<q>”.`;
no spools: `No spools in Bambuddy.`. When the pick carries a different tag,
Link asks first with an alert: title `<title> <colour> is linked to tag
<tag>`, message `Move the link to <uid>? The old tag will no longer identify
this spool.`, buttons **Move link** (`arrow.left.arrow.right`) · Cancel.

**Scan QR code** (`fullScreenCover`): camera preview edge to edge, close
(`xmark`) top leading, a corner-bracket frame in the middle, a capsule hint
under it: `Point at the QR code Bambuddy shows when you create an API key.`
A read closes the cover, fills URL and key, and starts Test connection.

## Settings (grouped `Form`, applies on change)

Large title `Settings`. Every change applies when it is made: pickers and
the segmented control at once, text fields when they are committed
(Return or leaving the field). There is no Save / Revert row. Each applied
change also goes to the watch (see "Settings sync to the watch").

```swift
Form {
  Section("Bambuddy") {
    Button("Scan QR code", systemImage: "qrcode.viewfinder")   // first row; .tertiary without a camera
    TextField("URL")                                           // http://bambuddy.local:8000
    SecureField("API key")
    Button("Test connection") + trailing result
  } footer: QR footer
  Section("New items") { Picker("Empty spool"); LabeledContent("Core weight") { TextField + "g" } }
    footer: "Weight of everything that is not filament; 325 g = Bambu reusable spool 293 g + refill core 32 g."
  Section("Weighing") { Picker("Type weight as", Net | Gross).pickerStyle(.segmented) }
    footer: "Gross is the whole spool on the scale. Each row can still switch."
  Section("Flipper") {
    LabeledContent(name ?? "No Flipper paired") { symbol + state }   // "Workshop" · Bluetooth / Searching…
    Button("Scan for Flipper")
    Button("Forget this Flipper", role: .destructive)
  } footer: "Bluetooth only on iPhone. The Flipper must be running FliBuddy."
}
```

QR footer: `Scan the QR code Bambuddy shows when you create an API key.`;
after a read `Filled from the QR code.` in green; without a camera `This
device has no camera. Type the URL and API key instead.` and the Scan row is
dimmed. Test results: `Not tested` · `Testing…` (spinner) · `Ready ·
inventory access OK` (`checkmark.circle.fill`, green) · `Unreachable:
<reason>` (`xmark.circle.fill`, red), the shared phrases of the macOS spec
(the mock-up shortens them to `Ready` / `Unreachable`). Editing the URL or
the key resets the result to `Not tested`. The Flipper state reads
`Bluetooth` when connected, `Searching…` with a spinner while scanning.
The discovered Flippers list under Scan (name, RSSI, a checkmark on the
chosen one) stays as shipped; the design does not show it. Rows are at
least 52 pt high. The Empty spool picker lists Bambuddy's spool catalog, as shipped; the
mock-up's four names (`Bambu reusable + core`, `Bambu cardboard`, `Generic
1 kg plastic`, `Custom`) are placeholders.

## Settings sync to the watch

The iPhone sends the settings (URL, API key, core weight, empty spool, Net /
Gross) to the watch after every applied change, through the shipped
`WatchSettingsSender` (application context, only the latest counts). With
apply-on-change a text field sends once when it commits, not per keystroke.

## Tokens

Spacing (pt): 4 symbol ↔ text in a status line · 8 between controls in a
group · 12 swatch ↔ text, header ↔ entry, between rows · 16 row padding and
list inset · 20 sheet and Form padding · 24 between Form sections · 32
empty-state stack. Inside a card: title → colour line 2, colour line →
status 6, inside the entry block 10.

Radii: `Circle()` swatch; row card insetGrouped Section (≈ 24); weight field
`.rect(cornerRadius: 14)`; buttons `.buttonBorderShape(.capsule)`; banner
`Capsule()`; sheets system.

Type roles (iOS sizes at the default content size): weight 34 bold rounded
monospaced digits · row title `.headline` 17 sb · colour line
`.subheadline` 15 · status `.subheadline` 15 · UID (details only)
`.caption.monospaced()` 12 · readout `.footnote.monospacedDigit()` 13 ·
banner `.footnote.weight(.medium)` 13 · Save `.headline` 17 sb · unit `g`
`.title2.weight(.semibold)` 22.

Colours: `.primary` titles and the weight · `.secondary` colour line,
status, readout · `.tertiary` placeholders, empty value · `.tint`
(systemBlue) Save, focus, Flipper requests · `.red` errors, Forget, Clear ·
`.green` saved, created, ready · `.orange` warnings (timeout, advertising,
no hello) · `.gray` searching, not checked · `systemGroupedBackground` the
feed and Form · `secondarySystemGroupedBackground` the row card ·
`tertiarySystemFill` the weight field and segmented track · `.separator`
the swatch stroke.

SF Symbols: `list.bullet`, `gearshape`, `trash`, `scalemass`,
`checkmark.circle.fill`, `plus.circle.fill`, `questionmark.circle`,
`exclamationmark.triangle.fill`, `xmark.circle.fill`,
`dot.radiowaves.left.and.right`, `antenna.radiowaves.left.and.right`,
`antenna.radiowaves.left.and.right.slash`, `app.dashed`, `server.rack`,
`wifi.exclamationmark`, `lock.trianglebadge.exclamationmark`, `nosign`,
`paintpalette`, `wave.3.right`, `qrcode.viewfinder`, `link`,
`arrow.left.arrow.right`, `magnifyingglass`, `xmark`, `checkmark`,
`delete.left`, `arrow.counterclockwise.circle.fill`, `archivebox`,
`info.circle`.

## Differences from what ships

None remain. The fourteen differences found on 2026-10-27 were closed by
the plan `docs/plans/20261027-apple-ui-from-design.md`; where the app
departs from this file, the next section says how and why. What changed:

1. Connection banner: the top glass banner (`ConnectionBanner`,
   `ConnectionBannerView`) replaced the bottom macOS status bar on iOS,
   with the iPhone phrases, one line per side in trouble.
2. Row card: the stacked card, one `Section` per row.
3. Number pad and focus: number pad, select-all, scroll to the focused
   row, tab bar hidden while typing, pad lowered when no row waits.
4. Haptics: success after a host save, error on a failed host action.
5. Net/Gross converts the number on screen, typed or not (Mac too).
6. Colour line `<colour name> · <code>`; the UID left the row.
7. Tag details sheet from the row's context menu and VoiceOver action.
8. Settings apply on change, with the labels, rows and footers above.
9. QR scanner as a full-screen cover; a dimmed Scan row without a camera;
   a read applies and starts Test connection.
10. New spool sheet: colour picker, Required / Optional, toolbar buttons.
11. Link picker: `.searchable`, the move-link alert, toolbar buttons.
12. Clear: `trash` button, `Clear feed` in the dialog.
13. Watch sync after each applied change, debounced.
14. Not-in-Bambuddy rows: New / Link as 44 pt capsules under Save.

## Implemented differently (2026-10-27)

Where the app departs from this file or fills in what it leaves open, and
why. Items marked "by eye" still wait for the owner's check on screen.

Connection banner
- The banner is `ConnectionBanner` (`FliBuddyCore`), built from the same
  two `StatusItem`s as the macOS status bar; each item carries its iPhone
  phrase in `short` where it differs. A side counts as healthy when its
  tint is green (Flipper connected, Bambuddy ready), so the colour-names
  warning is a problem line of its own.
- The shape is a rounded rectangle with a 20 pt continuous corner rather
  than `Capsule()`: at one line (40 pt) it is the capsule, and at two
  lines the corners stay the same instead of rounding into the text. By
  eye.
- The chip fills with the app tint, not the state's tint. The healthy
  line's accessibility hint is the firmware version. By eye.
- A portrait iPad shows the same banner; beside the iPad sidebar the
  banner gives way to the sidebar's status rows (`ipados-ui-spec.md`).

Feed row, number pad and focus
- The card is the row of its own inset-grouped `Section` with 16 pt row
  insets; the waiting-row hint is a 2 pt `.tint` stroke on the card's row
  background (24 pt continuous corner), not on the field. By eye.
- Save and the New / Link capsules are stock `.borderedProminent` /
  `.bordered` buttons with `.buttonBorderShape(.capsule)` at
  `.controlSize(.large)`; the label's minimum height (36 / 30) gives about
  50 / 44 pt rather than an exact frame. The non-prominent capsule is the
  bordered style's tinted fill rather than `tertiarySystemFill`. By eye.
- The capsules show no spinner of their own: the row's status line shows
  `Creating in Bambuddy…` with its spinner while New or Link runs.
- Select-all on focus sets the field's `TextSelection` to the whole value
  one turn after the field takes the keyboard, so the caret the tap placed
  does not win; a Net/Gross switch reselects a converted suggestion. A tap
  anywhere in the 64 pt box focuses the field. By eye.
- Leading zeros drop as the user types (`FeedViewModel.sanitizeWeight`),
  which is how a lone `0` is replaced by the next key; the Mac shares it.
- "Tapping the list background lowers the pad" is a tap on a card's header
  (swatch, title, colour line, status) plus
  `.scrollDismissesKeyboard(.immediately)` on a drag: a list-wide tap
  gesture races the field's own tap and the buttons. A tap between cards
  does nothing. By eye.
- No row's field holds the keyboard while a sheet is open: the sheets
  count themselves in and out (`FeedViewModel.sheetOpened()` /
  `sheetClosed()`), and the focused row's field takes the pad back when the
  last one closes.
- The success haptic plays after a save from the host; the error haptic
  after any failed host action (save, New, Link), as `FeedViewModel.haptic`
  events. A save from the Flipper plays nothing on the iPhone.
- The timeout note's symbol and text are a `Label` 4 pt under the status.
- Tag details opens from the card's context menu and the VoiceOver action
  shared with the Mac, as a sheet with medium and large detents.

Settings, QR, sheets and Clear
- Apply on change lives in `SettingsViewModel` (`appliesOnChange`, which
  only the iPhone and iPad set). Each change applies on top of the settings
  applied last, one after another, so a picker change leaves a field that
  is still being typed out of it. A text field commits on Return, when
  another field takes the focus, and when the Settings tab goes away.
- A core weight out of range is not applied (its red line stays under the
  field) while a URL or key committed with it is. A failed apply shows a
  red line at the bottom of the form; the edit stays and the next commit
  tries again.
- URL and API key are labelled rows with the field trailing. By eye.
- The core weight field is text, not a number format: digits go into the
  setting as typed (`SettingsViewModel.coreWeightText`, at most four, an
  empty field reads 0 and is not applied), so the commit on focus loss
  never sees a stale number; the number pad has no Return.
- The Flipper row reads `Searching…` while a scan runs (it wins over a
  connection), `Bluetooth` when connected, and `Not connected` with
  `antenna.radiowaves.left.and.right.slash` otherwise, which the spec does
  not name. A Flipper connected without a chosen one is titled `Flipper`.
  The scan button reads `Stop scanning` while it runs, as shipped.
- The watch gets the settings 0.5 s after the last applied change
  (`WatchSettingsSender.defaultDebounce`), so a quick run of changes sends
  once, the latest.
- The QR footer shows a failed read in red, in place of the hint. The
  close button is an `xmark` in a material circle; the bracket frame is
  240 pt, white. By eye.
- New spool: the colour picker has no opacity; with no colour on the tag
  it shows grey and stores nothing until a colour is picked. The title and
  `NTAG 7-byte · <uid>` sit in the navigation bar's centre. The material
  menu's empty entry reads `Choose` (the Mac keeps `Choose…`).
- Link to existing: the rows are buttons with the `checkmark` on the
  pick; the search field is always shown; no match is a
  `ContentUnavailableView` with `magnifyingglass`. Link with a pick that
  carries another tag asks with the alert; the iPad shows the inline
  warning instead (`ipados-ui-spec.md`).
- Clear keeps ⌘⌫ on a hardware keyboard, now a menu command of the app
  (`FeedCommands`, shared with the iPad) rather than the toolbar button's
  shortcut; ⌘S and ⌘↑ / ⌘↓ are menu commands too.

## Open questions for the owner

None. Decided 2026-10-27: Net/Gross below the core clamps to 0, as on the
Flipper; with both sides down the banner shows both.
