#include <furi.h>
#include <furi_hal_rtc.h>
#include <furi_hal_version.h>
#include <toolbox/version.h>

#include "app_settings_file.h"
#include "feedback_play.h"
#include "flibuddy_app.h"
#include "transport_ble.h"
#include "transport_none.h"
#include "transport_usb.h"
#include "ui_draw.h"
#include "ui_frame.h"

#define TICK_PERIOD_MS 250
#define RX_QUEUE_LEN   4

/* 1 tick = 1 ms on f7 (configTICK_RATE_HZ 1000); host_link copes with wrap. */
static uint32_t now_ms(void) {
    return furi_get_tick();
}

static const char* firmware_version(void) {
    const char* fw = version_get_version(NULL);
    return fw == NULL || fw[0] == '\0' ? "unknown" : fw;
}

/* TransportNotSent also when the line did not encode. */
static TransportSendResult send_text(FliBuddyApp* app, size_t len) {
    return len > 0 ? transport_send_line(app->transport, app->tx_buf, len) : TransportNotSent;
}

static void send_hello(FliBuddyApp* app) {
    send_text(
        app, proto_encode_hello(FLIBUDDY_HELLO_APP, firmware_version(), app->tx_buf, PROTO_LINE_MAX));
}

/* ---- view ---- */

static void refresh(FliBuddyApp* app) {
    const char* name = furi_hal_version_get_name_ptr();
    UiEnv env = {
        .now_ms = now_ms(),
        .anim = app->anim,
        .version = FLIBUDDY_VERSION,
        .firmware = firmware_version(),
        .device_name = name ? name : "Flipper",
        .host_app = app->host_app,
    };
    with_view_model(app->view, UiFrame * frame, { ui_frame_build(frame, &app->state, &env); }, true);
}

/* GUI service thread, with the model locked. */
static void on_draw(Canvas* canvas, void* model) {
    ui_draw(canvas, model);
}

/* A press, and for ▲▼ also a held key's long press and repeats. */
static bool key_of(const InputEvent* event, AppKey* key) {
    bool step = event->key == InputKeyUp || event->key == InputKeyDown;
    bool held = event->type == InputTypeLong || event->type == InputTypeRepeat;
    if(event->type != InputTypeShort && !(step && held)) return false;
    switch(event->key) {
    case InputKeyUp:
        *key = AppKeyUp;
        return true;
    case InputKeyDown:
        *key = AppKeyDown;
        return true;
    case InputKeyLeft:
        *key = AppKeyLeft;
        return true;
    case InputKeyRight:
        *key = AppKeyRight;
        return true;
    case InputKeyOk:
        *key = AppKeyOk;
        return true;
    case InputKeyBack:
        *key = AppKeyBack;
        return true;
    default:
        return false;
    }
}

/* Every key is the reducer's, Back included: the app exits on its
 * AppEffectExit only. */
static bool on_input(InputEvent* event, void* ctx) {
    FliBuddyApp* app = ctx;
    AppKey key;
    if(key_of(event, &key)) flibuddy_reduce(app, &(AppEvent){.type = AppEventKey, .key = key});
    return true;
}

/* ---- NFC ---- */

/* NFC worker thread. */
static void on_reader_event(TagReaderEvent event, void* ctx) {
    FliBuddyApp* app = ctx;
    static const uint32_t custom[] = {
        [TagReaderEventDetected] = FliBuddyEventTagDetected,
        [TagReaderEventRead] = FliBuddyEventTagRead,
        [TagReaderEventFailed] = FliBuddyEventReadFailed,
    };
    view_dispatcher_send_custom_event(app->view_dispatcher, custom[event]);
}

/* A started reader stays started after its worker read a tag (see
 * nfc_read.h), so the read and failed events stop it first; then it starts
 * again on every screen that reads, and its worker waits for the tag just
 * read to leave the field. */
static void sync_reader(FliBuddyApp* app) {
    if(app_reader_wanted(&app->state)) {
        tag_reader_start(app->reader, app->read_dump, on_reader_event, app);
    } else {
        tag_reader_stop(app->reader);
    }
}

/* ---- transport ---- */

static void apply_link(FliBuddyApp* app, HostLinkOutput out);
static void on_rx_line(const char* line, size_t len, void* ctx);

static void free_transport(FliBuddyApp* app) {
    if(app->transport != transport_none()) {
        if(app->transport_kind == TransportKindUsb) {
            transport_usb_free(app->transport);
        } else {
            transport_ble_free(app->transport);
        }
    }
    app->transport = transport_none();
}

/* A backend that does not open (Bluetooth off or unavailable) gives way to
 * the null transport: no host connects, and with Bluetooth the USB port
 * stays with the CLI. Leaving Settings retries it. This also runs before
 * the view is shown, so the state is changed directly; the caller redraws. */
static void start_transport(FliBuddyApp* app) {
    app->transport_kind = app->state.transport;
    app->transport = app->transport_kind == TransportKindUsb ? transport_usb_alloc() :
                                                               transport_ble_alloc();
    transport_set_rx_callback(app->transport, on_rx_line, app);
    if(!transport_open(app->transport)) {
        FURI_LOG_E(
            "FliBuddy", "%s unavailable",
            app->transport_kind == TransportKindUsb ? "USB" : "Bluetooth");
        free_transport(app);
        app_reduce(&app->state, &(AppEvent){.type = AppEventTransportFailed, .now_ms = now_ms()});
    }
}

static void save_settings(FliBuddyApp* app) {
    if(!app_settings_save(&app->state.settings, &app_settings_file)) {
        FURI_LOG_E("FliBuddy", "settings not saved");
    }
}

/* Closes the old transport (the host it carried is lost), saves the
 * settings and opens the new one. */
static void switch_transport(FliBuddyApp* app) {
    free_transport(app);
    /* a hello the old worker queued must not connect a host over the new one */
    furi_message_queue_reset(app->rx_queue);
    app->port_open = false;
    apply_link(app, host_link_port_closed(&app->link));
    save_settings(app);
    start_transport(app);
}

/* ---- the reducer ---- */

static void play_cue(FliBuddyApp* app) {
    if(app->state.cue != AppCueNone) {
        feedback_play(app->notifications, app->state.cue, &app->state.settings);
    }
}

void flibuddy_reduce(FliBuddyApp* app, const AppEvent* event) {
    AppEvent stamped = *event;
    stamped.now_ms = now_ms();
    AppEffect effect = app_reduce(&app->state, &stamped);
    play_cue(app);
    bool failed = false;
    switch(effect) {
    case AppEffectSendScan:
        /* a scan that may not have arrived gets no lookup to wait for: the
         * Flipper has no lookup timeout */
        failed = send_text(app, app_encode_scan(&app->state, app->tx_buf, PROTO_LINE_MAX)) !=
                 TransportSent;
        break;
    case AppEffectSendIntent:
        /* an intent that may have arrived may be performed: wait for its
         * result or the timeout, never claim it was not sent */
        failed = send_text(app, app_encode_intent(&app->state, app->tx_buf, PROTO_LINE_MAX)) ==
                 TransportNotSent;
        break;
    case AppEffectSaveSettings:
        save_settings(app);
        break;
    case AppEffectSwitchTransport:
        switch_transport(app);
        break;
    case AppEffectExit:
        view_dispatcher_stop(app->view_dispatcher);
        break;
    case AppEffectNone:
        break;
    }
    if(failed) {
        /* no answer will come: do not wait for one */
        app_reduce(&app->state, &(AppEvent){.type = AppEventSendFailed, .now_ms = stamped.now_ms});
        play_cue(app);
    }
    sync_reader(app);
    refresh(app);
}

void flibuddy_reduce_type(FliBuddyApp* app, AppEventType type) {
    flibuddy_reduce(app, &(AppEvent){.type = type});
}

static void apply_link(FliBuddyApp* app, HostLinkOutput out) {
    if(out.send_hello) send_hello(app);
    if(out.host_connected) flibuddy_reduce_type(app, AppEventHostConnected);
    if(out.host_lost) flibuddy_reduce_type(app, AppEventHostLost);
}

static AppBleStatus ble_status(FliBuddyApp* app) {
    if(app->transport_kind != TransportKindBluetooth || app->transport == transport_none()) {
        return AppBleOff;
    }
    switch(transport_ble_status(app->transport)) {
    case TransportBleAdvertising:
        return AppBleAdvertising;
    case TransportBleConnected:
        return AppBleConnected;
    case TransportBleOff:
        break;
    }
    return AppBleOff;
}

static void handle_message(FliBuddyApp* app, const ProtoMessage* msg) {
    switch(msg->type) {
    case ProtoMsgHello:
        strlcpy(app->host_app, msg->hello.app, sizeof(app->host_app));
        apply_link(app, host_link_host_hello(&app->link, now_ms()));
        break;
    case ProtoMsgLookup:
        flibuddy_reduce(app, &(AppEvent){.type = AppEventLookupReceived, .lookup = &msg->lookup});
        break;
    case ProtoMsgResult:
        flibuddy_reduce(app, &(AppEvent){.type = AppEventResultReceived, .result = &msg->result});
        break;
    case ProtoMsgNone:
        break;
    }
}

/* Transport worker thread: decode here, hand over to the GUI thread. */
static void on_rx_line(const char* line, size_t len, void* ctx) {
    FliBuddyApp* app = ctx;
    UNUSED(len);
    if(proto_decode_line(line, &app->rx_decoded) != ProtoDecodeOk) return;
    if(furi_message_queue_put(app->rx_queue, &app->rx_decoded, 0) == FuriStatusOk) {
        view_dispatcher_send_custom_event(app->view_dispatcher, FliBuddyEventRx);
    }
}

/* The reducer takes a read only on Reading. The worker can finish a tag
 * before the screen leaves for another one (a Mark toast committed by the
 * detection of that same tag); that tag must be read again when the reader
 * restarts, not waited out. */
static void forget_dropped_read(FliBuddyApp* app) {
    if(app->state.screen != AppScreenReading) tag_reader_forget(app->reader);
}

static bool on_custom_event(void* ctx, uint32_t event) {
    FliBuddyApp* app = ctx;
    switch(event) {
    case FliBuddyEventRx:
        while(furi_message_queue_get(app->rx_queue, &app->rx_msg, 0) == FuriStatusOk) {
            handle_message(app, &app->rx_msg);
        }
        return true;
    case FliBuddyEventTagDetected:
        flibuddy_reduce_type(app, AppEventTagDetected);
        return true;
    case FliBuddyEventTagRead:
        tag_reader_stop(app->reader); /* its worker has ended */
        forget_dropped_read(app);
        flibuddy_reduce(app, &(AppEvent){.type = AppEventTagRead, .tag = app->read_dump});
        return true;
    case FliBuddyEventReadFailed:
        tag_reader_stop(app->reader);
        forget_dropped_read(app);
        flibuddy_reduce_type(app, AppEventReadFailed);
        return true;
    default:
        return false;
    }
}

/* The view handles Back itself; this only runs if it ever does not. */
static bool on_navigation(void* ctx) {
    UNUSED(ctx);
    return true;
}

static void on_tick(void* ctx) {
    FliBuddyApp* app = ctx;
    bool open = transport_is_connected(app->transport);
    if(open != app->port_open) {
        app->port_open = open;
        apply_link(
            app,
            open ? host_link_port_opened(&app->link, now_ms()) :
                   host_link_port_closed(&app->link));
    }
    apply_link(app, host_link_tick(&app->link, now_ms()));
    AppBleStatus ble = ble_status(app);
    if(ble != app->state.ble) {
        flibuddy_reduce(app, &(AppEvent){.type = AppEventBleStatus, .ble = ble});
    }
    app->anim++;
    flibuddy_reduce_type(app, AppEventTick);
}

/* ---- life cycle ---- */

static FliBuddyApp* flibuddy_app_alloc(void) {
    FliBuddyApp* app = malloc(sizeof(FliBuddyApp));
    memset(app, 0, sizeof(FliBuddyApp));

    uint32_t seed = id_seed_from_time(furi_hal_rtc_get_timestamp());
    single_slot_intent_store_init(&app->intents);
    app_state_init(&app->state, &app->intents.base, seed, seed);
    app_settings_load(&app->state.settings, &app_settings_file);
    app->state.transport = app_settings_transport(&app->state.settings);
    host_link_init(&app->link);

    app->tx_buf = malloc(PROTO_LINE_MAX);
    app->read_dump = malloc(sizeof(TagDump));
    app->reader = tag_reader_alloc();
    app->rx_queue = furi_message_queue_alloc(RX_QUEUE_LEN, sizeof(ProtoMessage));

    app->gui = furi_record_open(RECORD_GUI);
    app->notifications = furi_record_open(RECORD_NOTIFICATION);
    app->view_dispatcher = view_dispatcher_alloc();
    view_dispatcher_set_event_callback_context(app->view_dispatcher, app);
    view_dispatcher_set_custom_event_callback(app->view_dispatcher, on_custom_event);
    view_dispatcher_set_navigation_event_callback(app->view_dispatcher, on_navigation);
    view_dispatcher_set_tick_event_callback(
        app->view_dispatcher, on_tick, furi_ms_to_ticks(TICK_PERIOD_MS));

    app->view = view_alloc();
    view_allocate_model(app->view, ViewModelTypeLocking, sizeof(UiFrame));
    view_set_context(app->view, app);
    view_set_draw_callback(app->view, on_draw);
    view_set_input_callback(app->view, on_input);
    view_dispatcher_add_view(app->view_dispatcher, FliBuddyViewMain, app->view);
    view_dispatcher_attach_to_gui(app->view_dispatcher, app->gui, ViewDispatcherTypeFullscreen);

    start_transport(app);
    return app;
}

static void flibuddy_app_free(FliBuddyApp* app) {
    /* the workers stop first, so nothing posts events into freed objects */
    tag_reader_free(app->reader);
    free_transport(app);

    view_dispatcher_remove_view(app->view_dispatcher, FliBuddyViewMain);
    view_free(app->view);
    view_dispatcher_free(app->view_dispatcher);
    furi_record_close(RECORD_NOTIFICATION);
    furi_record_close(RECORD_GUI);

    furi_message_queue_free(app->rx_queue);
    free(app->read_dump);
    free(app->tx_buf);
    free(app);
}

int32_t flibuddy_app(void* p) {
    UNUSED(p);
    FliBuddyApp* app = flibuddy_app_alloc();
    view_dispatcher_switch_to_view(app->view_dispatcher, FliBuddyViewMain);
    sync_reader(app);
    refresh(app);
    view_dispatcher_run(app->view_dispatcher);
    flibuddy_app_free(app);
    return 0;
}
