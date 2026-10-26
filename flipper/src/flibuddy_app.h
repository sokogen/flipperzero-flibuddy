/* The FliBuddy FAP: GUI, scenes and the glue between the transport, the
 * NFC reader, the hello handshake (host_link.h) and the screen reducer
 * (app_state.h).
 *
 * Every state change goes through flibuddy_reduce(), which also shows the
 * scene for the new AppScreen, runs the NFC reader on Idle and Reading and
 * restarts the transport when the user picks another one (the choice is
 * saved in app_settings).
 *
 * Threads: the GUI thread owns everything below except rx_decoded, which
 * the transport worker fills and hands over through rx_queue, and
 * read_dump, which the NFC worker fills before it posts
 * FliBuddyEventTagRead and then ends. Every source
 * file that uses the SDK includes an SDK header itself, so that the host
 * test build (flipper/tests/Makefile) leaves it out.
 */
#pragma once

#include <furi.h>
#include <gui/gui.h>
#include <gui/modules/number_input.h>
#include <gui/modules/submenu.h>
#include <gui/modules/widget.h>
#include <gui/scene_manager.h>
#include <gui/view_dispatcher.h>

#include "app_settings.h"
#include "app_state.h"
#include "host_link.h"
#include "intents.h"
#include "nfc_read.h"
#include "proto_decode.h"
#include "screen_text.h"
#include "transport.h"

#define FLIBUDDY_HELLO_APP "flibuddy-fap/0.1.0"
#define FLIBUDDY_TEXT_MAX (SCREEN_TEXT_MAX + 16) /* screen text and a title */

typedef enum {
    FliBuddyViewWidget,
    FliBuddyViewSubmenu,
    FliBuddyViewNumberInput,
} FliBuddyView;

typedef enum {
    FliBuddyEventRx = 100, /* messages wait in rx_queue */
    FliBuddyEventRedraw, /* the state or the connection status changed */
    FliBuddyEventTagDetected, /* NFC worker */
    FliBuddyEventTagRead, /* NFC worker, read_dump is filled */
    FliBuddyEventReadFailed, /* NFC worker */
    FliBuddyEventOk, /* OK button of a widget */
    FliBuddyEventWeightEntered, /* number input, entered_grams is set */
    FliBuddyEventMenuItem = 200, /* + the index of the chosen submenu item */
} FliBuddyEvent;

typedef struct {
    Gui* gui;
    ViewDispatcher* view_dispatcher;
    SceneManager* scene_manager;
    Widget* widget;
    Submenu* submenu;
    NumberInput* number_input;

    Transport* transport;
    TransportKind transport_kind; /* the backend of `transport` */
    AppSettings settings;
    FuriMessageQueue* rx_queue; /* ProtoMessage */
    ProtoMessage rx_decoded; /* transport worker only */
    ProtoMessage rx_msg; /* GUI thread */
    char* tx_buf; /* PROTO_LINE_MAX */

    TagReader* reader;
    TagDump* read_dump;
    char text[FLIBUDDY_TEXT_MAX];
    uint32_t menu_item; /* last chosen submenu item, kept across redraws */
    int32_t entered_grams;

    HostLink link;
    bool port_open;
    AppState state;
    SingleSlotIntentStore intents;
} FliBuddyApp;

/* Stamps the event with the clock, applies it to the state, performs its
 * effect and shows the scene of the new screen (or redraws the current
 * one). */
void flibuddy_reduce(FliBuddyApp* app, const AppEvent* event);

/* Shorthand for events without data. */
void flibuddy_reduce_type(FliBuddyApp* app, AppEventType type);
