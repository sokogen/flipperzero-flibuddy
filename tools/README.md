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

`uv run python -m fixtures.make_key_vectors` writes the crypto known-answer
vectors (SHA-256, HMAC RFC 4231, HKDF RFC 5869, Bambu keys for two UIDs) to
`flipper/tests/vectors/bambu_keys.h`; `tests/test_bambu_keys.py` checks the
same tables and fails when the header is stale.

`uv run python -m fixtures.make_tag_vectors` (after the generators above)
writes the tag dump fixtures as C arrays to `flipper/tests/vectors/tag_dumps.h`
for the C `scan` encoder test; `tests/test_tag_vectors.py` fails when it is
stale.

`tests/test_fixtures.py` fails when a committed fixture differs from what
its generator produces.
