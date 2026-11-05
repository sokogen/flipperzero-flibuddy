# Catalog screenshots

The Flipper Apps Catalog shows these screenshots; the first is the
preview. They must be qFlipper exports exactly as qFlipper saves them:
512×256 PNG in its two colours, orange (254, 138, 44) and black (0, 0, 0),
never resized, recoloured, cropped or converted.
`tools/tests/test_catalog.py` checks every PNG here.

## Taking them

1. On the Flipper, open FliBuddy → Settings and set Connection to
   Bluetooth, so that the app leaves the USB port to qFlipper.
2. Connect the Flipper to qFlipper with the USB cable and open the screen
   streaming view.
3. Connect the FliBuddy iPhone app over Bluetooth (for the screens that
   need it) and bring each screen up on the Flipper.
4. Take each with qFlipper's screenshot button and save it here under
   the name below.

## Screens

| File | Screen |
|---|---|
| `1_spool.png` | Result for a spool in Bambuddy: material and colour, `In Bambuddy #...`, the remaining bar (preview) |
| `2_waiting.png` | Waiting for app, with the OK **Get app** and ▶ **Settings** chips (iPhone app not connected) |
| `3_new_spool.png` | Result for a Bambu Lab tag Bambuddy does not know: inverted `Not in Bambuddy` (Auto-save new off) |
| `4_weight.png` | Weight entry (OK on a known spool) |
| `5_settings.png` | Settings |

The list is the `screenshots` of `../catalog/manifest.yml`; add or rename
a file in both.
