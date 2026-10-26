"""Line coverage gate for the Swift package.

Reads the llvm-cov JSON export that `swift test --enable-code-coverage`
writes (path from `swift test --show-codecov-path`) and fails when the
files under a path prefix, `Sources/FliBuddyCore/` by default, cover
fewer lines than the minimum.
"""

import argparse
import json
import sys

DEFAULT_PREFIX = "Sources/FliBuddyCore/"


def line_coverage(report: dict, prefix: str) -> tuple[int, int]:
    """Covered and total lines of the files whose path contains `prefix`."""
    covered = count = 0
    for export in report["data"]:
        for file in export["files"]:
            if prefix not in file["filename"]:
                continue
            lines = file["summary"]["lines"]
            covered += lines["covered"]
            count += lines["count"]
    return covered, count


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("codecov_json")
    parser.add_argument("--prefix", default=DEFAULT_PREFIX)
    parser.add_argument("--min", type=float, default=80.0, help="minimum line coverage in percent")
    args = parser.parse_args(argv)

    with open(args.codecov_json, encoding="utf-8") as f:
        covered, count = line_coverage(json.load(f), args.prefix)
    name = args.prefix.rstrip("/").rsplit("/", 1)[-1]
    if count == 0:
        print(f"{name}: no files under {args.prefix} in {args.codecov_json}")
        return 1
    percent = 100 * covered / count
    print(f"{name} line coverage {percent:.1f} % ({covered}/{count})")
    if percent < args.min:
        print(f"{name} line coverage is below {args.min:g} %")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
