"""The Flipper's firmware fonts are ASCII only: every string literal in the
app's sources is printable ASCII. Comments may use any character (the
sources say ◀▶ for the keys); texts from the host or a tag are folded to
ASCII by the decoders, which flipper/tests/test_ui_frame.c checks on every
frame it builds."""

import re
from pathlib import Path

SRC = Path(__file__).resolve().parents[2] / "flipper" / "src"

# A comment, a character literal or a string literal, whichever starts first.
TOKEN = re.compile(r"/\*.*?\*/|//[^\n]*|'(?:\\.|[^'\\\n])*'|\"((?:\\.|[^\"\\\n])*)\"", re.DOTALL)


def string_literals(source: str) -> list[str]:
    return [m.group(1) for m in TOKEN.finditer(source) if m.group(1) is not None]


def not_printable_ascii(literal: str) -> bool:
    return any(not (0x20 <= ord(ch) <= 0x7E) for ch in literal)


def test_literals_are_found_outside_comments():
    source = '/* "◀ Back" */\n// "…"\nconst char* s = "Get app"; char c = \'"\'; f("a\\"b", "…");\n'
    assert string_literals(source) == ["Get app", 'a\\"b', "…"]
    assert [not_printable_ascii(s) for s in string_literals(source)] == [False, False, True]


def test_every_string_literal_in_the_app_is_printable_ascii():
    files = sorted(SRC.rglob("*.[ch]"))
    assert files
    offenders = [
        f"{path.relative_to(SRC)}: {literal!r}"
        for path in files
        for literal in string_literals(path.read_text(encoding="utf-8"))
        if not_printable_ascii(literal)
    ]
    assert offenders == []


def test_the_screens_have_strings_to_check():
    literals = string_literals((SRC / "ui_frame.c").read_text(encoding="utf-8"))
    assert {"Get app", "No app yet?", "Waiting for app", "Settings"} <= set(literals)
