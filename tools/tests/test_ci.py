"""The path-filtered CI workflows and the root Makefile.

Each part of the repository has its own workflow that runs when the part,
the shared protocol contract or the workflow itself changes, and runs the
same suite as `make test` does locally.
"""

from pathlib import Path

import pytest
import yaml

REPO = Path(__file__).resolve().parents[2]
WORKFLOWS = REPO / ".github" / "workflows"


def workflow(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / f"{name}.yml").read_text(encoding="utf-8"))


def triggers(wf: dict) -> dict:
    # PyYAML reads the bare key `on` as the boolean True.
    return wf[True]


def run_lines(wf: dict) -> list[str]:
    return [
        line.strip()
        for job in wf["jobs"].values()
        for step in job["steps"]
        for line in step.get("run", "").splitlines()
        if line.strip()
    ]


def step_dirs(wf: dict) -> set[str]:
    return {
        step.get("working-directory", ".")
        for job in wf["jobs"].values()
        for step in job["steps"]
        if "run" in step
    }


@pytest.mark.parametrize(
    "name, part",
    [("flipper", "flipper/**"), ("host", "host/**"), ("tools", "tools/**")],
)
def test_workflow_is_path_filtered(name, part):
    on = triggers(workflow(name))
    for event in ("push", "pull_request"):
        paths = on[event]["paths"]
        assert part in paths
        assert "protocol/**" in paths
        assert f".github/workflows/{name}.yml" in paths


def test_tools_workflow_also_watches_the_generated_c_vectors():
    # tools/tests check that flipper/tests/vectors match their generators.
    for event in ("push", "pull_request"):
        assert "flipper/tests/vectors/**" in triggers(workflow("tools"))[event]["paths"]


def test_flipper_workflow_builds_the_fap_with_ufbt_1_5_1_and_runs_c_tests():
    wf = workflow("flipper")
    (job,) = wf["jobs"].values()
    assert job["runs-on"] == "ubuntu-latest"
    lines = run_lines(wf)
    assert "pip install ufbt" in lines
    assert "ufbt update --branch=1.5.1" in lines
    assert "ufbt" in lines
    assert any(line.startswith("make -C flipper/tests test") for line in lines)
    assert "flipper" in step_dirs(wf)
    uploads = [s for s in job["steps"] if s.get("uses", "").startswith("actions/upload-artifact")]
    assert [s["with"]["path"] for s in uploads] == ["flipper/dist/*.fap"]


def test_host_workflow_runs_swift_test_on_macos_with_the_lint_and_coverage_gates():
    wf = workflow("host")
    (job,) = wf["jobs"].values()
    assert job["runs-on"] == "macos-latest"
    lines = run_lines(wf)
    assert "swift build -Xswiftc -warnings-as-errors" in lines
    assert "swift test --enable-code-coverage" in lines
    assert any(line.startswith("uv run python swift_coverage.py") and "--min 80" in line for line in lines)
    assert step_dirs(wf) == {"host", "tools"}
    for event in ("push", "pull_request"):
        assert "tools/swift_coverage.py" in triggers(wf)[event]["paths"]


def test_tools_workflow_runs_pytest_with_uv():
    wf = workflow("tools")
    (job,) = wf["jobs"].values()
    assert job["runs-on"] == "ubuntu-latest"
    lines = run_lines(wf)
    assert "uv sync" in lines
    assert "uv run pytest --cov" in lines
    assert "uv run ruff check" in lines
    assert step_dirs(wf) == {"tools"}


def test_root_makefile_runs_all_three_suites():
    makefile = (REPO / "Makefile").read_text(encoding="utf-8")
    assert "test: test-flipper test-host test-tools" in makefile
    assert "$(MAKE) -C flipper/tests test" in makefile
    assert "cd host && swift test" in makefile
    assert "cd tools && uv run pytest" in makefile


def test_root_makefile_runs_the_linters():
    makefile = (REPO / "Makefile").read_text(encoding="utf-8")
    assert "lint: lint-flipper lint-host lint-tools" in makefile
    # The C tests already build with -Werror.
    assert "$(MAKE) -C flipper/tests test" in makefile
    assert "cd host && swift build -Xswiftc -warnings-as-errors" in makefile
    assert "cd tools && uv run ruff check" in makefile


def test_root_makefile_checks_coverage():
    makefile = (REPO / "Makefile").read_text(encoding="utf-8")
    assert "coverage: coverage-host coverage-tools" in makefile
    assert "swift test --enable-code-coverage" in makefile
    assert "cd tools && uv run pytest --cov" in makefile
