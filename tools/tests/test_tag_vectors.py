"""The C tag dump vectors in flipper/tests/vectors/tag_dumps.h.

They are the input of the C `scan` encoder test, which must reproduce
protocol/fixtures/messages/scan_*.json, so they have to carry exactly the
bytes of the tag fixtures and the scan parameters of the message generator.
"""

import json
import re
from pathlib import Path

from fixtures import make_message_fixtures, make_tag_vectors

REPO = Path(__file__).resolve().parents[2]
TAGS = REPO / "protocol" / "fixtures" / "tags"


def header() -> str:
    (content,) = make_tag_vectors.build().values()
    return content


def c_array(content: str, name: str) -> list[str]:
    """Rows of a generated array as upper-case hex strings."""
    body = re.search(rf"{name}\[[^=]*= \{{\n(.*?)\n\}};", content, re.DOTALL)
    if body is None:  # one-line array
        body = re.search(rf"{name}\[[^=]*= (\{{[^;]*\}});", content)
        rows = [body.group(1)]
    else:
        rows = body.group(1).splitlines()
    return ["".join(b[2:] for b in re.findall(r"0x[0-9A-F]{2}", row)) for row in rows]


def test_c_header_is_current():
    outputs = make_tag_vectors.build()
    assert list(outputs) == ["flipper/tests/vectors/tag_dumps.h"]
    for relative, content in outputs.items():
        assert (REPO / relative).read_text(encoding="utf-8") == content, (
            f"{relative} is stale; regenerate with "
            "`uv run python -m fixtures.make_tag_vectors`"
        )


def test_c_header_has_no_long_lines():
    assert all(len(line) <= 100 for line in header().splitlines())


def test_mfc_vectors_match_the_bambu_fixture():
    dump = json.loads((TAGS / "bambu_pla_basic_synthetic.json").read_text())
    content = header()
    assert c_array(content, "MFC_BLOCKS") == dump["blocks"]
    assert c_array(content, "MFC_UID") == [dump["uid"]]
    assert c_array(content, "MFC_ATQA") == [dump["atqa"]]
    assert f"#define MFC_SAK {dump['sak']}\n" in content
    assert f'#define MFC_SCAN_ID "{make_message_fixtures.MFC_SCAN_ID}"' in content
    assert "MFC_MISSING_SECTORS[1] = {7};" in content


def test_ntag_vectors_match_the_ntag_fixture():
    dump = json.loads((TAGS / "ntag215_blank.json").read_text())
    content = header()
    assert c_array(content, "NTAG_PAGES") == dump["pages"]
    assert c_array(content, "NTAG_UID") == [dump["uid"]]
    assert c_array(content, "NTAG_ATQA") == [dump["atqa"]]
    assert f"#define NTAG_SAK {dump['sak']}\n" in content
    assert f'#define NTAG_SCAN_ID "{make_message_fixtures.NTAG_SCAN_ID}"' in content


def test_real_vectors_match_the_real_fixture():
    dump = json.loads((REPO / "protocol" / make_tag_vectors.REAL_DUMP).read_text())
    assert dump["synthetic"] is False
    content = header()
    assert c_array(content, "REAL_BLOCKS") == dump["blocks"]
    assert c_array(content, "REAL_UID") == [dump["uid"]]
    assert c_array(content, "REAL_ATQA") == [dump["atqa"]]
    assert f"#define REAL_SAK {dump['sak']}\n" in content
    missing = ", ".join(str(s) for s in dump["missing"])
    assert f"REAL_MISSING_SECTORS[{len(dump['missing'])}] = {{{missing}}};" in content
