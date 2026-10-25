# tools

Python dev bridge (Phase 0 spike, kept as a debugging tool) and fixture
generators. Run the tests with `uv run pytest`.

Fixture generators write into `protocol/fixtures/`; run them from this
directory, tag dumps first:

```
uv run python -m fixtures.make_bambu_dump
uv run python -m fixtures.make_ntag_dump
uv run python -m fixtures.make_message_fixtures
```

`tests/test_fixtures.py` fails when a committed fixture differs from what
its generator produces.
