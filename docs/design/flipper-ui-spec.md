# Flipper UI spec

The screens of the FliBuddy Flipper app, after the Claude Design page
"FliBuddy Flipper" (`docs/design/flipper/flipper-ui.js`, the prototype's
renderer and state machine). The design's pixel positions are the target;
this document is what the app does. The flow is the pure reducer in
`flipper/src/app_state.{h,c}`, all wording is built by
`flipper/src/ui_frame.c` and both are tested on the host
(`flipper/tests/test_app_state.c`, `test_ui_frame.c`); `ui_draw.c` only
places the frame on the canvas. Keep this file current when either changes.

## Conventions

Screen 128×64, 1 bit. OK always does the screen's main action, ◀ opens the
menu or cancels, ▶ is the quick second action, Back goes back. The bottom
row holds up to three button chips (◀ label left, OK label centre, label ▶
right; the firmware's `elements_button_left/center/right`). A key without a
chip does nothing, except where a screen says so below.

Titles use FontPrimary with a dotted rule under them, body text
FontSecondary, the weight digits FontBigNumbers. The transport icon (USB or
Bluetooth) sits top right on every screen with a header; the Bluetooth icon
blinks while the Flipper advertises without a host. Icons are XBM files in
`flipper/images/`, generated from the design's bitmaps by
`tools/fixtures/make_flipper_icons.py` (a pytest fails when they are stale).

The firmware fonts are ASCII only: `...` stands for the ellipsis and ` - `
for the design's middle dot (`PLA Basic - 590 g left`). A spool is titled
`material subtype` (`PLA Basic`), or the subtype alone when it already
starts with the material (`PLA Silk+`).

## Screens

Keys: OK / ◀ / ▶ / ▲▼ / Back.

1. **Waiting for host** (no host): title "FliBuddy", the version, a line for
   the transport in use, "Waiting for host" with animated dots. The line
   reads `USB: no host app`, `USB unavailable` (the port did not open),
   `Visible as <name>` (Bluetooth, advertising), `Bluetooth: no host app`
   (a central subscribed without a `hello`) or `Bluetooth off`. ▶ Settings,
   Back exits the app. A tag read here shows Result · no host.
2. **Ready** (host connected): spool picture with animated waves, "Ready",
   "Hold spool tag to the back". After an action an inverted bar with a
   check names the last outcome (`Saved PLA Basic 590 g`, `Added PLA
   Silk+`, `New PLA Basic 1000 g`, `Empty PLA Basic`, `Deleted PLA Basic`)
   and the text reads "Next spool". ▶ Settings, Back exits the app. ◀ does
   nothing (the design's Recent screen is not built).
3. **Reading tag**: spool and waves, "Keep still". Back goes home.
4. **Looking up**: while the `lookup` is pending (no timeout): the tag's own
   detailed type or material when it has one, "Asking the host". Back goes
   home. Not in the design.
5. **Result · known**: colour swatch (Bayer-dithered by the luminance of the
   spool's RGBA) and the spool as title; the colour name (or
   `Color #RRGGBB`); `Tag 04B7...3C80` (a 4-byte UID is shown whole);
   `590 g left of 1000`, or `Archived` for a spool marked empty. OK Weigh,
   ▶ New (Mark as new), ◀ Menu, Back home.
6. **Result · unknown Bambu tag** (Auto-save new off): swatch and the tag's
   material as title; colour; UID; inverted `Not in Bambuddy`. OK Add, ▶
   Link, ◀ Menu, Back home. A tag with data but no material is titled
   `Spool tag` with OK Create (asks the host to create it).
7. **Result · blank tag**: `Blank tag`; the tag type; UID; inverted
   `No spool data`. OK Link (asks the host), ◀ Menu, Back home.
8. **Result · no host**: the tag's own text or type as title, the type, UID,
   inverted `No host`. ◀ Menu (Tag details only), Back home.
9. **Menu** (▲▼ wrap, OK chooses, Back to the result; four rows visible):
   known: Weigh, Mark as new, Mark as empty, Relink on host, Tag details,
   Delete spool. Unknown Bambu: Add new, Add and weigh, Link on host, Tag
   details. No material: Create on host, Link on host, Tag details. Blank:
   Link on host, Tag details. No host: Tag details.
10. **Tag details**: Type, UID with colons, Data (`15/16 sectors` or
    `135 pages`), RGBA, Label (`1000 g`) when known. OK / Back to the menu.
11. **Delete spool?**: warning icon, the spool and colour, "Removes it from
    Bambuddy for good." ◀ Cancel and Back to the menu, ▶ Delete (far from
    OK); OK does nothing.
12. **Weight**: title "Weight", a net/gross chip top right, four big digits
    with dimmed leading zeros and a cursor bar under the active digit; the
    cursor starts on the hundreds. ◀▶ move (wrapping); the position left of
    the first digit is the mode chip, where ▲▼ toggle net / gross and an
    untouched pre-fill is recomputed. ▲▼ on a digit change it (wrapping;
    held, they repeat). OK Save, Back to the result. The line under the
    digits: gross `Net 590 g - core 325`, gross without a known core
    `Core weight unknown`, net `Saves 590 g left`; gross below the core
    shows inverted `Below core weight`, and OK flashes red without sending.
    Pre-fill: gross = remaining + core, net = remaining; without a spool
    the lookup defaults (gross: the last gross, else label + core; net:
    gross - core, else label). The mode starts gross and is kept for the
    session. After Add and weigh on an unknown tag, Save creates the spool
    and records the weight.
13. **Saving / Adding / Deleting / Updating** (title per action): the spool
    (`- 590 g` net when saving), an indeterminate bar, "Waiting for
    Bambuddy". No keys; Error · No host reply after 10 s.
14. **Saved**: big check, "Saved", `PLA Basic - 590 g left`; after 1.3 s
    (or OK / Back) Ready with the Saved bar.
15. **Added to Bambuddy**: the spool and colour, `Spool #31 - 1000 g`. OK
    Weigh, ▶ Next (Ready with the Added bar), Back Ready. No time limit.
    Shown after Add, and at once after a scan when Auto-save new is on and
    the host created the spool.
16. **Marked as new**: `1000 g left - full`, a 3 s progress bar and
    "Next spool in 3 s". ◀ Undo, OK Weigh, Back Ready.
17. **Marked as empty**: `0 g left - archived`, the same bar. ◀ Undo; OK and
    Back go to Ready.
18. **Deleted**: "Tag is free to reuse", the same bar, no Undo. When the
    bar runs out, Ready with the Deleted bar; Back goes to Ready at once,
    without the bar; OK does nothing.
19. **Link tag / Create on host**: "Pick the spool in" / "Finish the spool
    in", "FliBuddy on host", bouncing dots. ◀ Cancel and Back to the result.
    The host's `result` only stops the 10 s timeout; when the host links or
    creates the spool it pushes a fresh `lookup` for the same scan and the
    screen becomes Result · known. Such a lookup also replaces Result, Menu
    and Tag details for that scan.
20. **Error**: a title per case, warning icon, up to three lines (the
    host's `lines` and `error` when present). Titles follow the failed
    action (`Not saved`, `Not added`, `Not deleted`, `Not updated`,
    `Not linked`) or the case (`Lookup failed`, `No host reply`, `Host
    lost`, `Not sent`, `Tag not read`). After a failed intent, while the
    host is there, ◀ Back and Back return to the result and ▶ Retry
    resends the same intent under its id; otherwise there is no Retry chip
    and ◀, ▶ and Back go home.
21. **Settings** (▲▼ select, ◀▶ change the value in place, Back saves and
    returns home): Connection (USB / Bluetooth), Auto-save new (Off / On),
    Feedback (Vibro+LED / LED / Off), Sound (Off / On), Version (OK opens
    About). Leaving with another Connection, or after the transport in use
    failed to open, restarts the transport.
22. **About**: app icon, "FliBuddy", "for Bambuddy", `Version 0.1.0`,
    `Protocol 2 - fw 1.5.1`, `Host: <app> - USB` / `- BLE` or
    `Host: not connected`. OK / Back to Settings.

## Mark as new, Mark as empty and Undo

Undo is local. The Mark toasts send nothing when they open; ◀ Undo returns
to the result and nothing leaves the Flipper. The mark is sent (`full` /
`empty`) when the bar runs out, on OK, on Back, or when another tag comes
near; it then goes through Updating to Ready with the New / Empty bar
(no second feedback). OK on Marked as new sends `full` first and opens
Weight once it is done. Losing the host on a pending toast drops the mark
and shows Result · no host. The design commits at once and offers Undo
afterwards; this app holds the change for the 3 s instead.

## Reading tags

The reader runs on Waiting, Ready, Reading, Result, Saved and the toasts. A
tag that was read is not read again until it has left the field (three
150 ms polls in a row without an answer) or another tag answers, so a spool
left on the Flipper does not rescan in a loop. Only one intent is ever in
flight.

## Feedback

Per the Feedback and Sound settings (`flipper/src/feedback.h`):

| Event | LED | Vibro | Sound = On |
|---|---|---|---|
| host connected, tag read | blue | short | - |
| saved, added, marked, deleted, a link's fresh lookup | green | short | success beeps |
| error, Save refused below the core | red | long | error beeps |

Feedback = LED drops the vibro; Off drops the LED and the vibro. Sound = On
adds the beeps whatever Feedback says. Every event wakes the backlight.

## Not built

The design's Recent screen (Ready's ◀), the settings After scan and Weigh
as, and Connection = Auto (the app uses the one transport chosen).
