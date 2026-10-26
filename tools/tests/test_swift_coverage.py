import json

import pytest

import swift_coverage


def codecov(*files: tuple[str, int, int]) -> dict:
    """An llvm-cov JSON export as `swift test --enable-code-coverage` writes it."""
    return {
        "data": [
            {
                "files": [
                    {"filename": name, "summary": {"lines": {"covered": covered, "count": count}}}
                    for name, covered, count in files
                ]
            }
        ]
    }


CORE = "/repo/host/Sources/FliBuddyCore/"


def test_line_coverage_counts_only_files_under_the_prefix():
    report = codecov(
        (CORE + "A.swift", 9, 10),
        (CORE + "Session/B.swift", 1, 10),
        ("/repo/host/Sources/FliBuddyMac/App.swift", 0, 50),
        ("/repo/host/Tests/FliBuddyCoreTests/T.swift", 100, 100),
    )
    assert swift_coverage.line_coverage(report, "Sources/FliBuddyCore/") == (10, 20)


def test_line_coverage_without_matching_files_is_empty():
    assert swift_coverage.line_coverage(codecov(), "Sources/FliBuddyCore/") == (0, 0)


def write(tmp_path, report: dict):
    path = tmp_path / "FliBuddy.json"
    path.write_text(json.dumps(report), encoding="utf-8")
    return str(path)


def test_main_passes_at_the_minimum(tmp_path, capsys):
    path = write(tmp_path, codecov((CORE + "A.swift", 8, 10)))
    assert swift_coverage.main([path, "--min", "80"]) == 0
    assert "FliBuddyCore line coverage 80.0 % (8/10)" in capsys.readouterr().out


def test_main_fails_below_the_minimum(tmp_path, capsys):
    path = write(tmp_path, codecov((CORE + "A.swift", 79, 100)))
    assert swift_coverage.main([path, "--min", "80"]) == 1
    assert "below 80" in capsys.readouterr().out


def test_main_fails_when_no_file_matches(tmp_path, capsys):
    path = write(tmp_path, codecov(("/repo/other/A.swift", 1, 1)))
    assert swift_coverage.main([path]) == 1
    assert "no files" in capsys.readouterr().out


@pytest.mark.parametrize("args", [[], ["a.json", "--min", "x"]])
def test_main_rejects_bad_arguments(args):
    with pytest.raises(SystemExit):
        swift_coverage.main(args)
