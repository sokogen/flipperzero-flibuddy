/* Encoding of the Flipper → host messages of protocol/PROTOCOL.md.
 *
 * Each encoder writes one compact JSON object, without the terminating
 * '\n', into `buf` and returns its length, or 0 when the input is invalid
 * or the text does not fit. The text never exceeds PROTO_LINE_MAX - 1 bytes
 * (room for the '\n') whatever `cap` is, so a receiver never drops it.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "json_writer.h"
#include "tag_dump.h"

#define PROTO_VERSION 1
#define PROTO_LINE_MAX 8192 /* bytes per line including the '\n' */
#define PROTO_ID_MAX 32

/* Whether `id` is a protocol identifier: 1-32 chars of A-Z a-z 0-9 _ . : - */
bool proto_id_valid(const char* id);

/* Writes `"t":<type>,"v":1` into an open object. */
bool proto_write_header(JsonWriter* w, const char* type);

/* Writes the tag object (as a value) in the order of PROTOCOL.md; false when
 * the dump is not valid. Shared with the intent encoder. */
bool proto_write_tag(JsonWriter* w, const TagDump* dump);

size_t proto_encode_hello(const char* app, const char* fw, char* buf, size_t cap);

size_t proto_encode_scan(const TagDump* dump, const char* scan_id, char* buf, size_t cap);
