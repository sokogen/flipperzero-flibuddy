#include "minitest.h"
#include "fixture.h"
#include "dump_loaders.h"

#include "screen_text.h"

#define FIXTURE_CAP 16384

static AppState app;
static SingleSlotIntentStore store;
static ProtoMessage msg;
static char fixture[FIXTURE_CAP];
static char text[SCREEN_TEXT_MAX];
static Scan scan;
static Intent intent;
static IdSeq ids;

static const ProtoMessage* fixture_message(const char* name) {
    char path[128];
    snprintf(path, sizeof(path), "fixtures/messages/%s", name);
    CHECK(fixture_read(path, fixture, sizeof(fixture)));
    CHECK(proto_decode_line(fixture, &msg) == ProtoDecodeOk);
    return &msg;
}

static void error_state(AppError error) {
    single_slot_intent_store_init(&store);
    app_state_init(&app, &store.base, 1, 1);
    app.screen = AppScreenError;
    app.error = error;
}

static void test_lines_are_joined_with_newlines(void) {
    const ProtoMessage* m = fixture_message("result_ok.json");
    size_t len = screen_lines_text(&m->result.lines, text, sizeof(text));
    CHECK_STR_EQ(text, "Saved\n484 g left");
    CHECK_EQ_INT(len, strlen(text));

    m = fixture_message("lookup_found.json");
    screen_lines_text(&m->lookup.lines, text, sizeof(text));
    CHECK_STR_EQ(text, "PLA Basic\nJade White\n484 g left of 1000\ncore 250 g");

    ProtoLines none = {0};
    CHECK_EQ_INT(screen_lines_text(&none, text, sizeof(text)), 0);
    CHECK_STR_EQ(text, "");
}

static void test_lines_are_cut_to_the_buffer(void) {
    const ProtoMessage* m = fixture_message("result_ok.json");
    char small[8];
    memset(small, 'x', sizeof(small));
    CHECK_EQ_INT(screen_lines_text(&m->result.lines, small, sizeof(small)), 7);
    CHECK_STR_EQ(small, "Saved\n4");
    CHECK_EQ_INT(screen_lines_text(&m->result.lines, small, 0), 0);
    CHECK_EQ_INT(small[0], 'S'); /* untouched */
}

static void test_done_shows_the_result_lines(void) {
    error_state(AppErrorNone);
    app.screen = AppScreenDone;
    app.result = fixture_message("result_ok.json")->result;
    screen_outcome_text(&app, text, sizeof(text));
    CHECK_STR_EQ(text, "Saved\n484 g left");

    memset(&app.result.lines, 0, sizeof(app.result.lines));
    screen_outcome_text(&app, text, sizeof(text));
    CHECK_STR_EQ(text, "Done");
}

static void test_errors_from_the_host_show_its_lines_and_error(void) {
    error_state(AppErrorLookup);
    app.lookup = fixture_message("lookup_error.json")->lookup;
    screen_outcome_text(&app, text, sizeof(text));
    CHECK_STR_EQ(text, "Bambuddy unreachable\nconnection timed out");
    memset(&app.lookup, 0, sizeof(app.lookup));
    screen_outcome_text(&app, text, sizeof(text));
    CHECK_STR_EQ(text, "Lookup failed");

    error_state(AppErrorHost);
    app.result = fixture_message("result_error.json")->result;
    screen_outcome_text(&app, text, sizeof(text));
    CHECK_STR_EQ(text, "Not saved\nspool 42 not found");
    app.result.lines.count = 0;
    screen_outcome_text(&app, text, sizeof(text));
    CHECK_STR_EQ(text, "spool 42 not found");
    app.result.error[0] = '\0';
    screen_outcome_text(&app, text, sizeof(text));
    CHECK_STR_EQ(text, "Not saved");
}

static void test_local_errors(void) {
    error_state(AppErrorReadFailed);
    screen_outcome_text(&app, text, sizeof(text));
    CHECK_STR_EQ(text, "Could not read the tag");
    error_state(AppErrorTimeout);
    screen_outcome_text(&app, text, sizeof(text));
    CHECK_STR_EQ(text, "No answer from the host in 10 s");
    error_state(AppErrorHostLost);
    screen_outcome_text(&app, text, sizeof(text));
    CHECK_STR_EQ(text, "Host disconnected");
    error_state(AppErrorSendFailed);
    screen_outcome_text(&app, text, sizeof(text));
    CHECK_STR_EQ(text, "Could not send to the host");
}

static void test_weight_mode_texts(void) {
    CHECK_STR_EQ(screen_weight_header(WeightModeGross), "Gross weight, g");
    CHECK_STR_EQ(screen_weight_header(WeightModeNet), "Net weight, g");
    CHECK_STR_EQ(screen_mode_item(WeightModeGross), "Mode: gross");
    CHECK_STR_EQ(screen_mode_item(WeightModeNet), "Mode: net");
}

static void test_intent_texts(void) {
    load_mfc(&scan.tag);
    strcpy(scan.id, "s-000012");
    id_seq_init(&ids, 'i', 3);

    CHECK(intent_new_weigh(&intent, &ids, &scan, 734, WeightModeGross));
    size_t len = screen_intent_text(&intent, text, sizeof(text));
    CHECK_STR_EQ(text, "734 g gross");
    CHECK_EQ_INT(len, strlen(text));
    CHECK(intent_new_weigh(&intent, &ids, &scan, 0, WeightModeNet));
    screen_intent_text(&intent, text, sizeof(text));
    CHECK_STR_EQ(text, "0 g net");

    CHECK(intent_new_action(&intent, &ids, &scan, IntentActionNew));
    screen_intent_text(&intent, text, sizeof(text));
    CHECK_STR_EQ(text, "New spool");
    CHECK(intent_new_action(&intent, &ids, &scan, IntentActionCreateOnHost));
    screen_intent_text(&intent, text, sizeof(text));
    CHECK_STR_EQ(text, "Create on host");
    CHECK(intent_new_action(&intent, &ids, &scan, IntentActionLinkOnHost));
    screen_intent_text(&intent, text, sizeof(text));
    CHECK_STR_EQ(text, "Link on host");

    CHECK_EQ_INT(screen_intent_text(NULL, text, sizeof(text)), 0);
    CHECK_STR_EQ(text, "");
}

static void status_state(TransportKind kind, AppBleStatus ble, bool connected) {
    single_slot_intent_store_init(&store);
    app_state_init(&app, &store.base, 1, 1);
    app.transport = kind;
    app.ble = ble;
    app.connected = connected;
}

static void test_status_line_over_usb(void) {
    status_state(TransportKindUsb, AppBleOff, false);
    CHECK_STR_EQ(screen_status_text(&app), "no host");
    status_state(TransportKindUsb, AppBleOff, true);
    CHECK_STR_EQ(screen_status_text(&app), "USB");
    /* a stale BLE status does not matter on USB */
    status_state(TransportKindUsb, AppBleAdvertising, false);
    CHECK_STR_EQ(screen_status_text(&app), "no host");
}

static void test_status_line_over_bluetooth(void) {
    status_state(TransportKindBluetooth, AppBleOff, false);
    CHECK_STR_EQ(screen_status_text(&app), "no host");
    status_state(TransportKindBluetooth, AppBleAdvertising, false);
    CHECK_STR_EQ(screen_status_text(&app), "BLE adv");
    /* a host subscribed but no hello yet */
    status_state(TransportKindBluetooth, AppBleConnected, false);
    CHECK_STR_EQ(screen_status_text(&app), "no host");
    status_state(TransportKindBluetooth, AppBleConnected, true);
    CHECK_STR_EQ(screen_status_text(&app), "BLE");
}

static void test_status_line_after_hello_over_bluetooth(void) {
    /* the host said hello: connected, whatever the last BLE status was */
    status_state(TransportKindBluetooth, AppBleAdvertising, true);
    CHECK_STR_EQ(screen_status_text(&app), "BLE");
    status_state(TransportKindBluetooth, AppBleOff, true);
    CHECK_STR_EQ(screen_status_text(&app), "BLE");
}

static void test_transport_names(void) {
    CHECK_STR_EQ(screen_transport_name(TransportKindUsb), "USB");
    CHECK_STR_EQ(screen_transport_name(TransportKindBluetooth), "Bluetooth");
}

int main(void) {
    RUN_TEST(test_lines_are_joined_with_newlines);
    RUN_TEST(test_lines_are_cut_to_the_buffer);
    RUN_TEST(test_done_shows_the_result_lines);
    RUN_TEST(test_errors_from_the_host_show_its_lines_and_error);
    RUN_TEST(test_local_errors);
    RUN_TEST(test_weight_mode_texts);
    RUN_TEST(test_intent_texts);
    RUN_TEST(test_status_line_over_usb);
    RUN_TEST(test_status_line_over_bluetooth);
    RUN_TEST(test_status_line_after_hello_over_bluetooth);
    RUN_TEST(test_transport_names);
    return MINITEST_RESULT();
}
