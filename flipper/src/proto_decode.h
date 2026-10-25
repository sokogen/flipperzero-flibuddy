/* Decoding of the host → Flipper messages of protocol/PROTOCOL.md.
 *
 * proto_decode_line() takes one line (without its '\n'; surrounding JSON
 * whitespace and a trailing '\r' are fine) and fills a ProtoMessage:
 *
 *   ProtoDecodeOk         a valid hello, lookup or result
 *   ProtoDecodeIgnored    valid JSON whose `t` the Flipper does not consume
 *                         (unknown, scan, intent) or whose `v` is not 1
 *   ProtoDecodeMalformed  not JSON, or a known `t` with missing, ill-typed
 *                         or out-of-range fields (per the schema), too many
 *                         or too long `lines`
 *
 * Fields may come in any order; unknown fields are skipped. Strings are
 * ASCII as the Flipper renders them (see json_reader.h). Unless the status
 * is ProtoDecodeOk the message is left zeroed with type ProtoMsgNone.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "proto_encode.h"

#define PROTO_LINES_MAX 4
#define PROTO_LINE_CHARS 40
#define PROTO_ERROR_MAX 200
#define PROTO_HELLO_FIELD_MAX 40
#define PROTO_GRAMS_MAX 9999

typedef enum {
    ProtoDecodeOk,
    ProtoDecodeIgnored,
    ProtoDecodeMalformed,
} ProtoDecodeStatus;

typedef enum {
    ProtoMsgNone,
    ProtoMsgHello,
    ProtoMsgLookup,
    ProtoMsgResult,
} ProtoMsgType;

typedef struct {
    uint8_t count;
    char line[PROTO_LINES_MAX][PROTO_LINE_CHARS + 1];
} ProtoLines;

typedef struct {
    char app[PROTO_HELLO_FIELD_MAX + 1];
    char fw[PROTO_HELLO_FIELD_MAX + 1]; /* "" unless sent by a Flipper */
    char os[PROTO_HELLO_FIELD_MAX + 1]; /* "" unless sent by a host */
} ProtoHello;

typedef enum {
    ProtoLookupFound,
    ProtoLookupUnknown,
    ProtoLookupError,
} ProtoLookupStatus;

typedef struct {
    bool has_gross;
    bool has_label;
    bool has_core;
    uint16_t gross;
    uint16_t label;
    uint16_t core;
} ProtoDefaults;

typedef struct {
    char scan_id[PROTO_ID_MAX + 1];
    ProtoLookupStatus status;
    int32_t spool_id; /* >= 1 when found, 0 otherwise */
    bool prefill;
    ProtoLines lines;
    ProtoDefaults defaults;
    char error[PROTO_ERROR_MAX + 1]; /* "" when absent */
} ProtoLookup;

typedef struct {
    char id[PROTO_ID_MAX + 1];
    bool ok;
    ProtoLines lines;
    char error[PROTO_ERROR_MAX + 1]; /* "" when absent */
} ProtoResult;

typedef struct {
    ProtoMsgType type;
    union {
        ProtoHello hello;
        ProtoLookup lookup;
        ProtoResult result;
    };
} ProtoMessage;

ProtoDecodeStatus proto_decode_line(const char* line, ProtoMessage* msg);
