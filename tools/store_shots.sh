#!/bin/sh
# The App Store screenshots of FliBuddy (demo fixtures, see sim_shot.sh):
# iPhone 6.9" (1320x2868), iPad 13" (2064x2752, portrait) and Apple Watch
# (Series 12 46 mm, 416x496), after `make apple-project apple-build`.
#
#   tools/store_shots.sh [<output directory>]
#
# The default directory is host/Apple/.build/store-shots (git-ignored).
# Nothing in the fixtures shows an error, "by host", a raw tag header or an
# http address.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-$root/host/Apple/.build/store-shots}
shot=$root/tools/sim_shot.sh
mkdir -p "$out"

phone="iPhone 18 Pro Max"
pad="iPad Pro 13-inch (M5)"
watch="Apple Watch Series 12 (46mm)"

# Fail before the first shot when a simulator is missing.
available=$(xcrun simctl list devices available)
for name in "$phone" "$pad" "$watch"; do
    printf '%s\n' "$available" | grep -qF "    $name (" || { echo "no available simulator named '$name'" >&2; exit 1; }
done

# The store feed (no blank NTAG row); "none" keeps the keyboard down.
store="-FliBuddyDemoSet store"
unfocused="$store -FliBuddyDemoFocus none"

# iPhone: the focused weight entry, then the mixed feed, Spools with a
# search, the Link sheet and Settings filled from a QR code.

{
"$shot" -a light "$phone" "$out/iphone-1-weight-light.png" $store
"$shot" -a dark "$phone" "$out/iphone-2-feed-dark.png" $unfocused
"$shot" -a light "$phone" "$out/iphone-3-spools-search-light.png" -FliBuddyDemoPane spools -FliBuddyDemoSearch pla
"$shot" -a light "$phone" "$out/iphone-4-link-sheet-light.png" $unfocused -FliBuddyDemoSheet link
"$shot" -a light "$phone" "$out/iphone-5-settings-qr-light.png" -FliBuddyDemoPane settings -FliBuddyDemoQR YES

# iPad (portrait: simctl cannot rotate)
"$shot" -a light "$pad" "$out/ipad-1-feed-light.png" $unfocused
"$shot" -a light "$pad" "$out/ipad-2-spools-light.png" -FliBuddyDemoPane spools
"$shot" -a dark "$pad" "$out/ipad-3-feed-dark.png" $unfocused

# Apple Watch
"$shot" "$watch" "$out/watch-1-feed.png" $store
}
