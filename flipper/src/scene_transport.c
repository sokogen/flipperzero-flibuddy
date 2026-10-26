#include <gui/scene_manager.h>

#include "scenes.h"
#include "spoolbuddy_app.h"

/* The transport menu: the item index is the TransportKind; the one in use
 * is selected. Choosing goes through the reducer, which returns to Idle and
 * has the app switch the transport when the kind changed. */

static void on_item(void* ctx, uint32_t index) {
    SpoolBuddyApp* app = ctx;
    view_dispatcher_send_custom_event(app->view_dispatcher, SpoolBuddyEventMenuItem + index);
}

static void add_item(SpoolBuddyApp* app, TransportKind kind) {
    submenu_add_item(app->submenu, screen_transport_name(kind), kind, on_item, app);
}

void spoolbuddy_scene_transport_on_enter(void* ctx) {
    SpoolBuddyApp* app = ctx;
    Submenu* menu = app->submenu;
    submenu_reset(menu);
    submenu_set_header(menu, "Transport");
    add_item(app, TransportKindUsb);
    add_item(app, TransportKindBluetooth);
    submenu_set_selected_item(menu, app->state.transport);
    view_dispatcher_switch_to_view(app->view_dispatcher, SpoolBuddyViewSubmenu);
}

bool spoolbuddy_scene_transport_on_event(void* ctx, SceneManagerEvent event) {
    SpoolBuddyApp* app = ctx;
    if(event.type == SceneManagerEventTypeBack) {
        spoolbuddy_reduce_type(app, AppEventBack);
        return true;
    }
    if(event.type != SceneManagerEventTypeCustom) return false;
    if(event.event >= SpoolBuddyEventMenuItem) {
        spoolbuddy_reduce(
            app,
            &(AppEvent){
                .type = AppEventTransportChosen,
                .transport = (TransportKind)(event.event - SpoolBuddyEventMenuItem)});
        return true;
    }
    /* nothing on the menu depends on the connection */
    return event.event == SpoolBuddyEventRedraw;
}

void spoolbuddy_scene_transport_on_exit(void* ctx) {
    SpoolBuddyApp* app = ctx;
    submenu_reset(app->submenu);
}
