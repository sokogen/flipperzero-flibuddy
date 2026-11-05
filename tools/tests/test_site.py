"""The GitHub Pages site in site/: static HTML, no external hosts.

The apps and the Flipper's Get app QR link to these pages, so the URLs they
use must map to files here.
"""

import re
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse

import pytest

REPO = Path(__file__).resolve().parents[2]
SITE = REPO / "site"
BASE = "https://sokogen.github.io/flipperzero-flibuddy/"
PAGES = [SITE / "index.html", SITE / "privacy" / "index.html", SITE / "support" / "index.html"]


class Refs(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[str] = []  # a href
        self.assets: list[tuple[str, str]] = []  # (tag, url) loaded by the page

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "a" and a.get("href"):
            self.links.append(a["href"])
        elif tag == "link" and a.get("href"):
            self.assets.append((tag, a["href"]))
        elif tag in ("script", "img", "iframe", "source") and a.get("src"):
            self.assets.append((tag, a["src"]))


def refs(page: Path) -> Refs:
    parser = Refs()
    parser.feed(page.read_text(encoding="utf-8"))
    return parser


def resolve(page: Path, url: str) -> Path:
    path = urlparse(url).path
    target = (page.parent / path).resolve()
    return target / "index.html" if target.is_dir() else target


@pytest.mark.parametrize("page", PAGES, ids=lambda p: str(p.relative_to(SITE)))
def test_internal_links_resolve(page):
    parsed = refs(page)
    for url in parsed.links + [u for _, u in parsed.assets]:
        if urlparse(url).scheme in ("http", "https", "mailto"):
            continue
        assert resolve(page, url).is_file(), f"{page.name}: {url}"


@pytest.mark.parametrize("page", PAGES, ids=lambda p: str(p.relative_to(SITE)))
def test_nothing_is_loaded_from_another_host(page):
    parsed = refs(page)
    for tag, url in parsed.assets:
        assert not urlparse(url).netloc, f"{page.name}: <{tag}> loads {url}"
    assert "<script" not in page.read_text(encoding="utf-8")
    css = (SITE / "style.css").read_text(encoding="utf-8")
    assert not re.search(r"url\(|@import|//", css)


def test_app_links_map_to_pages():
    source = (REPO / "host/Sources/FliBuddyCore/FliBuddyCore.swift").read_text(encoding="utf-8")
    urls = re.findall(r'URL\(string: "(' + re.escape(BASE) + r'[^"]*)"\)', source)
    assert len(urls) == 2
    for url in urls:
        rel = url.removeprefix(BASE)
        assert (SITE / rel / "index.html").is_file(), url
    assert (SITE / "index.html").is_file()  # the Get app QR points at BASE


def test_pages_are_complete():
    for page in PAGES:
        text = page.read_text(encoding="utf-8")
        assert "not affiliated" in text
        assert 'name="viewport"' in text
    assert "prefers-color-scheme: dark" in (SITE / "style.css").read_text(encoding="utf-8")
    assert "2026-11-05" in PAGES[1].read_text(encoding="utf-8")


def test_pages_workflow_deploys_site_on_main():
    import yaml

    wf = yaml.safe_load((REPO / ".github/workflows/pages.yml").read_text(encoding="utf-8"))
    on = wf[True]  # PyYAML reads the bare key `on` as True
    assert on["push"]["branches"] == ["main"]
    assert "site/**" in on["push"]["paths"]
    uses = [s.get("uses", "") for s in wf["jobs"]["deploy"]["steps"]]
    assert any(u.startswith("actions/upload-pages-artifact@") for u in uses)
    assert any(u.startswith("actions/deploy-pages@") for u in uses)
    assert wf["permissions"]["pages"] == "write"
