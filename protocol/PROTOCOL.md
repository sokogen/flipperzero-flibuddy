# flipper-spoolbuddy wire protocol, version 1

The Flipper app and the host (Mac now, iPad/iPhone later) exchange
newline-delimited JSON over a byte stream: USB CDC in Phase 1, BLE serial
later. The Flipper is a thin client: it sends raw tag dumps and user
actions, the host parses tags, talks to Bambuddy and sends back display
strings.

The contract is machine-checked:

- `schema/message.schema.json`: JSON Schema (draft 2020-12) for every message.
- `fixtures/messages/*.json`: one sample per message type and action. Files
  named `invalid_*` must fail the schema; every other file must pass.
- `fixtures/tags/*.json`: tag dumps (synthetic until Phase 0 captures real
  ones). `scan_*` and `intent_*` samples are generated from them by
  `tools/fixtures/make_message_fixtures.py`.

The C (`flipper/tests`), Swift (`host/`) and Python (`tools/`) test suites
all run against these files. Changing a message means changing the schema,
the fixtures, this document and both sides in one commit.

## Framing

- One JSON object per line, UTF-8, terminated by `\n` (LF). A receiver
  accepts and strips a `\r` before the `\n`. Empty lines are ignored.
- A line, including its terminating `\n`, is at most **8192 bytes**. A
  receiver drops a longer line whole (everything up to the next `\n`) and
  keeps going. A sender never produces one; the Flipper reports an encoding
  error instead.
- Senders emit compact JSON (no whitespace between tokens) and no
  non-ASCII characters on the Flipper side. Receivers accept any valid JSON
  whitespace and any key order.
- Hex strings (UIDs, ATQA, blocks, pages) are upper-case without separators.

## Common fields

| Field | Type | Meaning |
|---|---|---|
| `t` | string | Message type: `hello`, `scan`, `lookup`, `intent`, `result`. |
| `v` | integer | Protocol version, always `1`. |

A receiver ignores a line whose `t` it does not know, and a line whose `v`
is not `1`. A line that is not valid JSON, or a known `t` with missing or
ill-typed fields, is dropped as malformed; neither side crashes or
disconnects on it. Unknown fields are not allowed by the schema; a receiver
may ignore them.

## Session

1. After the transport connects, each side sends `hello` as its first line.
2. The Flipper treats the link as **connected** once it has received a host
   `hello` within 2 s of sending its own (or of the transport coming up);
   until then its status line shows `no host` and a scan stays local.
3. Flipper → host: `scan` after each tag read.
4. Host → Flipper: `lookup` answering that `scan_id`.
5. Flipper → host: zero or more `intent`s for that scan (user actions).
6. Host → Flipper: one `result` per intent, matched by `id`.

The host may also act on a scan by itself (the owner edits the weight in the
feed); that sends nothing to the Flipper.

## Messages

### `hello` (both directions)

| Field | Type | Required | Meaning |
|---|---|---|---|
| `app` | string, ≤ 40 | yes | Sender app and version, e.g. `spoolbuddy-fap/0.1.0`, `spoolbuddy-mac/0.1.0`. |
| `fw` | string, ≤ 40 | Flipper | Flipper firmware version, e.g. `1.5.1`. |
| `os` | string, ≤ 40 | host | Host OS, e.g. `macOS 26.0`. |

Exactly one of `fw` / `os` is present.

```json
{"t":"hello","v":1,"app":"spoolbuddy-fap/0.1.0","fw":"1.5.1"}
{"t":"hello","v":1,"app":"spoolbuddy-mac/0.1.0","os":"macOS 26.0"}
```

### `scan` (Flipper → host)

| Field | Type | Required | Meaning |
|---|---|---|---|
| `scan_id` | id | yes | Unique per scan within a Flipper app run, `s-NNNNNN`. |
| `tag` | tag object | yes | The raw dump, see below. |

Tag object:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `type` | `"mfc"` \| `"ntag"` | yes | MIFARE Classic 1K or NTAG21x. |
| `uid` | hex, 4, 7 or 10 bytes | yes | Tag UID. |
| `sak` | integer 0–255 | yes | SAK from anticollision. |
| `atqa` | hex, 2 bytes | yes | ATQA as received, e.g. `0400`, `0044`. |
| `blocks` | object | `mfc` only | Block number (`"0"`–`"63"`) → 16 bytes hex. Sector trailers (3, 7, …, 63) are never sent. Blocks of missing sectors are absent. |
| `missing` | array of integers 0–15 | `mfc` only, optional | Sectors that failed authentication or reading. Omitted when all sectors were read. |
| `pages` | object | `ntag` only | Page number (`"0"`–`"230"`) → 4 bytes hex, from page 0 to the end of the tag's memory. |

The Flipper emits `blocks` / `pages` keys in ascending numeric order and tag
fields in the order of the table; `scan_mfc.json` and `scan_ntag.json` show
the exact shape.

```json
{"t":"scan","v":1,"scan_id":"s-000012","tag":{"type":"mfc","uid":"5A3C9E21","sak":8,"atqa":"0400","blocks":{"0":"5A3C9E21D9080400F600848E53F87010","1":"4130302D573100004746413030000000","2":"504C4100000000000000000000000000","…":"…"},"missing":[7]}}
{"t":"scan","v":1,"scan_id":"s-000013","tag":{"type":"ntag","uid":"04112233445566","sak":0,"atqa":"0044","pages":{"0":"041122BF","1":"33445566","…":"…"}}}
```

A full Bambu dump (48 data blocks) is about 2 KB, a full NTAG216 dump
(231 pages) about 4 KB, both well under the line limit.

### `lookup` (host → Flipper)

| Field | Type | Required | Meaning |
|---|---|---|---|
| `scan_id` | id | yes | The scan this answers. |
| `status` | `"found"` \| `"unknown"` \| `"error"` | yes | Spool found in Bambuddy, not found, or lookup failed. |
| `spool_id` | integer ≥ 1 | when `found` | Bambuddy spool id. |
| `prefill` | boolean | optional | `unknown` only: the tag gave enough data (at least `material`) for the Flipper to offer **New**. Absent means `false`. |
| `lines` | array of ≤ 4 strings, each ≤ 40 chars | yes | Display text, rendered verbatim. May be empty. |
| `defaults` | object | optional | Grams for the Enter weight screen: `gross` (last gross weight), `label` (filament weight per label), `core` (empty spool weight); each an integer 0–9999, each optional. |
| `error` | string, ≤ 200 | when `error` | Technical reason, for logs; `lines` carries what the user sees. |

The Flipper pre-fills the weight with `defaults.gross`, falling back to
`defaults.label + defaults.core`.

```json
{"t":"lookup","v":1,"scan_id":"s-000012","status":"found","spool_id":42,"lines":["PLA Basic","Jade White","484 g left of 1000","core 250 g"],"defaults":{"gross":734,"label":1000,"core":250}}
{"t":"lookup","v":1,"scan_id":"s-000012","status":"unknown","prefill":true,"lines":["PLA Basic","#FFFFFFFF","label 1000 g"],"defaults":{"label":1000,"core":250}}
{"t":"lookup","v":1,"scan_id":"s-000012","status":"error","lines":["Bambuddy unreachable"],"error":"connection timed out"}
```

### `intent` (Flipper → host)

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | id | yes | Unique per intent, `i-NNNNNN`. The host's idempotency key. |
| `scan_id` | id | yes | The scan the action refers to. |
| `action` | enum | yes | `weigh`: record a weight. `new`: create a full spool from the tag (offered only when `lookup.prefill` is true). `create_on_host`: flag the feed row so the owner creates the spool on the host. `link_on_host`: flag the row so the owner links the tag to an existing spool on the host. |
| `grams` | integer 0–9999 | `weigh` | Weight typed on the Flipper. |
| `mode` | `"net"` \| `"gross"` | `weigh` | `gross`: spool on the scale as is. `net`: filament only; the host adds the spool's core weight. |
| `tag` | tag object | yes | The same object as in the `scan`, so an intent is self-contained (a future offline queue replays intents without their scans). |

```json
{"t":"intent","v":1,"id":"i-000003","scan_id":"s-000012","action":"weigh","grams":734,"mode":"gross","tag":{"type":"mfc","uid":"5A3C9E21","…":"…"}}
{"t":"intent","v":1,"id":"i-000004","scan_id":"s-000012","action":"new","tag":{"…":"…"}}
```

### `result` (host → Flipper)

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | id | yes | The intent this answers. |
| `ok` | boolean | yes | Whether the action succeeded. |
| `lines` | array of ≤ 4 strings, each ≤ 40 chars | yes | Display text for the Done / Error screen. |
| `error` | string, ≤ 200 | when `ok` is false | Technical reason, for logs. |

```json
{"t":"result","v":1,"id":"i-000003","ok":true,"lines":["Saved","484 g left"]}
{"t":"result","v":1,"id":"i-000003","ok":false,"lines":["Not saved"],"error":"spool 42 not found"}
```

## Rules

- **Idempotency.** The host remembers every intent id it has completed in
  the session and answers a repeated id with the stored `result` without
  calling Bambuddy again.
- **Matching.** The Flipper applies a `lookup` only if its `scan_id` is the
  scan on screen, and a `result` only if its `id` is the intent in flight;
  anything else is ignored.
- **Timeouts.** The Flipper waits 10 s for a `result`, then shows an error.
  The host does not time out on the Flipper.
- **Wording.** The host owns all user-visible text. The Flipper renders
  `lines` verbatim and never parses them.
- **New items.** The Flipper never sends `new` without `prefill: true`, and
  the host refuses to create a spool without `material`.

## Identifiers

`scan_id` and `id` are strings of 1–32 characters from `A–Z a–z 0–9 _ . : -`.
The Flipper uses `s-` / `i-` followed by a zero-padded counter.
