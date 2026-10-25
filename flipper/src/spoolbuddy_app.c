#include <furi.h>
#include <furi_hal_rtc.h>
#include <toolbox/version.h>

#include "scenes.h"
#include "spoolbuddy_app.h"
#include "transport_usb.h"

#define TICK_PERIOD_MS 250
#define RX_QUEUE_LEN 4

#define SPOOLBUDDY_SCENE_ON_ENTER(name, Name) spoolbuddy_scene_##name##_on_enter,
#define SPOOLBUDDY_SCENE_ON_EVENT(name, Name) spoolbuddy_scene_##name##_on_event,
#define SPOOLBUDDY_SCENE_ON_EXIT(name, Name) spoolbuddy_scene_##name##_on_exit,

static void (*const scene_on_enter[])(void*) = {SPOOLBUDDY_SCENES(SPOOLBUDDY_SCENE_ON_ENTER)};
static bool (*const scene_on_event[])(void*, SceneManagerEvent) = {
    SPOOLBUDDY_SCENES(SPOOLBUDDY_SCENE_ON_EVENT)};
static void (*const scene_on_exit[])(void*) = {SPOOLBUDDY_SCENES(SPOOLBUDDY_SCENE_ON_EXIT)};

const SceneManagerHandlers spoolbuddy_scene_handlers = {
    .on_enter_handlers = scene_on_enter,
    .on_event_handlers = scene_on_event,
    .on_exit_handlers = scene_on_exit,
    .scene_num = SpoolBuddySceneCount,
};

/* 1 tick = 1 ms on f7 (configTICK_RATE_HZ 1000); host_link copes with wrap. */
static uint32_t now_ms(void) {
    return furi_get_tick();
}

static void send_text(SpoolBuddyApp* app, size_t len) {
    if(len > 0) transport_send_line(app->transport, app->tx_buf, len);
}

static void send_hello(SpoolBuddyApp* app) {
    const char* fw = version_get_version(NULL);
    if(fw == NULL || fw[0] == '\0') fw = "unknown";
    send_text(app, proto_encode_hello(SPOOLBUDDY_HELLO_APP, fw, app->tx_buf, PROTO_LINE_MAX));
}

static void reduce(SpoolBuddyApp* app, const AppEvent* event) {
    switch(app_reduce(&app->state, event)) {
    case AppEffectSendScan:
        send_text(
            app,
            proto_encode_scan(
                &app->state.scan.tag, app->state.scan.id, app->tx_buf, PROTO_LINE_MAX));
        break;
    case AppEffectSendIntent:
        send_text(
            app,
            intent_encode(intent_store_current(app->state.intents), app->tx_buf, PROTO_LINE_MAX));
        break;
    case AppEffectNone:
        break;
    }
}

static void apply_link(SpoolBuddyApp* app, HostLinkOutput out) {
    if(out.send_hello) send_hello(app);
    if(out.host_connected) reduce(app, &(AppEvent){.type = AppEventHostConnected});
    if(out.host_lost) reduce(app, &(AppEvent){.type = AppEventHostLost});
}

/* Tells the scene when the status line changed since `was_up`. */
static void notify_status(SpoolBuddyApp* app, bool was_up) {
    if(host_link_is_up(&app->link) != was_up) {
        scene_manager_handle_custom_event(app->scene_manager, SpoolBuddyEventStatus);
    }
}

static void handle_message(SpoolBuddyApp* app, const ProtoMessage* msg) {
    bool was_up = host_link_is_up(&app->link);
    switch(msg->type) {
    case ProtoMsgHello:
        apply_link(app, host_link_host_hello(&app->link, now_ms()));
        notify_status(app, was_up);
        break;
    case ProtoMsgLookup:
        reduce(app, &(AppEvent){.type = AppEventLookupReceived, .lookup = &msg->lookup});
        break;
    case ProtoMsgResult:
        reduce(app, &(AppEvent){.type = AppEventResultReceived, .result = &msg->result});
        break;
    case ProtoMsgNone:
        break;
    }
}

/* Transport worker thread: decode here, hand over to the GUI thread. */
static void on_rx_line(const char* line, size_t len, void* ctx) {
    SpoolBuddyApp* app = ctx;
    UNUSED(len);
    if(proto_decode_line(line, &app->rx_decoded) != ProtoDecodeOk) return;
    if(furi_message_queue_put(app->rx_queue, &app->rx_decoded, 0) == FuriStatusOk) {
        view_dispatcher_send_custom_event(app->view_dispatcher, SpoolBuddyEventRx);
    }
}

static bool on_custom_event(void* ctx, uint32_t event) {
    SpoolBuddyApp* app = ctx;
    if(event == SpoolBuddyEventRx) {
        while(furi_message_queue_get(app->rx_queue, &app->rx_msg, 0) == FuriStatusOk) {
            handle_message(app, &app->rx_msg);
        }
        return true;
    }
    return scene_manager_handle_custom_event(app->scene_manager, event);
}

static bool on_back(void* ctx) {
    SpoolBuddyApp* app = ctx;
    return scene_manager_handle_back_event(app->scene_manager);
}

static void on_tick(void* ctx) {
    SpoolBuddyApp* app = ctx;
    bool was_up = host_link_is_up(&app->link);
    bool open = transport_is_connected(app->transport);
    if(open != app->port_open) {
        app->port_open = open;
        apply_link(
            app,
            open ? host_link_port_opened(&app->link, now_ms()) :
                   host_link_port_closed(&app->link));
    }
    apply_link(app, host_link_tick(&app->link, now_ms()));
    notify_status(app, was_up);
    scene_manager_handle_tick_event(app->scene_manager);
}

static SpoolBuddyApp* spoolbuddy_app_alloc(void) {
    SpoolBuddyApp* app = malloc(sizeof(SpoolBuddyApp));
    memset(app, 0, sizeof(SpoolBuddyApp));

    uint32_t seed = id_seed_from_time(furi_hal_rtc_get_timestamp());
    single_slot_intent_store_init(&app->intents);
    app_state_init(&app->state, &app->intents.base, seed, seed);
    host_link_init(&app->link);

    app->tx_buf = malloc(PROTO_LINE_MAX);
    app->rx_queue = furi_message_queue_alloc(RX_QUEUE_LEN, sizeof(ProtoMessage));

    app->gui = furi_record_open(RECORD_GUI);
    app->view_dispatcher = view_dispatcher_alloc();
    app->scene_manager = scene_manager_alloc(&spoolbuddy_scene_handlers, app);
    view_dispatcher_set_event_callback_context(app->view_dispatcher, app);
    view_dispatcher_set_custom_event_callback(app->view_dispatcher, on_custom_event);
    view_dispatcher_set_navigation_event_callback(app->view_dispatcher, on_back);
    view_dispatcher_set_tick_event_callback(
        app->view_dispatcher, on_tick, furi_ms_to_ticks(TICK_PERIOD_MS));

    app->widget = widget_alloc();
    view_dispatcher_add_view(
        app->view_dispatcher, SpoolBuddyViewWidget, widget_get_view(app->widget));
    view_dispatcher_attach_to_gui(app->view_dispatcher, app->gui, ViewDispatcherTypeFullscreen);

    app->transport = transport_usb_alloc();
    transport_set_rx_callback(app->transport, on_rx_line, app);
    if(!transport_open(app->transport)) FURI_LOG_E("SpoolBuddy", "USB CDC unavailable");
    return app;
}

static void spoolbuddy_app_free(SpoolBuddyApp* app) {
    /* the worker stops first, so nothing posts events into freed objects */
    transport_usb_free(app->transport);

    view_dispatcher_remove_view(app->view_dispatcher, SpoolBuddyViewWidget);
    widget_free(app->widget);
    scene_manager_free(app->scene_manager);
    view_dispatcher_free(app->view_dispatcher);
    furi_record_close(RECORD_GUI);

    furi_message_queue_free(app->rx_queue);
    free(app->tx_buf);
    free(app);
}

int32_t spoolbuddy_app(void* p) {
    UNUSED(p);
    SpoolBuddyApp* app = spoolbuddy_app_alloc();
    scene_manager_next_scene(app->scene_manager, SpoolBuddySceneIdle);
    view_dispatcher_run(app->view_dispatcher);
    spoolbuddy_app_free(app);
    return 0;
}
