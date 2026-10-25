#include <gui/scene_manager.h>

#include "scenes.h"
#include "spoolbuddy_app.h"

static void render(SpoolBuddyApp* app) {
    Widget* widget = app->widget;
    widget_reset(widget);
    widget_add_string_element(widget, 64, 2, AlignCenter, AlignTop, FontPrimary, "SpoolBuddy");
    widget_add_string_multiline_element(
        widget, 64, 32, AlignCenter, AlignCenter, FontSecondary, "Hold a spool\nto the back");
    widget_add_string_element(
        widget,
        64,
        63,
        AlignCenter,
        AlignBottom,
        FontSecondary,
        host_link_status_text(&app->link));
}

void spoolbuddy_scene_idle_on_enter(void* ctx) {
    SpoolBuddyApp* app = ctx;
    /* the next result opens on its text */
    scene_manager_set_scene_state(app->scene_manager, SpoolBuddySceneResult, 0);
    app->menu_item = 0;
    render(app);
    view_dispatcher_switch_to_view(app->view_dispatcher, SpoolBuddyViewWidget);
}

bool spoolbuddy_scene_idle_on_event(void* ctx, SceneManagerEvent event) {
    SpoolBuddyApp* app = ctx;
    if(event.type == SceneManagerEventTypeCustom && event.event == SpoolBuddyEventRedraw) {
        render(app);
        return true;
    }
    return false;
}

void spoolbuddy_scene_idle_on_exit(void* ctx) {
    SpoolBuddyApp* app = ctx;
    widget_reset(app->widget);
}
