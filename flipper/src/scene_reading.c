#include <gui/scene_manager.h>

#include "scenes.h"
#include "flibuddy_app.h"

/* Progress while the NFC reads the tag or the host looks it up. */
static void render(FliBuddyApp* app) {
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

void flibuddy_scene_reading_on_enter(void* ctx) {
    FliBuddyApp* app = ctx;
    render(app);
    view_dispatcher_switch_to_view(app->view_dispatcher, FliBuddyViewWidget);
}

bool flibuddy_scene_reading_on_event(void* ctx, SceneManagerEvent event) {
    FliBuddyApp* app = ctx;
    if(event.type == SceneManagerEventTypeBack) {
        /* stops the NFC (flibuddy_app.c, sync_reader) */
        flibuddy_reduce_type(app, AppEventBack);
        return true;
    }
    if(event.type == SceneManagerEventTypeCustom && event.event == FliBuddyEventRedraw) {
        render(app);
        return true;
    }
    return false;
}

void flibuddy_scene_reading_on_exit(void* ctx) {
    FliBuddyApp* app = ctx;
    widget_reset(app->widget);
}
