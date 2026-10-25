"""Fixture generators for protocol/fixtures. Run from tools/ as
`uv run python -m fixtures.<name>`."""

import json
from pathlib import Path

PROTOCOL = Path(__file__).resolve().parents[2] / "protocol"


def to_json(data) -> str:
    """Stable on-disk JSON: two-space indent, trailing newline."""
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def write(outputs: dict[str, str]) -> None:
    """Write {path relative to protocol/: content} and report each file."""
    for relative, content in outputs.items():
        path = PROTOCOL / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        print(f"wrote protocol/{relative}")
