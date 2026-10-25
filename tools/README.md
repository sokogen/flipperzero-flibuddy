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

## Dev bridge

`bridge/` connects the Flipper app to Bambuddy over USB serial, for the
Phase 0 spike and for debugging the protocol without the Mac host:

```
uv run python -m bridge --bambuddy http://<BAMBUDDY_LAN_IP>:8000 --api-key bb_...
uv run python -m bridge --dump-dir ../protocol/fixtures/tags   # no Bambuddy: print and save scans
```

- `--port` defaults to the first `/dev/cu.usbmodemflip_*`; the API key can
  come from `$BAMBUDDY_API_KEY`.
- At start-up the bridge reads `/settings/spoolman` and refuses Spoolman
  mode (the key needs `settings:read`).
- It answers `hello`, prints each parsed tag and the `lookup` it sends, and
  performs `weigh` / `new` intents (`--core-weight`, `--catalog-id` set the
  empty spool for new items); `create_on_host` / `link_on_host` are only
  logged. A repeated intent id gets the stored `result`; failed calls are
  not stored, so a retry runs again.
- `--dump-dir` saves every scan in the `protocol/fixtures/tags` format.
  MIFARE Classic sector trailers are rebuilt from the derived Key A (the
  Flipper does not send them).

Modules: `bambu_tag.py` (pure tag parser, mirrored by the Swift one),
`bambuddy.py` (httpx client), `session.py` (framing and message handling),
`__main__.py` (CLI and serial loop).
