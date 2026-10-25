/* The SpoolBuddy FAP: GUI, scenes and the glue between the transport, the
 * hello handshake (host_link.h) and the screen reducer (app_state.h).
 *
 * Threads: the GUI thread owns everything below except rx_decoded, which
 * the transport worker fills and hands over through rx_queue. Every source
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
#include "proto_decode.h"
#include "transport.h"

#define SPOOLBUDDY_HELLO_APP "spoolbuddy-fap/0.1.0"

typedef enum {
    SpoolBuddyViewWidget,
} SpoolBuddyView;

typedef enum {
    SpoolBuddyEventRx = 100, /* messages wait in rx_queue */
    SpoolBuddyEventStatus, /* the connection status changed */
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

    HostLink link;
    bool port_open;
    AppState state;
    SingleSlotIntentStore intents;
} SpoolBuddyApp;
