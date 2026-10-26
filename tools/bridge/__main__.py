"""Run the dev bridge: Flipper over USB serial <-> Bambuddy.

    uv run python -m bridge --bambuddy http://NAS:8000 --api-key bb_... \\
        [--port /dev/cu.usbmodemflip_X1] [--dump-dir DIR]

Without --bambuddy the bridge only answers hello, prints parsed scans and
saves dumps; lookups come back as errors.
"""

import argparse
import os
import sys
from pathlib import Path

import serial
from serial.tools import list_ports

from bridge import bambuddy, session

BAUD = 115200


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="python -m bridge", description=__doc__.split("\n\n")[0])
    parser.add_argument("--port", help="serial device (default: auto-detect /dev/cu.usbmodemflip_*)")
    parser.add_argument("--bambuddy", metavar="URL", help="Bambuddy base URL, e.g. http://192.168.1.10:8000")
    parser.add_argument("--api-key", default=os.environ.get("BAMBUDDY_API_KEY"),
                        help="Bambuddy API key (default: $BAMBUDDY_API_KEY)")
    parser.add_argument("--core-weight", type=int, default=session.DEFAULT_CORE,
                        help="empty spool weight in g for new items (default: 250)")
    parser.add_argument("--catalog-id", type=int, help="core_weight_catalog_id for new items")
    parser.add_argument("--dump-dir", type=Path, help="save every scan as a tag fixture here")
    args = parser.parse_args(argv)
    if args.bambuddy and not args.api_key:
        parser.error("--bambuddy needs --api-key or $BAMBUDDY_API_KEY")
    return args


def check_inventory_mode(client) -> str | None:
    """None when Bambuddy is in internal inventory mode, else the reason to refuse."""
    try:
        if client.spoolman_enabled():
            return "Bambuddy is in Spoolman mode; the bridge supports internal inventory only"
    except bambuddy.PermissionMissing as error:
        return f"{error}; add it to the key in Bambuddy"
    except bambuddy.BambuddyError as error:
        return f"cannot reach Bambuddy: {error}"
    return None


def log(text: str) -> None:
    print(text, flush=True)


def serve(port, bridge: session.Bridge, log=log) -> None:
    """Exchange lines with an open serial port until it fails or closes."""
    framer = session.LineFramer()

    def send(line: str) -> None:
        port.write(line.encode("ascii") + b"\n")

    send(bridge.greet())
    while True:
        try:
            data = port.read(port.in_waiting or 1)
        except (serial.SerialException, OSError) as error:
            log(f"port closed: {error}")
            return
        for line in framer.feed(data):
            for reply in bridge.handle_line(line):
                send(reply)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    client = None
    if args.bambuddy:
        client = bambuddy.BambuddyClient(args.bambuddy, args.api_key)
        refusal = check_inventory_mode(client)
        if refusal:
            print(f"error: {refusal}", file=sys.stderr)
            return 2
    else:
        log("no --bambuddy: lookups will report an error")

    device = args.port or session.find_flipper_port(p.device for p in list_ports.comports())
    if not device:
        print("error: no Flipper found (/dev/cu.usbmodemflip_*); is the app open?", file=sys.stderr)
        return 1

    bridge = session.Bridge(client, core_weight=args.core_weight, catalog_id=args.catalog_id,
                            dump_dir=args.dump_dir, log=log)
    log(f"opening {device}")
    try:
        with serial.Serial(device, BAUD, timeout=0.2) as port:
            serve(port, bridge, log)
    except KeyboardInterrupt:
        pass
    except serial.SerialException as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
