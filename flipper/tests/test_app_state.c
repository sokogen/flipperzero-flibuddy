#include "minitest.h"
#include "fixture.h"
#include "dump_loaders.h"

#include "app_state.h"
#include "proto_decode.h"

#define FIXTURE_CAP 16384

static AppState app;
static SingleSlotIntentStore store;
static TagDump mfc;
static TagDump ntag;
static ProtoMessage msg;
static char text[FIXTURE_CAP];

static AppEffect send(AppEventType type) {
    AppEvent e = {.type = type};
    return app_reduce(&app, &e);
}

static AppEffect send_tag(const TagDump* tag) {
    AppEvent e = {.type = AppEventTagRead, .tag = tag};
    return app_reduce(&app, &e);
}

static AppEffect send_lookup(const ProtoLookup* lookup) {
    AppEvent e = {.type = AppEventLookupReceived, .lookup = lookup};
    return app_reduce(&app, &e);
}

static AppEffect send_result(const ProtoResult* result) {
    AppEvent e = {.type = AppEventResultReceived, .result = result};
    return app_reduce(&app, &e);
}

static AppEffect send_weight_at(uint16_t grams, uint32_t now_ms) {
    AppEvent e = {.type = AppEventWeightEntered, .now_ms = now_ms, .grams = grams};
    return app_reduce(&app, &e);
}

static AppEffect send_weight(uint16_t grams) {
    return send_weight_at(grams, 0);
}

static AppEffect send_at(AppEventType type, uint32_t now_ms) {
    AppEvent e = {.type = type, .now_ms = now_ms};
    return app_reduce(&app, &e);
}

static ProtoLookup* fixture_lookup(const char* name) {
    char path[128];
    snprintf(path, sizeof(path), "fixtures/messages/%s", name);
    CHECK(fixture_read(path, text, sizeof(text)));
    CHECK(proto_decode_line(text, &msg) == ProtoDecodeOk);
    CHECK(msg.type == ProtoMsgLookup);
    return &msg.lookup;
}

static ProtoLookup lookup_with(ProtoLookupStatus status, bool prefill) {
    ProtoLookup l;
    memset(&l, 0, sizeof(l));
    strcpy(l.scan_id, "s-000012");
    l.status = status;
    l.prefill = prefill;
    if(status == ProtoLookupFound) l.spool_id = 7;
    return l;
}

static ProtoResult result_for(const char* id, bool ok) {
    ProtoResult r;
    memset(&r, 0, sizeof(r));
    strcpy(r.id, id);
    r.ok = ok;
    r.lines.count = 1;
    strcpy(r.lines.line[0], ok ? "Saved" : "Not saved");
    if(!ok) strcpy(r.error, "spool 42 not found");
    return r;
}

/* Fresh app with a host connected; the next scan id is s-000012 and the
 * next intent id i-000003, as in the fixtures. */
static void setup(void) {
    load_mfc(&mfc);
    load_ntag(&ntag);
    single_slot_intent_store_init(&store);
    app_state_init(&app, &store.base, 12, 3);
    send(AppEventHostConnected);
}

/* Idle → Reading → WaitingLookup with the MFC fixture tag. */
static void scan_mfc(void) {
    CHECK(send(AppEventTagDetected) == AppEffectNone);
    CHECK(app.screen == AppScreenReading);
    CHECK(send_tag(&mfc) == AppEffectSendScan);
    CHECK(app.screen == AppScreenWaitingLookup);
}

static void test_init_starts_idle_without_host(void) {
    single_slot_intent_store_init(&store);
    app_state_init(&app, &store.base, 1, 1);
    CHECK(app.screen == AppScreenIdle);
    CHECK(!app.connected);
    CHECK(app.mode == WeightModeGross);
    CHECK(send(AppEventHostConnected) == AppEffectNone);
    CHECK(app.connected);
    CHECK(app.screen == AppScreenIdle);
    CHECK(send(AppEventHostLost) == AppEffectNone);
    CHECK(!app.connected);
}

static void test_scan_gets_a_new_id_and_a_copy_of_the_tag(void) {
    setup();
    scan_mfc();
    CHECK_STR_EQ(app.scan.id, "s-000012");
    CHECK_MEM_EQ(&app.scan.tag, &mfc, sizeof(mfc));
    CHECK(send(AppEventBack) == AppEffectNone);
    CHECK(app.screen == AppScreenIdle);
    send(AppEventTagDetected);
    send_tag(&ntag);
    CHECK_STR_EQ(app.scan.id, "s-000013");
}

static void test_found_weigh_done_back_to_idle(void) {
    setup();
    scan_mfc();
    CHECK(send_lookup(fixture_lookup("lookup_found.json")) == AppEffectNone);
    CHECK(app.screen == AppScreenResult);
    CHECK(app.result_kind == AppResultFound);
    CHECK_EQ_INT(app.lookup.spool_id, 42);
    CHECK_STR_EQ(app.lookup.lines.line[0], "PLA Basic");

    CHECK(send(AppEventMenuWeigh) == AppEffectNone);
    CHECK(app.screen == AppScreenEnterWeight);
    CHECK_EQ_INT(app.weight_default, 734);

    CHECK(send_weight(734) == AppEffectSendIntent);
    CHECK(app.screen == AppScreenWaitingResult);
    const Intent* in_flight = intent_store_current(&store.base);
    CHECK(in_flight != NULL);
    if(in_flight) {
        CHECK_STR_EQ(in_flight->id, "i-000003");
        CHECK_STR_EQ(in_flight->scan_id, "s-000012");
        CHECK(in_flight->action == IntentActionWeigh);
        CHECK_EQ_INT(in_flight->grams, 734);
        CHECK(in_flight->mode == WeightModeGross);
        CHECK_MEM_EQ(&in_flight->tag, &mfc, sizeof(mfc));
    }

    ProtoResult ok = result_for("i-000003", true);
    CHECK(send_result(&ok) == AppEffectNone);
    CHECK(app.screen == AppScreenDone);
    CHECK_STR_EQ(app.result.lines.line[0], "Saved");
    CHECK(intent_store_current(&store.base) == NULL);
    CHECK(send(AppEventBack) == AppEffectNone);
    CHECK(app.screen == AppScreenIdle);
}

static void test_mismatched_result_is_ignored(void) {
    setup();
    scan_mfc();
    send_lookup(fixture_lookup("lookup_found.json"));
    send(AppEventMenuWeigh);
    send_weight(500);
    ProtoResult stale = result_for("i-000002", true);
    CHECK(send_result(&stale) == AppEffectNone);
    CHECK(app.screen == AppScreenWaitingResult);
    CHECK(intent_store_current(&store.base) != NULL);
    ProtoResult failed = result_for("i-000003", false);
    send_result(&failed);
    CHECK(app.screen == AppScreenError);
    CHECK(app.error == AppErrorHost);
    CHECK_STR_EQ(app.result.lines.line[0], "Not saved");
    CHECK_STR_EQ(app.result.error, "spool 42 not found");
    CHECK(send(AppEventBack) == AppEffectNone);
    CHECK(app.screen == AppScreenIdle);
}

static void test_results_outside_waiting_are_ignored(void) {
    setup();
    ProtoResult r = result_for("i-000003", true);
    CHECK(send_result(&r) == AppEffectNone);
    CHECK(app.screen == AppScreenIdle);
    scan_mfc();
    CHECK(send_result(&r) == AppEffectNone);
    CHECK(app.screen == AppScreenWaitingLookup);
}

static void test_lookup_for_another_scan_is_ignored(void) {
    setup();
    scan_mfc();
    ProtoLookup other = lookup_with(ProtoLookupFound, false);
    strcpy(other.scan_id, "s-000011");
    CHECK(send_lookup(&other) == AppEffectNone);
    CHECK(app.screen == AppScreenWaitingLookup);
    /* A lookup outside WaitingLookup is ignored too. */
    send(AppEventBack);
    ProtoLookup late = lookup_with(ProtoLookupFound, false);
    CHECK(send_lookup(&late) == AppEffectNone);
    CHECK(app.screen == AppScreenIdle);
}

static void test_unknown_with_prefill_offers_new(void) {
    setup();
    scan_mfc();
    send_lookup(fixture_lookup("lookup_unknown.json"));
    CHECK(app.screen == AppScreenResult);
    CHECK(app.result_kind == AppResultUnknownPrefill);
    CHECK(send(AppEventMenuWeigh) == AppEffectNone); /* not offered */
    CHECK(send(AppEventMenuCreateOnHost) == AppEffectNone); /* not offered */
    CHECK(app.screen == AppScreenResult);
    CHECK(intent_store_current(&store.base) == NULL);

    CHECK(send(AppEventMenuNew) == AppEffectSendIntent);
    CHECK(app.screen == AppScreenWaitingResult);
    const Intent* in_flight = intent_store_current(&store.base);
    CHECK(in_flight != NULL);
    if(in_flight) {
        CHECK(in_flight->action == IntentActionNew);
        CHECK_STR_EQ(in_flight->id, "i-000003");
    }
}

static void test_unknown_with_prefill_offers_link_on_host(void) {
    setup();
    scan_mfc();
    ProtoLookup l = lookup_with(ProtoLookupUnknown, true);
    send_lookup(&l);
    CHECK(send(AppEventMenuLinkOnHost) == AppEffectSendIntent);
    const Intent* in_flight = intent_store_current(&store.base);
    CHECK(in_flight != NULL);
    if(in_flight) CHECK(in_flight->action == IntentActionLinkOnHost);
}

static void test_unknown_bare_never_sends_new(void) {
    setup();
    scan_mfc();
    ProtoLookup l = lookup_with(ProtoLookupUnknown, false);
    send_lookup(&l);
    CHECK(app.result_kind == AppResultUnknownBare);
    CHECK(send(AppEventMenuNew) == AppEffectNone);
    CHECK(send(AppEventMenuWeigh) == AppEffectNone);
    CHECK(app.screen == AppScreenResult);
    CHECK(intent_store_current(&store.base) == NULL);

    CHECK(send(AppEventMenuCreateOnHost) == AppEffectSendIntent);
    const Intent* in_flight = intent_store_current(&store.base);
    CHECK(in_flight != NULL);
    if(in_flight) CHECK(in_flight->action == IntentActionCreateOnHost);
    ProtoResult ok = result_for("i-000003", true);
    send_result(&ok);
    CHECK(app.screen == AppScreenDone);

    send(AppEventBack);
    scan_mfc();
    ProtoLookup again = lookup_with(ProtoLookupUnknown, false);
    strcpy(again.scan_id, "s-000013");
    send_lookup(&again);
    CHECK(send(AppEventMenuLinkOnHost) == AppEffectSendIntent);
    in_flight = intent_store_current(&store.base);
    CHECK(in_flight != NULL);
    if(in_flight) {
        CHECK(in_flight->action == IntentActionLinkOnHost);
        CHECK_STR_EQ(in_flight->id, "i-000004");
        CHECK_STR_EQ(in_flight->scan_id, "s-000013");
    }
}

static void test_lookup_error_shows_error(void) {
    setup();
    scan_mfc();
    send_lookup(fixture_lookup("lookup_error.json"));
    CHECK(app.screen == AppScreenError);
    CHECK(app.error == AppErrorLookup);
    CHECK_STR_EQ(app.lookup.lines.line[0], "Bambuddy unreachable");
    CHECK(send(AppEventBack) == AppEffectNone);
    CHECK(app.screen == AppScreenIdle);
}

static void test_no_host_goes_straight_to_result(void) {
    setup();
    send(AppEventHostLost);
    send(AppEventTagDetected);
    CHECK(send_tag(&ntag) == AppEffectNone);
    CHECK(app.screen == AppScreenResult);
    CHECK(app.result_kind == AppResultNoHost);
    CHECK_MEM_EQ(&app.scan.tag, &ntag, sizeof(ntag));
    /* No actions without a host. */
    CHECK(send(AppEventMenuWeigh) == AppEffectNone);
    CHECK(send(AppEventMenuNew) == AppEffectNone);
    CHECK(send(AppEventMenuCreateOnHost) == AppEffectNone);
    CHECK(send(AppEventMenuLinkOnHost) == AppEffectNone);
    CHECK(app.screen == AppScreenResult);
    CHECK(intent_store_current(&store.base) == NULL);
    CHECK(send(AppEventBack) == AppEffectNone);
    CHECK(app.screen == AppScreenIdle);
}

static void test_host_lost_while_waiting_for_lookup(void) {
    setup();
    scan_mfc();
    CHECK(send(AppEventHostLost) == AppEffectNone);
    CHECK(app.screen == AppScreenResult);
    CHECK(app.result_kind == AppResultNoHost);
}

static void test_host_lost_on_result_and_enter_weight(void) {
    setup();
    scan_mfc();
    send_lookup(fixture_lookup("lookup_found.json"));
    send(AppEventHostLost);
    CHECK(app.screen == AppScreenResult);
    CHECK(app.result_kind == AppResultNoHost);

    setup();
    scan_mfc();
    send_lookup(fixture_lookup("lookup_found.json"));
    send(AppEventMenuWeigh);
    send(AppEventHostLost);
    CHECK(app.screen == AppScreenResult);
    CHECK(app.result_kind == AppResultNoHost);
    CHECK(send_weight(100) == AppEffectNone);
    CHECK(intent_store_current(&store.base) == NULL);
}

static void test_host_lost_mid_intent_is_an_error(void) {
    setup();
    scan_mfc();
    send_lookup(fixture_lookup("lookup_found.json"));
    send(AppEventMenuWeigh);
    send_weight(600);
    CHECK(send(AppEventHostLost) == AppEffectNone);
    CHECK(app.screen == AppScreenError);
    CHECK(app.error == AppErrorHostLost);
    /* A result arriving after reconnect no longer applies. */
    send(AppEventHostConnected);
    ProtoResult late = result_for("i-000003", true);
    send_result(&late);
    CHECK(app.screen == AppScreenError);
}

static void test_a_scan_that_cannot_be_sent_shows_local_facts(void) {
    setup();
    scan_mfc();
    CHECK(send(AppEventSendFailed) == AppEffectNone);
    CHECK(app.screen == AppScreenResult);
    CHECK(app.result_kind == AppResultNoHost);
    /* The link is still up: the next scan tries the host again. */
    CHECK(app.connected);
    send(AppEventBack);
    scan_mfc();
}

static void test_an_intent_that_cannot_be_sent_is_an_error(void) {
    setup();
    scan_mfc();
    send_lookup(fixture_lookup("lookup_found.json"));
    send(AppEventMenuWeigh);
    send_weight(600);
    CHECK(send(AppEventSendFailed) == AppEffectNone);
    CHECK(app.screen == AppScreenError);
    CHECK(app.error == AppErrorSendFailed);
    CHECK(!app_result_timed_out(&app, 60000));
}

static void test_send_failed_elsewhere_is_ignored(void) {
    setup();
    CHECK(send(AppEventSendFailed) == AppEffectNone);
    CHECK(app.screen == AppScreenIdle);
    scan_mfc();
    send_lookup(fixture_lookup("lookup_found.json"));
    CHECK(send(AppEventSendFailed) == AppEffectNone);
    CHECK(app.screen == AppScreenResult);
    CHECK(app.result_kind == AppResultFound);
}

static void test_timeout_while_waiting_for_result(void) {
    setup();
    scan_mfc();
    send_lookup(fixture_lookup("lookup_found.json"));
    send(AppEventMenuWeigh);
    send_weight(600);
    CHECK(send(AppEventTimeout) == AppEffectNone);
    CHECK(app.screen == AppScreenError);
    CHECK(app.error == AppErrorTimeout);
    /* Timeouts elsewhere do nothing. */
    send(AppEventBack);
    CHECK(send(AppEventTimeout) == AppEffectNone);
    CHECK(app.screen == AppScreenIdle);
}

static void test_back_while_waiting_for_result_is_ignored(void) {
    setup();
    scan_mfc();
    send_lookup(fixture_lookup("lookup_found.json"));
    send(AppEventMenuWeigh);
    send_weight(600);
    CHECK(send(AppEventBack) == AppEffectNone);
    CHECK(app.screen == AppScreenWaitingResult);
}

static void test_read_failed_and_back_while_reading(void) {
    setup();
    send(AppEventTagDetected);
    CHECK(send(AppEventReadFailed) == AppEffectNone);
    CHECK(app.screen == AppScreenError);
    CHECK(app.error == AppErrorReadFailed);
    send(AppEventBack);
    send(AppEventTagDetected);
    CHECK(send(AppEventBack) == AppEffectNone);
    CHECK(app.screen == AppScreenIdle);
    /* Tag events outside Reading are ignored. */
    CHECK(send_tag(&mfc) == AppEffectNone);
    CHECK(send(AppEventReadFailed) == AppEffectNone);
    CHECK(app.screen == AppScreenIdle);
}

static void test_enter_weight_back_returns_to_result(void) {
    setup();
    scan_mfc();
    send_lookup(fixture_lookup("lookup_found.json"));
    send(AppEventMenuWeigh);
    CHECK(send(AppEventBack) == AppEffectNone);
    CHECK(app.screen == AppScreenResult);
    CHECK(app.result_kind == AppResultFound);
    CHECK(send(AppEventBack) == AppEffectNone);
    CHECK(app.screen == AppScreenIdle);
}

static void test_weight_out_of_range_is_ignored(void) {
    setup();
    scan_mfc();
    send_lookup(fixture_lookup("lookup_found.json"));
    send(AppEventMenuWeigh);
    CHECK(send_weight(PROTO_GRAMS_MAX + 1) == AppEffectNone);
    CHECK(app.screen == AppScreenEnterWeight);
    CHECK(send_weight(PROTO_GRAMS_MAX) == AppEffectSendIntent);
}

static void test_weight_default_falls_back_to_label_plus_core(void) {
    setup();
    scan_mfc();
    ProtoLookup l = lookup_with(ProtoLookupFound, false);
    l.defaults.has_label = true;
    l.defaults.label = 1000;
    l.defaults.has_core = true;
    l.defaults.core = 250;
    send_lookup(&l);
    send(AppEventMenuWeigh);
    CHECK_EQ_INT(app.weight_default, 1250);

    setup();
    scan_mfc();
    l.defaults.label = 9900;
    send_lookup(&l);
    send(AppEventMenuWeigh);
    CHECK_EQ_INT(app.weight_default, PROTO_GRAMS_MAX);

    setup();
    scan_mfc();
    l = lookup_with(ProtoLookupFound, false);
    send_lookup(&l);
    send(AppEventMenuWeigh);
    CHECK_EQ_INT(app.weight_default, 0);
}

static void test_mode_toggle_persists_across_scans(void) {
    setup();
    scan_mfc();
    send_lookup(fixture_lookup("lookup_found.json"));
    send(AppEventMenuWeigh);
    CHECK(send(AppEventToggleMode) == AppEffectNone);
    CHECK(app.mode == WeightModeNet);
    CHECK(app.screen == AppScreenEnterWeight);
    send_weight(484);
    const Intent* in_flight = intent_store_current(&store.base);
    CHECK(in_flight != NULL);
    if(in_flight) CHECK(in_flight->mode == WeightModeNet);
    ProtoResult ok = result_for("i-000003", true);
    send_result(&ok);
    send(AppEventBack);

    scan_mfc();
    ProtoLookup l = lookup_with(ProtoLookupFound, false);
    strcpy(l.scan_id, "s-000013");
    send_lookup(&l);
    send(AppEventMenuWeigh);
    CHECK(app.mode == WeightModeNet);
    send(AppEventToggleMode);
    CHECK(app.mode == WeightModeGross);
}

static void test_mode_toggles_from_the_found_menu(void) {
    setup();
    scan_mfc();
    send_lookup(fixture_lookup("lookup_found.json"));
    CHECK(send(AppEventToggleMode) == AppEffectNone);
    CHECK(app.mode == WeightModeNet);
    CHECK(app.screen == AppScreenResult);
    CHECK(app.result_kind == AppResultFound);
    send(AppEventMenuWeigh);
    CHECK_EQ_INT(app.weight_default, 484); /* gross 734 - core 250 */
    send(AppEventBack);
    CHECK(send(AppEventToggleMode) == AppEffectNone);
    CHECK(app.mode == WeightModeGross);
    send(AppEventMenuWeigh);
    CHECK_EQ_INT(app.weight_default, 734);
}

static void test_mode_toggle_only_where_weighing_is_offered(void) {
    setup();
    CHECK(send(AppEventToggleMode) == AppEffectNone); /* Idle */
    CHECK(app.mode == WeightModeGross);
    scan_mfc();
    CHECK(send(AppEventToggleMode) == AppEffectNone); /* WaitingLookup */
    CHECK(app.mode == WeightModeGross);
    send_lookup(fixture_lookup("lookup_unknown.json"));
    CHECK(send(AppEventToggleMode) == AppEffectNone);
    CHECK(app.mode == WeightModeGross);
    send(AppEventMenuNew);
    CHECK(send(AppEventToggleMode) == AppEffectNone); /* WaitingResult */
    CHECK(app.mode == WeightModeGross);

    setup();
    send(AppEventHostLost);
    send(AppEventTagDetected);
    send_tag(&mfc);
    CHECK(app.result_kind == AppResultNoHost);
    CHECK(send(AppEventToggleMode) == AppEffectNone);
    CHECK(app.mode == WeightModeGross);
}

static void test_toggle_on_enter_weight_updates_the_default(void) {
    setup();
    scan_mfc();
    send_lookup(fixture_lookup("lookup_found.json"));
    send(AppEventMenuWeigh);
    CHECK_EQ_INT(app.weight_default, 734);
    send(AppEventToggleMode);
    CHECK_EQ_INT(app.weight_default, 484);
    send(AppEventToggleMode);
    CHECK_EQ_INT(app.weight_default, 734);
}

static void test_net_weight_default(void) {
    ProtoLookup l = lookup_with(ProtoLookupFound, false);
    l.defaults.has_gross = true;
    l.defaults.gross = 200;
    l.defaults.has_core = true;
    l.defaults.core = 250;
    l.defaults.has_label = true;
    l.defaults.label = 1000;

    /* gross below the core clamps to 0 */
    setup();
    send(AppEventToggleMode); /* ignored on Idle */
    scan_mfc();
    send_lookup(&l);
    send(AppEventToggleMode);
    send(AppEventMenuWeigh);
    CHECK(app.mode == WeightModeNet);
    CHECK_EQ_INT(app.weight_default, 0);

    /* without a core the gross is all there is */
    setup();
    scan_mfc();
    l.defaults.has_core = false;
    send_lookup(&l);
    send(AppEventToggleMode);
    send(AppEventMenuWeigh);
    CHECK_EQ_INT(app.weight_default, 200);

    /* without a gross: the label weight */
    setup();
    scan_mfc();
    l.defaults.has_gross = false;
    l.defaults.has_core = true;
    send_lookup(&l);
    send(AppEventToggleMode);
    send(AppEventMenuWeigh);
    CHECK_EQ_INT(app.weight_default, 1000);

    /* nothing known */
    setup();
    scan_mfc();
    l = lookup_with(ProtoLookupFound, false);
    send_lookup(&l);
    send(AppEventToggleMode);
    send(AppEventMenuWeigh);
    CHECK_EQ_INT(app.weight_default, 0);
}

static void test_result_times_out_after_10_s(void) {
    setup();
    CHECK(!app_result_timed_out(&app, 60000)); /* nothing in flight */
    scan_mfc();
    send_lookup(fixture_lookup("lookup_found.json"));
    send(AppEventMenuWeigh);
    CHECK(!app_result_timed_out(&app, 60000)); /* not sent yet */
    CHECK(send_weight_at(600, 5000) == AppEffectSendIntent);
    CHECK(!app_result_timed_out(&app, 5000));
    CHECK(!app_result_timed_out(&app, 5000 + APP_RESULT_TIMEOUT_MS - 1));
    CHECK(app_result_timed_out(&app, 5000 + APP_RESULT_TIMEOUT_MS));
    CHECK_EQ_INT(APP_RESULT_TIMEOUT_MS, 10000);
    send(AppEventTimeout);
    CHECK(app.screen == AppScreenError);
    CHECK(!app_result_timed_out(&app, 5000 + APP_RESULT_TIMEOUT_MS));
}

static void test_result_timeout_for_menu_intents_and_tick_wrap(void) {
    setup();
    scan_mfc();
    send_lookup(fixture_lookup("lookup_unknown.json"));
    CHECK(send_at(AppEventMenuNew, UINT32_MAX - 999) == AppEffectSendIntent);
    CHECK(!app_result_timed_out(&app, 8999)); /* 9999 ms after, past the wrap */
    CHECK(app_result_timed_out(&app, 9000));
    ProtoResult ok = result_for("i-000003", true);
    send_result(&ok);
    CHECK(app.screen == AppScreenDone);
    CHECK(!app_result_timed_out(&app, 9000));
}

static AppEffect send_transport(TransportKind kind) {
    AppEvent e = {.type = AppEventTransportChosen, .transport = kind};
    return app_reduce(&app, &e);
}

static AppEffect send_ble(AppBleStatus status) {
    AppEvent e = {.type = AppEventBleStatus, .ble = status};
    return app_reduce(&app, &e);
}

static void test_init_uses_usb_with_ble_off(void) {
    single_slot_intent_store_init(&store);
    app_state_init(&app, &store.base, 1, 1);
    CHECK(app.transport == TransportKindUsb);
    CHECK(app.ble == AppBleOff);
}

static void test_transport_menu_opens_from_idle_and_closes_with_back(void) {
    setup();
    CHECK(send(AppEventMenuTransport) == AppEffectNone);
    CHECK(app.screen == AppScreenTransport);
    /* the reader is off here: a tag does not start a read */
    CHECK(send(AppEventTagDetected) == AppEffectNone);
    CHECK(app.screen == AppScreenTransport);
    CHECK(send(AppEventBack) == AppEffectNone);
    CHECK(app.screen == AppScreenIdle);
    CHECK(app.transport == TransportKindUsb);
}

static void test_transport_menu_only_from_idle(void) {
    setup();
    scan_mfc();
    CHECK(send(AppEventMenuTransport) == AppEffectNone);
    CHECK(app.screen == AppScreenWaitingLookup);
    CHECK(send_transport(TransportKindBluetooth) == AppEffectNone);
    CHECK(app.transport == TransportKindUsb);
    CHECK(app.screen == AppScreenWaitingLookup);
}

static void test_choosing_another_transport_switches_it(void) {
    setup();
    send(AppEventMenuTransport);
    CHECK(send_transport(TransportKindBluetooth) == AppEffectSwitchTransport);
    CHECK(app.transport == TransportKindBluetooth);
    CHECK(app.ble == AppBleOff);
    CHECK(app.screen == AppScreenIdle);

    send(AppEventMenuTransport);
    CHECK(send_transport(TransportKindUsb) == AppEffectSwitchTransport);
    CHECK(app.transport == TransportKindUsb);
    CHECK(app.screen == AppScreenIdle);
}

static void test_choosing_the_same_transport_changes_nothing(void) {
    setup();
    send(AppEventMenuTransport);
    CHECK(send_transport(TransportKindUsb) == AppEffectNone);
    CHECK(app.transport == TransportKindUsb);
    CHECK(app.screen == AppScreenIdle);
    CHECK(app.connected);
}

static void test_unknown_transport_kind_is_ignored(void) {
    setup();
    send(AppEventMenuTransport);
    CHECK(send_transport((TransportKind)7) == AppEffectNone);
    CHECK(app.transport == TransportKindUsb);
    CHECK(app.screen == AppScreenTransport);
}

static void test_switching_transport_resets_the_ble_status(void) {
    setup();
    app.transport = TransportKindBluetooth;
    send_ble(AppBleConnected);
    send(AppEventMenuTransport);
    CHECK(send_transport(TransportKindUsb) == AppEffectSwitchTransport);
    CHECK(app.ble == AppBleOff);
}

static void test_ble_status_is_recorded_on_every_screen(void) {
    setup();
    app.transport = TransportKindBluetooth;
    CHECK(send_ble(AppBleAdvertising) == AppEffectNone);
    CHECK(app.ble == AppBleAdvertising);
    CHECK(app.screen == AppScreenIdle);
    CHECK(send_ble(AppBleConnected) == AppEffectNone);
    CHECK(app.ble == AppBleConnected);

    scan_mfc();
    CHECK(send_ble(AppBleAdvertising) == AppEffectNone);
    CHECK(app.ble == AppBleAdvertising);
    CHECK(app.screen == AppScreenWaitingLookup);
    /* the status alone does not lose the host: host_link does */
    CHECK(app.connected);
    send(AppEventMenuTransport);
    CHECK(send_ble(AppBleOff) == AppEffectNone);
    CHECK(app.ble == AppBleOff);
}

int main(void) {
    RUN_TEST(test_init_starts_idle_without_host);
    RUN_TEST(test_scan_gets_a_new_id_and_a_copy_of_the_tag);
    RUN_TEST(test_found_weigh_done_back_to_idle);
    RUN_TEST(test_mismatched_result_is_ignored);
    RUN_TEST(test_results_outside_waiting_are_ignored);
    RUN_TEST(test_lookup_for_another_scan_is_ignored);
    RUN_TEST(test_unknown_with_prefill_offers_new);
    RUN_TEST(test_unknown_with_prefill_offers_link_on_host);
    RUN_TEST(test_unknown_bare_never_sends_new);
    RUN_TEST(test_lookup_error_shows_error);
    RUN_TEST(test_no_host_goes_straight_to_result);
    RUN_TEST(test_host_lost_while_waiting_for_lookup);
    RUN_TEST(test_host_lost_on_result_and_enter_weight);
    RUN_TEST(test_host_lost_mid_intent_is_an_error);
    RUN_TEST(test_a_scan_that_cannot_be_sent_shows_local_facts);
    RUN_TEST(test_an_intent_that_cannot_be_sent_is_an_error);
    RUN_TEST(test_send_failed_elsewhere_is_ignored);
    RUN_TEST(test_timeout_while_waiting_for_result);
    RUN_TEST(test_back_while_waiting_for_result_is_ignored);
    RUN_TEST(test_read_failed_and_back_while_reading);
    RUN_TEST(test_enter_weight_back_returns_to_result);
    RUN_TEST(test_weight_out_of_range_is_ignored);
    RUN_TEST(test_weight_default_falls_back_to_label_plus_core);
    RUN_TEST(test_mode_toggle_persists_across_scans);
    RUN_TEST(test_mode_toggles_from_the_found_menu);
    RUN_TEST(test_mode_toggle_only_where_weighing_is_offered);
    RUN_TEST(test_toggle_on_enter_weight_updates_the_default);
    RUN_TEST(test_net_weight_default);
    RUN_TEST(test_result_times_out_after_10_s);
    RUN_TEST(test_result_timeout_for_menu_intents_and_tick_wrap);
    RUN_TEST(test_init_uses_usb_with_ble_off);
    RUN_TEST(test_transport_menu_opens_from_idle_and_closes_with_back);
    RUN_TEST(test_transport_menu_only_from_idle);
    RUN_TEST(test_choosing_another_transport_switches_it);
    RUN_TEST(test_choosing_the_same_transport_changes_nothing);
    RUN_TEST(test_unknown_transport_kind_is_ignored);
    RUN_TEST(test_switching_transport_resets_the_ble_status);
    RUN_TEST(test_ble_status_is_recorded_on_every_screen);
    return MINITEST_RESULT();
}
