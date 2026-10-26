#include <gui/scene_manager.h>

#include "scenes.h"
#include "flibuddy_app.h"

static void on_button(GuiButtonType button, InputType type, void* ctx) {
    FliBuddyApp* app = ctx;
    if(button == GuiButtonTypeCenter && type == InputTypeShort) {
        view_dispatcher_send_custom_event(app->view_dispatcher, FliBuddyEventOk);
    }
}

/* The status line sits under the title: the OK button takes the bottom. */
static void render(FliBuddyApp* app) {
    Widget* widget = app->widget;
    widget_reset(widget);
    widget_add_string_element(widget, 64, 2, AlignCenter, AlignTop, FontPrimary, "FliBuddy");
    widget_add_string_element(
        widget, 64, 14, AlignCenter, AlignTop, FontSecondary, screen_status_text(&app->state));
    widget_add_string_multiline_element(
        widget, 64, 37, AlignCenter, AlignCenter, FontSecondary, "Hold a spool\nto the back");
    widget_add_button_element(widget, GuiButtonTypeCenter, "Transport", on_button, app);
}

void flibuddy_scene_idle_on_enter(void* ctx) {
    FliBuddyApp* app = ctx;
    /* the next result opens on its text */
    scene_manager_set_scene_state(app->scene_manager, FliBuddySceneResult, 0);
    app->menu_item = 0;
    render(app);
    view_dispatcher_switch_to_view(app->view_dispatcher, FliBuddyViewWidget);
}

bool flibuddy_scene_idle_on_event(void* ctx, SceneManagerEvent event) {
    FliBuddyApp* app = ctx;
    if(event.type != SceneManagerEventTypeCustom) return false;
    if(event.event == FliBuddyEventRedraw) {
        render(app);
        return true;
    }
    if(event.event == FliBuddyEventOk) {
        flibuddy_reduce_type(app, AppEventMenuTransport);
        return true;
    }
    return false;
}

void flibuddy_scene_idle_on_exit(void* ctx) {
    FliBuddyApp* app = ctx;
    widget_reset(app->widget);
}
