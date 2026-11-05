#!/bin/sh
# Screenshot of the FliBuddy app in the demo mode (-FliBuddyDemo YES: a
# demo Flipper and an in-memory Bambuddy, see DemoFixtures in
# host/Sources/FliBuddyCore/Demo) on an iOS, iPadOS or watchOS simulator.
#
#   tools/sim_shot.sh [-a light|dark] [-s <content size>] [-w <seconds>]
#                     <device name or UDID> <output.png> [<launch argument>...]
#
# Boots the simulator if needed; on an iPhone or iPad sets the appearance
# (default light), the Dynamic Type size (default large; e.g. extra-large,
# accessibility-medium) and the status bar to 9:41 (watchOS simulators
# support none of these); installs the app `make apple-build` put in
# host/Apple/.build, launches it with the demo argument, waits (default 4 s)
# and saves a PNG. Launch arguments after the output go to the app, e.g.
# `-FliBuddyDemoPane spools` to open the demo on the Spools tab.
#
# simctl cannot rotate a device: the screenshot is in the orientation the
# simulator boots in (portrait), or the one last set in the Simulator app.
set -eu

# The usage text is the comment block's "tools/sim_shot.sh [...]" lines.
usage() {
    sed -n '/^#   tools\/sim_shot.sh/,/^#                     </p' "$0" | sed 's/^# //' >&2
    exit 2
}

appearance=light
content_size=large
wait_seconds=4
while getopts a:s:w:h opt; do
    case $opt in
        a) appearance=$OPTARG ;;
        s) content_size=$OPTARG ;;
        w) wait_seconds=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ $# -ge 2 ] || usage
device=$1
output=$2
shift 2

case $appearance in light | dark) ;; *) echo "appearance: light or dark" >&2; exit 2 ;; esac

root=$(cd "$(dirname "$0")/.." && pwd)
products=$root/host/Apple/.build/Build/Products

# "<udid> <runtime> <state>" of the device named or numbered $device; a
# booted one first when several share the name.
found=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
wanted = sys.argv[1]
matches = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for device in devices:
        if wanted in (device["udid"], device["name"]):
            matches.append((device["state"] != "Booted", device["udid"], runtime, device["state"]))
if matches:
    _, udid, runtime, state = sorted(matches)[0]
    print(udid, runtime, state)
' "$device")
[ -n "$found" ] || { echo "no available simulator named or numbered '$device'" >&2; exit 1; }
udid=${found%% *}
state=${found##* }
runtime=${found#* }
runtime=${runtime% *}

case $runtime in
    *watchOS*)
        app=$products/Debug-watchsimulator/FliBuddyWatch.app
        bundle=com.sokolachko.flibuddy.watchkitapp
        watch=1
        ;;
    *)
        app=$products/Debug-iphonesimulator/FliBuddy.app
        bundle=com.sokolachko.flibuddy
        watch=0
        ;;
esac
[ -d "$app" ] || { echo "$app not found; run make apple-project apple-build" >&2; exit 1; }

if [ "$state" != Booted ]; then
    echo "booting $device ($udid)"
    xcrun simctl boot "$udid"
fi
xcrun simctl bootstatus "$udid" -b >/dev/null

# watchOS simulators support neither (the watch is always dark).
if [ "$watch" = 0 ]; then
    xcrun simctl ui "$udid" appearance "$appearance"
    xcrun simctl ui "$udid" content_size "$content_size"
fi
if [ "$watch" = 0 ]; then
    # The override outlives the script: clear it however the script ends.
    trap 'xcrun simctl status_bar "$udid" clear >/dev/null 2>&1 || true' EXIT
    xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active \
        --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 ||
        echo "warning: status bar not overridden" >&2
fi

xcrun simctl install "$udid" "$app"
xcrun simctl launch --terminate-running-process "$udid" "$bundle" -FliBuddyDemo YES "$@" >/dev/null
sleep "$wait_seconds"

mkdir -p "$(dirname "$output")"
xcrun simctl io "$udid" screenshot --type=png "$output" >/dev/null
echo "$output"
