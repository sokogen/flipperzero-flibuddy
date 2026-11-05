"""The Flipper Apps Catalog submission prepared in flipper/: the manifest
draft (flipper/catalog/manifest.yml, copied to the catalog repository as
applications/NFC/flibuddy/manifest.yml at submission), the description
and changelog in the catalog's Markdown subset, and the qFlipper
screenshots in flipper/screenshots/.

The catalog's own check is its tools/bundle.py; these tests catch what
can be caught without it."""

import re
from pathlib import Path

import pytest
import yaml
from PIL import Image

FLIPPER = Path(__file__).resolve().parents[2] / "flipper"
MANIFEST = FLIPPER / "catalog" / "manifest.yml"
SCREENSHOTS = FLIPPER / "screenshots"
# qFlipper's export: the 128x64 screen at 4x, lit pixels orange.
SCREENSHOT_SIZE = (512, 256)
QFLIPPER_COLOURS = {(254, 138, 44), (0, 0, 0)}


def manifest() -> dict:
    return yaml.safe_load(MANIFEST.read_text(encoding="utf-8"))


def fam_field(name: str) -> str:
    text = (FLIPPER / "application.fam").read_text(encoding="utf-8")
    return re.search(rf'^\s*{name}="([^"]*)",$', text, re.MULTILINE).group(1)


def included(value: str) -> Path:
    """The file a manifest value loads with '@', relative to the subdir."""
    assert value.startswith("@")
    return app_path(value[1:])


def app_path(relative: str) -> Path:
    assert not relative.startswith("/")
    assert ".." not in Path(relative).parts
    path = (FLIPPER / relative).resolve()
    assert path.is_relative_to(FLIPPER)
    return path


# ---- the Markdown subset ----

# What the catalog's BasicFormattingEnforcingExtension refuses, line by line.
FORBIDDEN_LINES = [
    (re.compile(r"^#{3,}"), "header deeper than H2"),
    (re.compile(r"^\s*(=+|-+)\s*$"), "setext header or horizontal rule"),
    (re.compile(r"^\s*([*_])(\s*\1){2,}\s*$"), "horizontal rule"),
    (re.compile(r"^( {4}|\t)"), "indented code block"),
    (re.compile(r"^\s*>"), "blockquote"),
    (re.compile(r"^\s*\[[^\]]+\]:"), "reference definition"),
]
FORBIDDEN_TEXT = [
    ("`", "backtick"),
    ("<", "HTML or angle-bracket link"),
    ("&", "HTML entity"),
    ("![", "image"),
    ("][", "reference link"),
    ("|", "table"),
]


def markdown_problems(text: str) -> list[str]:
    problems = []
    for number, line in enumerate(text.splitlines(), 1):
        problems += [f"{number}: {what}" for pattern, what in FORBIDDEN_LINES if pattern.search(line)]
        problems += [f"{number}: {what}" for needle, what in FORBIDDEN_TEXT if needle in line]
    return problems


def test_the_markdown_check_knows_the_subset():
    allowed = "# Title\n\n## Part\n\nSome **bold**, *italic* and a [link](https://example.com).\n\n- a list\n- of items\n"
    assert markdown_problems(allowed) == []
    for bad in ("### Deep", "Text\n---", "***", "    code", "> quote", "`code`", "<b>x</b>", "&amp;",
                "![img](a.png)", "[a][b]", "[b]: https://x", "a | b"):
        assert markdown_problems(bad), bad


# ---- the manifest ----

def test_the_manifest_points_at_the_flipper_folder_of_the_repository():
    source = manifest()["sourcecode"]
    assert source["type"] == "git"
    location = source["location"]
    assert location["origin"] == "https://github.com/sokogen/flipperzero-flibuddy.git"
    assert location["subdir"] == "flipper"
    # filled with the full 40-character sha of the submitted commit
    assert "commit_sha" in location


def test_the_manifest_leaves_the_app_fields_to_the_fam():
    # name, id, version, category, author and icon come from application.fam;
    # name, id and version would have to match it exactly.
    assert set(manifest()) == {"sourcecode", "short_description", "description", "changelog", "screenshots"}


def test_the_short_description_is_the_fams():
    assert manifest()["short_description"] == fam_field("fap_description")


def test_the_description_and_changelog_are_files_in_the_app_folder():
    m = manifest()
    assert m["description"] == "@catalog/description.md"
    assert m["changelog"] == "@CHANGELOG.md"
    assert included(m["description"]).is_file()
    assert included(m["changelog"]).is_file()


@pytest.mark.parametrize("field", ["description", "changelog"])
def test_the_texts_use_only_the_catalogs_markdown(field):
    text = included(manifest()[field]).read_text(encoding="utf-8")
    assert text.isascii()
    assert markdown_problems(text) == []


def test_the_description_says_who_it_is_not_from_and_what_it_needs():
    text = included(manifest()["description"]).read_text(encoding="utf-8")
    assert "not affiliated with Bambu Lab or Flipper Devices" in " ".join(text.split())
    # the Flipper alone first, then the phone app and Bambuddy
    assert text.index("## On the Flipper alone") < text.index("## With the FliBuddy app")
    assert "## Extra requirements" in text
    assert "https://sokogen.github.io/flipperzero-flibuddy/" in text
    assert "https://github.com/maziggy/bambuddy" in text


def test_the_changelog_has_the_fams_version():
    text = included(manifest()["changelog"]).read_text(encoding="utf-8")
    assert f"## v{fam_field('fap_version')}" in text.splitlines()


def test_the_screenshots_are_listed_in_the_folder_readme():
    shots = manifest()["screenshots"]
    assert len(shots) >= 1
    readme = (SCREENSHOTS / "README.md").read_text(encoding="utf-8")
    for shot in shots:
        assert shot.startswith("screenshots/") and shot.endswith(".png")
        assert app_path(shot).parent == SCREENSHOTS
        assert Path(shot).name in readme


# ---- the screenshots ----

def screenshot_files() -> list[Path]:
    return sorted(SCREENSHOTS.glob("*.png"))


@pytest.mark.parametrize("path", screenshot_files() or [None], ids=lambda p: p.name if p else "none")
def test_a_screenshot_is_an_unedited_qflipper_export(path):
    if path is None:
        pytest.skip("no screenshots in flipper/screenshots yet (see its README)")
    with Image.open(path) as img:
        assert img.format == "PNG"
        assert img.size == SCREENSHOT_SIZE
        colours = {c for _, c in img.convert("RGB").getcolors(maxcolors=1 << 16)}
    assert colours == QFLIPPER_COLOURS


def test_screenshots_present_are_the_listed_ones():
    listed = {Path(s).name for s in manifest()["screenshots"]}
    assert {p.name for p in screenshot_files()} <= listed
