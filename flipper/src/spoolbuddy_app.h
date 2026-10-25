/* The SpoolBuddy FAP: GUI, scenes and the glue between the transport, the
 * NFC reader, the hello handshake (host_link.h) and the screen reducer
 * (app_state.h).
 *
 * Every state change goes through spoolbuddy_reduce(), which also shows the
 * scene for the new AppScreen and runs the NFC reader on Idle and Reading.
 *
 * Threads: the GUI thread owns everything below except rx_decoded, which
 * the transport worker fills and hands over through rx_queue, and
 * read_dump, which the NFC worker fills before it posts
 * SpoolBuddyEventTagRead and then ends. Every source
 * file that uses the SDK includes an SDK header itself, so that the host
 * test build (flipper/tests/Makefile) leaves it out.
 */
#pragma once

#include <furi.h>
#include <gui/gui.h>
#include <gui/modules/widget.h>
#include <gui/scene_manager.h>
#include <gui/view_dispatcher.h>

#include "app_state.h"
#include "host_link.h"
#include "intents.h"
#include "nfc_read.h"
#include "proto_decode.h"
#include "transport.h"

#define SPOOLBUDDY_HELLO_APP "spoolbuddy-fap/0.1.0"
#define SPOOLBUDDY_TEXT_MAX 256 /* tag summary or host lines on screen */

typedef enum {
    SpoolBuddyViewWidget,
} SpoolBuddyView;

typedef enum {
    SpoolBuddyEventRx = 100, /* messages wait in rx_queue */
    SpoolBuddyEventRedraw, /* the state or the connection status changed */
    SpoolBuddyEventTagDetected, /* NFC worker */
    SpoolBuddyEventTagRead, /* NFC worker, read_dump is filled */
    SpoolBuddyEventReadFailed, /* NFC worker */
    SpoolBuddyEventOk, /* OK button of a widget */
} SpoolBuddyEvent;

typedef struct {
    Gui* gui;
    ViewDispatcher* view_dispatcher;
    SceneManager* scene_manager;
    Widget* widget;

    Transport* transport;
    FuriMessageQueue* rx_queue; /* ProtoMessage */
    ProtoMessage rx_decoded; /* transport worker only */
    ProtoMessage rx_msg; /* GUI thread */
    char* tx_buf; /* PROTO_LINE_MAX */

    TagReader* reader;
    TagDump* read_dump;
    char text[SPOOLBUDDY_TEXT_MAX];

    HostLink link;
    bool port_open;
    AppState state;
    SingleSlotIntentStore intents;
} SpoolBuddyApp;

/* Applies an event to the state, performs its effect and shows the scene
 * of the new screen (or redraws the current one). */
void spoolbuddy_reduce(SpoolBuddyApp* app, const AppEvent* event);

/* Shorthand for events without data. */
void spoolbuddy_reduce_type(SpoolBuddyApp* app, AppEventType type);
