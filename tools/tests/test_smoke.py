"""Smoke test: the tool environment has its runtime dependencies."""

import importlib
import sys

import pytest


def test_python_version():
    assert sys.version_info >= (3, 13)


@pytest.mark.parametrize("module", ["serial", "httpx", "jsonschema"])
def test_dependency_importable(module):
    importlib.import_module(module)
