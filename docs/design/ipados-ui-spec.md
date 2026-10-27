# FliBuddy iPad: UI specification from the design

Source: the Claude Design project "FliBuddy mobile app design"
(`docs/design/source/FliBuddy Spec.dc.html` and
`docs/design/source/FliBuddy iPad.dc.html`), imported on 2026-10-27. Like
the iPhone page, the iPad page imports the shared prototype model
`docs/design/source/flibuddy-core.js` (row view-model `vm`, connection
tables `FLIP` / `BAMBU` and `statusVM`, `Session`).

This file covers the iPad app (`host/Apple/iOS`, the same target as the
iPhone, views in `host/Sources/FliBuddyUI`). **Everything not stated here is
as in `ios-ui-spec.md`**: the owner decisions, the assumptions and their
answers, the stance, the row-states table and its copy, the weight rules,
the sheets, Tag details, the empty and blocking states, Settings (applies on
change) and the tokens. The portrait layout *is* the iPhone layout.

Precedence: as in the iPhone spec. Where this file and the shipped code
disagree, this file wins; where it is silent, the iPhone spec, then the
shipped behaviour. The owner decisions outrank the design pages;
`protocol/PROTOCOL.md`, `docs/design/flipper-ui-spec.md` and the approved
design document outrank this file on behaviour.

## What the iPad adds to the iPhone answers

- Assumption 5 (settings apply on change) holds on the iPad as on the
  iPhone. The iPad has no WatchConnectivity, so nothing is sent to a watch.
- The iPad shows both connection states in the sidebar, not the iPhone
  banner, in landscape.

## Two layouts

"Landscape on a bench stand, usually with a keyboard." The design draws
landscape (1366 × 1024) as a `NavigationSplitView` with one-line rows and
portrait (1024 × 1366) as the iPhone layout with a top tab bar.

- **Landscape (regular width):** sidebar + feed table, below.
- **Portrait (compact presentation):** the iPhone `TabView` (Feed /
  Settings), shown as the iPadOS floating tab bar at the top (a glass
  capsule with Feed and Settings), the iPhone connection banner under the
  title, Clear as the `trash` icon button in the navigation bar, stacked
  cards at most 760 wide, centred. Behaviour exactly as on the iPhone,
  including the number keyboard and a full-width Save.

Which layout shows is decided by the window's width, not by
`horizontalSizeClass` alone: a full-screen iPad in portrait is a regular
size class, and the design wants the card layout there (owner decision
2026-10-27: follow the design for now). The one-line table shows when the
detail column is at least 900 pt wide, else the cards.

## Landscape structure

```swift
NavigationSplitView {
  List(selection: $pane) {
    Section("Connections") {
      FlipperStatusRow()
      BambuddyStatusRow() }
    NavigationLink(value: .feed) {
      Label("Feed", systemImage: "list.bullet") }.badge(feed.count)
    NavigationLink(value: .settings) {
      Label("Settings", systemImage: "gearshape") }   // shows "⌘," trailing
  }
  .navigationTitle("FliBuddy")
  .safeAreaInset(edge: .bottom) {
    Button("Clear feed", systemImage: "trash", role: .destructive)
      .keyboardShortcut(.delete) }                    // shows "⌘⌫" trailing
} detail: {
  FeedTable()   // List, one-line rows; title "Feed" or "Settings"
}
// size class .compact (portrait): same TabView as iPhone
```

Sidebar (system sidebar, ≈ 300 wide, glass on iPadOS 26):

| Part | Spec |
|---|---|
| Title | `FliBuddy`, large title |
| Section header | `Connections`, `.subheadline.weight(.semibold)` `.secondary` |
| Status row | symbol 22 pt in the state's tint · name (`Flipper` / `Bambuddy`, `.body` 17) over a sub line (`.footnote` 13, `.secondary`, `.red` when the Bambuddy state is red) · the state's action as a 28 pt `.tint` capsule chip (Connect, Check, Retry, Settings) |
| Flipper sub line | `Workshop · Bluetooth` when connected (the Flipper's name), else the status bar phrase without the `Flipper · ` prefix: `No Flipper · searching` (with a 10 pt spinner), `Flipper nearby, not connected`, `Open FliBuddy on the Flipper` |
| Bambuddy sub line | the core's `BAMBU` phrase without the `Bambuddy` prefix, capitalised: `Ready · bambuddy.local` (the URL's host), `Not checked`, `Unreachable`, `API key lacks inventory permission`, `In Spoolman mode`, `Ready · colour names unavailable` (the prototype strips the prefix with string replaces, which leaves `· not checked` for one state; the capitalised forms are the intent) |
| Feed | `list.bullet` · `Feed` · the row count as a badge |
| Settings | `gearshape` · `Settings` · `⌘,` in `.footnote` `.tertiary` |
| Clear feed | bottom of the sidebar, `trash` · `Clear feed` in red · `⌘⌫`; disabled while the feed is empty |

Symbols and tints for the status rows are the macOS status-bar table
(`macos-ui-spec.md`, "Status bar"), the USB row excepted.

## Feed table row (landscape, one line)

The rows sit in one inset-grouped card (`secondarySystemGroupedBackground`,
corner ≈ 24), separated by hairlines; padding 10 vertical, 20 horizontal;
minimum height 76. Columns, 12 apart:

| Column | Width | Content |
|---|---|---|
| Swatch | 28 | `Circle()` from the RGBA, `.separator` stroke; dashed `.tertiary` without colour |
| Title | 150 | material + subtype, `.headline` (17 sb); the UID line of the design moves to Tag details (owner decision) |
| Colour | 112 | colour name and Bambu code, `.subheadline` `.secondary` (15): `Bambu Green · 10501`; `Jade White · archived` for an archived spool |
| Remaining | 140 | `.subheadline.monospacedDigit()` `.secondary` (15): `590 g left of 1000`, `label 1000 g` |
| Status | flexible | symbol 17 pt + phrase (15); under it, in entry states, the short readout `.footnote.monospacedDigit()` (13): `Saves 590 g left`, `Type the scale reading`, or red `Below the core weight (325 g)`; the timeout note in `.footnote` |
| Entry / actions | auto, trailing | weight field · `g` · Net/Gross · Save, 8 apart; or the action buttons |

Entry parts:

| Part | Spec |
|---|---|
| Weight field | 100 × 44, `tertiarySystemFill`, `.rect(cornerRadius: 12)`, right-aligned value `.system(.largeTitle, design: .rounded).bold().monospacedDigit()` scaled to 28 pt, placeholder `0`; focus ring 2 pt `.tint`. Accessibility label `Gross weight, grams` / `Net weight, grams`. |
| Unit | `g`, 17 sb `.secondary` |
| Net / Gross | segmented 120 × 34, capsule track, labels 14 sb |
| Save | height 44, minimum width 76, `.borderedProminent` capsule, 17 sb, `Save` / `Saving…`; tooltip / pointer label `Save (⌘S)` |
| Actions | capsules 44 high, padding 18, 8 apart, 15 sb; prominent `.tint` with white text, the other `tertiarySystemFill` with `.tint` text |

The Spec page's "Per platform" note says field 120 · Net/Gross 150 and a
minimum height of 64; the iPad page draws field 100, Net/Gross 120 and 76.
This file follows the iPad page, which is the drawn and interactive mock-up
and leaves the flexible status column room for the readout.

On a `Not in Bambuddy` Bambu row and on Created, the secondary buttons
(**New**, **Link to existing…**) do not fit beside the entry: they go as
plain `.footnote` buttons under the short readout in the status column
(builder's call; the design has no row with both).

The focused row's background is the selection tint. A tap on a saved row
reopens it. A row waiting behind a touched field gets the 2 pt `.tint`
outline, as on the Mac.

## Keyboard and touch

"Hardware keyboard: same as macOS. Touch: same as iPhone."

1. Landscape: the newest Enter weight row focuses its inline field with the
   suggestion selected (the same focus model as the Mac and iPhone; it
   never steals from a touched field).
2. With a hardware keyboard: type, ⇥ to Net/Gross, ⌘S or Return saves.
   Holding ⌘ shows the shortcut overlay (the commands below are declared as
   menu commands so they appear there).
3. Without a keyboard the system number keyboard appears; the list scrolls
   the focused row into view above it.
4. Portrait behaves exactly like the iPhone: stacked card, full-width Save.
5. Clear lives in the sidebar and in the ⌘ menu; it asks for confirmation.

| Action | Keys |
|---|---|
| Save focused row | ⌘S or Return in the field |
| Clear feed (with confirmation) | ⌘⌫ |
| Settings | ⌘, |
| Field → mode → Save | ⇥ (⇧⇥ back) |
| Next / previous row | ⌘↓ / ⌘↑ (macOS parity; not on the iPad page) |

A successful save gives the iPhone's success haptic only where the device
has one; the iPad has none, so nothing extra.

## Sheets and dialogs

As on the iPhone (New spool, Link to existing, Tag details, Scan QR code),
presented as form sheets. Two differences on the iPad page:

- **Link to existing**: the move warning is inline under the list, not an
  alert: `exclamationmark.triangle.fill` orange + `<title> <colour> is linked
  to tag <tag>. Saving moves the link to <uid>.`; the ✓ button then moves the
  link. Use the inline form on the iPad (it has the room) and the alert on
  the iPhone.
- **Clear the feed?** is a centred alert-style dialog with **Clear feed**
  (destructive) and Cancel, same copy as the iPhone.

## Settings

The iPhone form in the detail column, title `Settings`, applies on change.
The page shows the QR footer `Scan the QR code Bambuddy shows when you create
an API key.` and the same Flipper rows (`Workshop`, state, `Scan for
Flipper`, `Forget this Flipper`) with no footer under them (the iPhone's
`Bluetooth only on iPhone…` footer is not drawn on the iPad). Without a camera the iPhone's no-camera footer applies.

## Differences from what ships

Checked against the code on 2026-10-27; the iPhone list applies to the
portrait layout and to everything shared (number keyboard, Net/Gross
conversion, colour code, Tag details, apply on change, sheets, QR cover).

1. **Layout switch.** `RootView` (`host/Apple/iOS/App.swift`) switches on
   `horizontalSizeClass`, so a full-screen portrait iPad gets the split view
   and landscape rows, not the iPhone cards.
2. **Sidebar.** The shipped sidebar holds only Feed and Settings: no
   Connections section with the two status rows and their action chips, no
   count badge on Feed, no `⌘,` hint, no Clear feed at its bottom.
3. **Status bar.** `FeedView` (`host/Sources/FliBuddyUI/FeedView.swift`)
   draws the macOS bottom `StatusBar` in the detail column on the iPad; the
   design moves both states into the sidebar (landscape) or the banner
   (portrait).
4. **Row geometry.** The one-line layout in `FeedRowView` is `#if
   os(macOS)`; the iPad stacks the entry under the header. It needs the
   one-line grid (28 · 150 · 112 · 140 · flexible · auto), field 100 × 44 at
   28 pt, segmented 120 × 34, Save 44 high, the short readout under the
   status and the colour and remaining in separate columns.
5. **Keyboard.** ⌘S, ⌘↑ / ⌘↓ (`FeedKeyboardShortcuts`) and ⌘⌫ (the toolbar
   Clear) exist; ⌘, does not open Settings on the iPad, and the commands are
   not menu commands, so the ⌘ overlay does not list them.
6. **Clear placement.** Clear is a toolbar button of the feed, labelled
   `Clear`, not the sidebar's `Clear feed`.
7. **Link warning.** Inline already, but worded `… Linking moves it to
   <uid>.` with a `Move link` button title (the macOS form); the iPad page
   says `Saving moves the link to <uid>.`

## Implemented differently (2026-10-27)

Where the app departs from this file or fills in what it leaves open, and
why. Items marked "by eye" still wait for the owner's check on screen.

Layout
- `FeedLayout.forWindow(width:isCompact:)` (`FliBuddyCore`) decides from
  the window's width, measured at the root: the table when the window
  leaves 900 pt beside a 300 pt sidebar (window ≥ 1200 pt) and the size
  class is regular, else the cards. A 13" iPad (1366 / 1376 pt) gets the
  table in landscape; an 11" iPad (1180–1210 pt) gets the cards in
  landscape too, as the 900 pt rule says. A narrow multitasking window
  gets the cards.
- The portrait cards are centred at most 760 wide through the list's
  content margins.

Sidebar
- The rows come from `Sidebar` (`FliBuddyCore`), built from the same two
  `StatusItem`s as the macOS status bar and the iPhone banner. A connected
  Flipper without a saved name reads `Flipper · Bluetooth`. Sub lines for
  states the table above leaves out: `Not set up`, `Rejected the API key`,
  `Checking…` (with the spinner); a Flipper problem (`Bluetooth is off`,
  a version mismatch) shows as it is.
- A state that spins (searching, checking) keeps its symbol
  (`antenna.radiowaves.left.and.right.slash`, `server.rack`) and shows the
  10 pt spinner before the sub line. The chip fills with the app tint, as
  on the iPhone banner. By eye.
- Clear feed is a plain red button in the sidebar's bottom inset with
  `⌘⌫` trailing; disabled it dims. By eye.

Feed table
- The focused row's background is the tint at 15 % rather than a `List`
  selection, so a tap in the row never fights the weight field. By eye.
- A row with no entry (a tag without material, a deleted spool) shows New
  and Link to existing… as the 44 pt capsules in the trailing column; the
  footnote buttons under the readout are for rows with an entry
  (`Not in Bambuddy` with material, Created).
- Save is the stock `.borderedProminent` capsule with a 30 pt label
  minimum height (about 44 pt), not an exact frame. By eye.

Keyboard
- The commands are `FeedCommands` on the app's scene: a `Feed` menu with
  Save Focused Row (⌘S), Previous Row (⌘↑), Next Row (⌘↓) and Clear Feed…
  (⌘⌫), and Settings… (⌘,) in the app menu. ⌘⌫ shows the feed and asks;
  ⌘, opens Settings in either layout. The iPhone gets the same commands.

Dialogs
- Clear the feed? is an alert beside the sidebar; the portrait cards keep
  the iPhone's confirmation dialog.
- The inline Link warning goes by device (an iPad shows it in both
  layouts, never the alert): `<title> <colour> is linked to tag <tag>.
  Saving moves the link to <uid>.` The ✓ button keeps its title; the Mac
  keeps `… Linking moves it to <uid>.` and `Move link`.

## Open questions for the owner

None. Decided 2026-10-27: portrait shows the iPhone cards, as designed.
