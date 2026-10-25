#include "minitest.h"
#include "fixture.h"

#include "proto_decode.h"

#define FIXTURE_CAP 16384

static ProtoMessage msg;
static char text[FIXTURE_CAP];
static char prefix[FIXTURE_CAP];

static ProtoDecodeStatus decode_fixture(const char* name, bool compact) {
    char path[128];
    snprintf(path, sizeof(path), "fixtures/messages/%s", name);
    bool loaded = compact ? fixture_read_compact(path, text, sizeof(text)) :
                            fixture_read(path, text, sizeof(text));
    CHECK(loaded);
    if(!loaded) return ProtoDecodeMalformed;
    return proto_decode_line(text, &msg);
}

static ProtoDecodeStatus decode(const char* line) {
    return proto_decode_line(line, &msg);
}

static void check_lookup_found(void) {
    CHECK(msg.type == ProtoMsgLookup);
    CHECK_STR_EQ(msg.lookup.scan_id, "s-000012");
    CHECK(msg.lookup.status == ProtoLookupFound);
    CHECK_EQ_INT(msg.lookup.spool_id, 42);
    CHECK(!msg.lookup.prefill);
    CHECK_EQ_INT(msg.lookup.lines.count, 4);
    CHECK_STR_EQ(msg.lookup.lines.line[0], "PLA Basic");
    CHECK_STR_EQ(msg.lookup.lines.line[1], "Jade White");
    CHECK_STR_EQ(msg.lookup.lines.line[2], "484 g left of 1000");
    CHECK_STR_EQ(msg.lookup.lines.line[3], "core 250 g");
    CHECK(msg.lookup.defaults.has_gross);
    CHECK(msg.lookup.defaults.has_label);
    CHECK(msg.lookup.defaults.has_core);
    CHECK_EQ_INT(msg.lookup.defaults.gross, 734);
    CHECK_EQ_INT(msg.lookup.defaults.label, 1000);
    CHECK_EQ_INT(msg.lookup.defaults.core, 250);
    CHECK_STR_EQ(msg.lookup.error, "");
}

static void test_lookup_found_fixture(void) {
    CHECK(decode_fixture("lookup_found.json", false) == ProtoDecodeOk);
    check_lookup_found();
    CHECK(decode_fixture("lookup_found.json", true) == ProtoDecodeOk);
    check_lookup_found();
}

static void test_lookup_unknown_fixture(void) {
    CHECK(decode_fixture("lookup_unknown.json", true) == ProtoDecodeOk);
    CHECK(msg.type == ProtoMsgLookup);
    CHECK_STR_EQ(msg.lookup.scan_id, "s-000012");
    CHECK(msg.lookup.status == ProtoLookupUnknown);
    CHECK_EQ_INT(msg.lookup.spool_id, 0);
    CHECK(msg.lookup.prefill);
    CHECK_EQ_INT(msg.lookup.lines.count, 3);
    CHECK_STR_EQ(msg.lookup.lines.line[0], "PLA Basic");
    CHECK_STR_EQ(msg.lookup.lines.line[1], "#FFFFFFFF");
    CHECK_STR_EQ(msg.lookup.lines.line[2], "label 1000 g");
    CHECK_STR_EQ(msg.lookup.lines.line[3], "");
    CHECK(!msg.lookup.defaults.has_gross);
    CHECK(msg.lookup.defaults.has_label);
    CHECK(msg.lookup.defaults.has_core);
    CHECK_EQ_INT(msg.lookup.defaults.label, 1000);
    CHECK_EQ_INT(msg.lookup.defaults.core, 250);
}

static void test_lookup_error_fixture(void) {
    CHECK(decode_fixture("lookup_error.json", false) == ProtoDecodeOk);
    CHECK(msg.type == ProtoMsgLookup);
    CHECK(msg.lookup.status == ProtoLookupError);
    CHECK_EQ_INT(msg.lookup.lines.count, 1);
    CHECK_STR_EQ(msg.lookup.lines.line[0], "Bambuddy unreachable");
    CHECK_STR_EQ(msg.lookup.error, "connection timed out");
    CHECK(!msg.lookup.defaults.has_gross);
    CHECK(!msg.lookup.defaults.has_label);
    CHECK(!msg.lookup.defaults.has_core);
}

static void test_result_ok_fixture(void) {
    CHECK(decode_fixture("result_ok.json", false) == ProtoDecodeOk);
    CHECK(msg.type == ProtoMsgResult);
    CHECK_STR_EQ(msg.result.id, "i-000003");
    CHECK(msg.result.ok);
    CHECK_EQ_INT(msg.result.lines.count, 2);
    CHECK_STR_EQ(msg.result.lines.line[0], "Saved");
    CHECK_STR_EQ(msg.result.lines.line[1], "484 g left");
    CHECK_STR_EQ(msg.result.error, "");
}

static void test_result_error_fixture(void) {
    CHECK(decode_fixture("result_error.json", true) == ProtoDecodeOk);
    CHECK(msg.type == ProtoMsgResult);
    CHECK_STR_EQ(msg.result.id, "i-000003");
    CHECK(!msg.result.ok);
    CHECK_EQ_INT(msg.result.lines.count, 1);
    CHECK_STR_EQ(msg.result.lines.line[0], "Not saved");
    CHECK_STR_EQ(msg.result.error, "spool 42 not found");
}

static void test_hello_fixtures(void) {
    CHECK(decode_fixture("hello_host.json", false) == ProtoDecodeOk);
    CHECK(msg.type == ProtoMsgHello);
    CHECK_STR_EQ(msg.hello.app, "spoolbuddy-mac/0.1.0");
    CHECK_STR_EQ(msg.hello.os, "macOS 26.0");
    CHECK_STR_EQ(msg.hello.fw, "");

    CHECK(decode_fixture("hello_flipper.json", true) == ProtoDecodeOk);
    CHECK(msg.type == ProtoMsgHello);
    CHECK_STR_EQ(msg.hello.app, "spoolbuddy-fap/0.1.0");
    CHECK_STR_EQ(msg.hello.fw, "1.5.1");
    CHECK_STR_EQ(msg.hello.os, "");
}

static void test_flipper_bound_messages_are_ignored(void) {
    /* scan and intent travel Flipper -> host; the Flipper ignores them. */
    CHECK(decode_fixture("scan_mfc.json", true) == ProtoDecodeIgnored);
    CHECK(msg.type == ProtoMsgNone);
    CHECK(decode_fixture("intent_weigh.json", true) == ProtoDecodeIgnored);
    CHECK(msg.type == ProtoMsgNone);
}

static void test_invalid_fixtures(void) {
    CHECK(decode_fixture("invalid_missing_t.json", false) == ProtoDecodeMalformed);
    CHECK(msg.type == ProtoMsgNone);
}

static void test_unknown_type_or_version_is_ignored(void) {
    CHECK(decode("{\"t\":\"ping\",\"v\":1}") == ProtoDecodeIgnored);
    CHECK(decode("{\"t\":\"ping\",\"v\":1,\"anything\":[{\"x\":null}]}") == ProtoDecodeIgnored);
    CHECK(decode("{\"v\":2,\"t\":\"result\",\"id\":\"i-1\",\"ok\":true,\"lines\":[]}") ==
          ProtoDecodeIgnored);
    CHECK(msg.type == ProtoMsgNone);
    /* An unknown type is still dropped as malformed when it is not JSON. */
    CHECK(decode("{\"t\":\"ping\",\"v\":1,") == ProtoDecodeMalformed);
}

static void test_key_order_and_unknown_fields(void) {
    CHECK(decode("{\"lines\":[\"x\"],\"extra\":{\"a\":[1,2.5e3,null]},\"ok\":true,"
                 "\"id\":\"i-9\",\"v\":1,\"t\":\"result\"}") == ProtoDecodeOk);
    CHECK(msg.type == ProtoMsgResult);
    CHECK_STR_EQ(msg.result.id, "i-9");
    CHECK(msg.result.ok);
    CHECK_EQ_INT(msg.result.lines.count, 1);
    /* A 32-character id is the longest allowed. */
    CHECK(decode("{\"t\":\"result\",\"v\":1,\"id\":\"i-123456789012345678901234567890\","
                 "\"ok\":true,\"lines\":[]}") == ProtoDecodeOk);
    CHECK_STR_EQ(msg.result.id, "i-123456789012345678901234567890");
    CHECK(decode("{\"t\":\"lookup\",\"v\":1,\"scan_id\":\"s-1\",\"status\":\"unknown\","
                 "\"lines\":[],\"defaults\":{\"core\":0,\"tare\":5}}") == ProtoDecodeOk);
    CHECK(msg.lookup.defaults.has_core);
    CHECK_EQ_INT(msg.lookup.defaults.core, 0);
    CHECK_EQ_INT(msg.lookup.lines.count, 0);
}

static void test_line_length_cap(void) {
    /* 40 chars fit, 41 do not. */
    CHECK(decode("{\"t\":\"result\",\"v\":1,\"id\":\"i-1\",\"ok\":true,"
                 "\"lines\":[\"0123456789012345678901234567890123456789\"]}") ==
          ProtoDecodeOk);
    CHECK_STR_EQ(msg.result.lines.line[0], "0123456789012345678901234567890123456789");
    CHECK(decode("{\"t\":\"result\",\"v\":1,\"id\":\"i-1\",\"ok\":true,"
                 "\"lines\":[\"01234567890123456789012345678901234567890\"]}") ==
          ProtoDecodeMalformed);
    CHECK(msg.type == ProtoMsgNone);
    /* Non-ASCII renders as '?', one per character. */
    CHECK(decode("{\"t\":\"result\",\"v\":1,\"id\":\"i-1\",\"ok\":true,"
                 "\"lines\":[\"220\xC2\xB0\x43 \\\"hot\\\"\"]}") == ProtoDecodeOk);
    CHECK_STR_EQ(msg.result.lines.line[0], "220?C \"hot\"");
}

static void test_lines_count_cap(void) {
    CHECK(decode("{\"t\":\"result\",\"v\":1,\"id\":\"i-1\",\"ok\":true,"
                 "\"lines\":[\"a\",\"b\",\"c\",\"d\"]}") == ProtoDecodeOk);
    CHECK_EQ_INT(msg.result.lines.count, 4);
    CHECK(decode("{\"t\":\"result\",\"v\":1,\"id\":\"i-1\",\"ok\":true,"
                 "\"lines\":[\"a\",\"b\",\"c\",\"d\",\"e\"]}") == ProtoDecodeMalformed);
}

static void test_error_length_cap(void) {
    char line[512];
    char error[202];
    memset(error, 'e', 200);
    error[200] = '\0';
    snprintf(line, sizeof(line),
             "{\"t\":\"result\",\"v\":1,\"id\":\"i-1\",\"ok\":false,\"lines\":[],\"error\":\"%s\"}",
             error);
    CHECK(decode(line) == ProtoDecodeOk);
    CHECK_STR_EQ(msg.result.error, error);
    error[200] = 'e';
    error[201] = '\0';
    snprintf(line, sizeof(line),
             "{\"t\":\"result\",\"v\":1,\"id\":\"i-1\",\"ok\":false,\"lines\":[],\"error\":\"%s\"}",
             error);
    CHECK(decode(line) == ProtoDecodeMalformed);
}

static void test_malformed_lines(void) {
    static const char* const lines[] = {
        "",
        "   ",
        "not json",
        "[]",
        "\"lookup\"",
        "{\"t\":\"result\",\"v\":1,\"id\":\"i-1\",\"ok\":true,\"lines\":[]} x",
        "{\"t\":\"result\",\"v\":1,\"id\":\"i-1\",\"ok\":true,\"lines\":[]}{}",
        /* header */
        "{\"v\":1}",
        "{\"t\":1,\"v\":1}",
        "{\"t\":\"result\"}",
        "{\"t\":\"result\",\"v\":\"1\",\"id\":\"i-1\",\"ok\":true,\"lines\":[]}",
        "{\"t\":\"result\",\"v\":1.0,\"id\":\"i-1\",\"ok\":true,\"lines\":[]}",
        /* result */
        "{\"t\":\"result\",\"v\":1,\"ok\":true,\"lines\":[]}",
        "{\"t\":\"result\",\"v\":1,\"id\":\"i 1\",\"ok\":true,\"lines\":[]}",
        "{\"t\":\"result\",\"v\":1,\"id\":\"\",\"ok\":true,\"lines\":[]}",
        /* 33-character id */
        "{\"t\":\"result\",\"v\":1,\"id\":\"i-1234567890123456789012345678901\",\"ok\":true,"
        "\"lines\":[]}",
        "{\"t\":\"result\",\"v\":1,\"id\":\"i-1\",\"lines\":[]}",
        "{\"t\":\"result\",\"v\":1,\"id\":\"i-1\",\"ok\":1,\"lines\":[]}",
        "{\"t\":\"result\",\"v\":1,\"id\":\"i-1\",\"ok\":true}",
        "{\"t\":\"result\",\"v\":1,\"id\":\"i-1\",\"ok\":true,\"lines\":\"Saved\"}",
        "{\"t\":\"result\",\"v\":1,\"id\":\"i-1\",\"ok\":true,\"lines\":[1]}",
        "{\"t\":\"result\",\"v\":1,\"id\":\"i-1\",\"ok\":true,\"lines\":[null]}",
        "{\"t\":\"result\",\"v\":1,\"id\":\"i-1\",\"ok\":false,\"lines\":[]}",
        "{\"t\":\"result\",\"v\":1,\"id\":\"i-1\",\"ok\":false,\"lines\":[],\"error\":\"\"}",
        "{\"t\":\"result\",\"v\":1,\"id\":\"i-1\",\"ok\":true,\"lines\":[],\"error\":7}",
        /* lookup */
        "{\"t\":\"lookup\",\"v\":1,\"status\":\"unknown\",\"lines\":[]}",
        "{\"t\":\"lookup\",\"v\":1,\"scan_id\":\"s-1\",\"lines\":[]}",
        "{\"t\":\"lookup\",\"v\":1,\"scan_id\":\"s-1\",\"status\":\"lost\",\"lines\":[]}",
        "{\"t\":\"lookup\",\"v\":1,\"scan_id\":\"s-1\",\"status\":\"unknown\"}",
        "{\"t\":\"lookup\",\"v\":1,\"scan_id\":\"s-1\",\"status\":\"found\",\"lines\":[]}",
        "{\"t\":\"lookup\",\"v\":1,\"scan_id\":\"s-1\",\"status\":\"found\",\"spool_id\":0,"
        "\"lines\":[]}",
        "{\"t\":\"lookup\",\"v\":1,\"scan_id\":\"s-1\",\"status\":\"found\",\"spool_id\":\"42\","
        "\"lines\":[]}",
        "{\"t\":\"lookup\",\"v\":1,\"scan_id\":\"s-1\",\"status\":\"found\","
        "\"spool_id\":2147483648,\"lines\":[]}",
        "{\"t\":\"lookup\",\"v\":1,\"scan_id\":\"s-1\",\"status\":\"error\",\"lines\":[]}",
        "{\"t\":\"lookup\",\"v\":1,\"scan_id\":\"s-1\",\"status\":\"unknown\",\"prefill\":1,"
        "\"lines\":[]}",
        "{\"t\":\"lookup\",\"v\":1,\"scan_id\":\"s-1\",\"status\":\"unknown\",\"lines\":[],"
        "\"defaults\":[]}",
        "{\"t\":\"lookup\",\"v\":1,\"scan_id\":\"s-1\",\"status\":\"unknown\",\"lines\":[],"
        "\"defaults\":{\"gross\":10000}}",
        "{\"t\":\"lookup\",\"v\":1,\"scan_id\":\"s-1\",\"status\":\"unknown\",\"lines\":[],"
        "\"defaults\":{\"core\":-1}}",
        "{\"t\":\"lookup\",\"v\":1,\"scan_id\":\"s-1\",\"status\":\"unknown\",\"lines\":[],"
        "\"defaults\":{\"label\":\"1000\"}}",
        /* hello */
        "{\"t\":\"hello\",\"v\":1,\"os\":\"macOS\"}",
        "{\"t\":\"hello\",\"v\":1,\"app\":\"\",\"os\":\"macOS\"}",
        "{\"t\":\"hello\",\"v\":1,\"app\":\"mac\"}",
        "{\"t\":\"hello\",\"v\":1,\"app\":\"mac\",\"os\":\"macOS\",\"fw\":\"1.5.1\"}",
        "{\"t\":\"hello\",\"v\":1,\"app\":\"mac\",\"os\":\"\"}",
        "{\"t\":\"hello\",\"v\":1,\"app\":\"mac\","
        "\"os\":\"01234567890123456789012345678901234567890\"}",
    };
    for(size_t i = 0; i < sizeof(lines) / sizeof(lines[0]); i++) {
        ProtoDecodeStatus status = decode(lines[i]);
        if(status != ProtoDecodeMalformed)
            MINITEST_FAIL("line %zu decoded as %d, expected malformed: %s", i, status, lines[i]);
        minitest_checks++;
        CHECK(msg.type == ProtoMsgNone);
    }
}

static void test_message_is_cleared_between_decodes(void) {
    CHECK(decode_fixture("lookup_found.json", true) == ProtoDecodeOk);
    CHECK(decode("{\"t\":\"lookup\",\"v\":1,\"scan_id\":\"s-2\",\"status\":\"unknown\","
                 "\"lines\":[\"x\"]}") == ProtoDecodeOk);
    CHECK_EQ_INT(msg.lookup.spool_id, 0);
    CHECK(!msg.lookup.defaults.has_gross);
    CHECK_STR_EQ(msg.lookup.lines.line[1], "");
}

/* No truncation of a valid line decodes, and none crashes (ASan/UBSan). */
static void test_every_prefix_is_malformed(void) {
    static const char* const names[] = {
        "lookup_found.json",
        "lookup_unknown.json",
        "lookup_error.json",
        "result_ok.json",
        "result_error.json",
        "hello_host.json",
    };
    for(size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        char path[128];
        snprintf(path, sizeof(path), "fixtures/messages/%s", names[i]);
        CHECK(fixture_read_compact(path, text, sizeof(text)));
        size_t len = strlen(text);
        bool all_malformed = true;
        for(size_t n = 0; n < len; n++) {
            memcpy(prefix, text, n);
            prefix[n] = '\0';
            if(proto_decode_line(prefix, &msg) != ProtoDecodeMalformed) {
                MINITEST_FAIL("%s: prefix of %zu bytes did not fail", names[i], n);
                all_malformed = false;
            }
        }
        CHECK(all_malformed);
        CHECK(proto_decode_line(text, &msg) == ProtoDecodeOk);
    }
}

int main(void) {
    RUN_TEST(test_lookup_found_fixture);
    RUN_TEST(test_lookup_unknown_fixture);
    RUN_TEST(test_lookup_error_fixture);
    RUN_TEST(test_result_ok_fixture);
    RUN_TEST(test_result_error_fixture);
    RUN_TEST(test_hello_fixtures);
    RUN_TEST(test_flipper_bound_messages_are_ignored);
    RUN_TEST(test_invalid_fixtures);
    RUN_TEST(test_unknown_type_or_version_is_ignored);
    RUN_TEST(test_key_order_and_unknown_fields);
    RUN_TEST(test_line_length_cap);
    RUN_TEST(test_lines_count_cap);
    RUN_TEST(test_error_length_cap);
    RUN_TEST(test_malformed_lines);
    RUN_TEST(test_message_is_cleared_between_decodes);
    RUN_TEST(test_every_prefix_is_malformed);
    return MINITEST_RESULT();
}
