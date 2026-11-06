"""Replace an old empty-spool (core) weight on Bambuddy spools.

FliBuddy 1.0 changed its default core weight from 325 g to 242 g, and every
spool created before keeps 325 g. Gross weighings on those spools subtracted
325 g, so their remaining filament is low by the difference.

For each spool with the old core weight this sets the new one. A spool that
was weighed (`last_scale_weight`), is not archived and not empty also gets
`weight_used` lowered by the difference, which is what the last weighing
would have recorded with the new core; filament used by prints since then
stays counted. `weight_locked` goes out as it was, because Bambuddy locks the
weight on any `weight_used` write that leaves it out.

Without `--apply` nothing is written; the changes are only listed.

    cd tools
    BAMBUDDY_URL=https://bambuddy.example.com BAMBUDDY_API_KEY=... \\
        uv run python fix_core_weight.py [--old 325] [--new 242] [--apply]

The key needs inventory read and update. It is read from the environment
only and never printed.
"""

import argparse
import os
import sys
from dataclasses import dataclass, field

from bridge.bambuddy import BambuddyClient, BambuddyError, is_archived, remaining


@dataclass
class Change:
    spool_id: int
    title: str
    fields: dict
    remaining_before: int
    remaining_after: int
    note: str = field(default="")


def title(spool: dict) -> str:
    parts = (spool.get("material"), spool.get("subtype"), spool.get("color_name"))
    return " ".join(p for p in parts if p) or "?"


def plan(spools: list[dict], old: int, new: int) -> list[Change]:
    """The changes for every spool whose core weight is `old`, by spool id."""
    changes = []
    for spool in sorted(spools, key=lambda s: s.get("id", 0)):
        if spool.get("core_weight") != old:
            continue
        fields = {"core_weight": new}
        before = remaining(spool)
        used = spool.get("weight_used") or 0
        label = spool.get("label_weight", 0)
        if spool.get("last_scale_weight") is None:
            note = "never weighed: weight used kept"
        elif is_archived(spool):
            note = "archived: weight used kept"
        elif used >= label:
            note = "empty: weight used kept"
        else:
            note = ""
            fields["weight_used"] = max(0.0, float(used) - (old - new))
            fields["weight_locked"] = bool(spool.get("weight_locked"))
        after = remaining({**spool, **fields})
        changes.append(Change(spool["id"], title(spool), fields, before, after, note))
    return changes


def describe(change: Change) -> str:
    line = f"#{change.spool_id} {change.title}: {change.remaining_before} -> {change.remaining_after} g left"
    return f"{line} ({change.note})" if change.note else line


def main(argv=None, env=None, client_factory=BambuddyClient, out=sys.stdout) -> int:
    parser = argparse.ArgumentParser(description="Replace an old core weight on Bambuddy spools.")
    parser.add_argument("--old", type=int, default=325, help="core weight to replace, grams (325)")
    parser.add_argument("--new", type=int, default=242, help="new core weight, grams (242)")
    parser.add_argument("--apply", action="store_true", help="write the changes (default: list only)")
    args = parser.parse_args(argv)
    env = os.environ if env is None else env

    def say(text: str) -> None:
        print(text, file=out)

    if args.old == args.new:
        say("--old and --new must differ")
        return 2
    for name in ("BAMBUDDY_URL", "BAMBUDDY_API_KEY"):
        if not env.get(name):
            say(f"set {name}")
            return 2
    client = client_factory(env["BAMBUDDY_URL"], env["BAMBUDDY_API_KEY"])

    try:
        changes = plan(client.list_spools(include_archived=True), args.old, args.new)
    except BambuddyError as error:
        say(f"listing spools failed: {error}")
        return 1
    if not changes:
        say(f"no spools with core {args.old} g")
        return 0

    say(f"{len(changes)} spool(s) with core {args.old} g -> {args.new} g:")
    for change in changes:
        say("  " + describe(change))
    if not args.apply:
        say("dry run: nothing written; run again with --apply to write")
        return 0

    done = 0
    for change in changes:
        try:
            client.update_spool(change.spool_id, change.fields)
        except BambuddyError as error:
            say(f"#{change.spool_id} failed: {error}")
            say(f"updated {done} spool(s); stopped")
            return 1
        done += 1
    say(f"updated {done} spool(s)")
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
