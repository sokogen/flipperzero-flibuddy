/* The FliBuddy FAP: one custom view and the glue between the transport, the
 * NFC reader, the hello handshake (host_link.h), the screen reducer
 * (app_state.h) and the screens (ui_frame.h, ui_draw.h).
 *
 * Every state change goes through flibuddy_reduce(), which performs the
 * reducer's effect (send a scan or an intent, save the settings, switch the
 * transport, exit), plays its feedback cue, runs the NFC reader on the
 * screens that read (app_reader_wanted) and rebuilds the view's frame.
 *
 * Threads: the GUI thread owns everything below except rx_decoded, which
 * the transport worker fills and hands over through rx_queue, read_dump,
 * which the NFC worker fills before it posts FliBuddyEventTagRead,
 * FliBuddyEventReadFailed or FliBuddyEventTagUnsupported and then ends, and the view's frame, which the
 * GUI service draws under the view model's lock. Every source file that
 * uses the SDK includes an SDK header itself, so that the host test build
 * (flipper/tests/Makefile) leaves it out.
 */
#pragma once

#include <furi.h>
#include <gui/gui.h>
#include <gui/view.h>
#include <gui/view_dispatcher.h>
#include <notification/notification.h>

#include "app_state.h"
#include "host_link.h"
#include "intents.h"
#include "nfc_read.h"
#include "proto_decode.h"
#include "transport.h"

#define FLIBUDDY_VERSION   "0.1.0"
#define FLIBUDDY_HELLO_APP "flibuddy-fap/" FLIBUDDY_VERSION

typedef enum {
    FliBuddyViewMain,
} FliBuddyView;

typedef enum {
    FliBuddyEventRx = 100, /* messages wait in rx_queue */
    FliBuddyEventTagDetected, /* NFC worker */
    FliBuddyEventTagRead, /* NFC worker, read_dump is filled */
    FliBuddyEventReadFailed, /* NFC worker */
    FliBuddyEventTagUnsupported, /* NFC worker */
} FliBuddyEvent;

typedef struct {
    Gui* gui;
    ViewDispatcher* view_dispatcher;
    View* view; /* model: UiFrame */
    NotificationApp* notifications;

    Transport* transport;
    TransportKind transport_kind; /* the backend of `transport` */
    FuriMessageQueue* rx_queue; /* ProtoMessage */
    ProtoMessage rx_decoded; /* transport worker only */
    ProtoMessage rx_msg; /* GUI thread */
    char* tx_buf; /* PROTO_LINE_MAX */

    TagReader* reader;
    TagDump* read_dump;

    HostLink link;
    bool port_open;
    char host_app[PROTO_HELLO_FIELD_MAX + 1]; /* from the host's hello */
    uint32_t anim; /* ticks, for the animations */
    AppState state;
    SingleSlotIntentStore intents;
} FliBuddyApp;

/* Stamps the event with the clock, applies it to the state, performs its
 * effect and feedback, syncs the reader and redraws. */
void flibuddy_reduce(FliBuddyApp* app, const AppEvent* event);

/* Shorthand for events without data. */
void flibuddy_reduce_type(FliBuddyApp* app, AppEventType type);
