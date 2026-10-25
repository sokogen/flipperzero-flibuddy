#include <gui/scene_manager.h>

#include "scenes.h"
#include "spoolbuddy_app.h"

/* Progress while the NFC reads the tag or the host looks it up. */
static void render(SpoolBuddyApp* app) {
    const char* title = "Reading tag";
    const char* hint = "Keep the spool still";
    switch(app->state.screen) {
    case AppScreenWaitingLookup:
        title = "Looking up";
        hint = "Waiting for the host";
        break;
    default:
        break;
    }
    Widget* widget = app->widget;
    widget_reset(widget);
    widget_add_string_element(widget, 64, 22, AlignCenter, AlignCenter, FontPrimary, title);
    widget_add_string_element(widget, 64, 40, AlignCenter, AlignCenter, FontSecondary, hint);
}

void spoolbuddy_scene_reading_on_enter(void* ctx) {
    SpoolBuddyApp* app = ctx;
    render(app);
    view_dispatcher_switch_to_view(app->view_dispatcher, SpoolBuddyViewWidget);
}

bool spoolbuddy_scene_reading_on_event(void* ctx, SceneManagerEvent event) {
    SpoolBuddyApp* app = ctx;
    if(event.type == SceneManagerEventTypeBack) {
        /* stops the NFC (spoolbuddy_app.c, sync_reader) */
        spoolbuddy_reduce_type(app, AppEventBack);
        return true;
    }
    if(event.type == SceneManagerEventTypeCustom && event.event == SpoolBuddyEventRedraw) {
        render(app);
        return true;
    }
    return false;
}

void spoolbuddy_scene_reading_on_exit(void* ctx) {
    SpoolBuddyApp* app = ctx;
    widget_reset(app->widget);
}
