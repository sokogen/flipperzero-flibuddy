#include <gui/scene_manager.h>

#include "scenes.h"
#include "spoolbuddy_app.h"

static void on_button(GuiButtonType button, InputType type, void* ctx) {
    SpoolBuddyApp* app = ctx;
    if(button == GuiButtonTypeCenter && type == InputTypeShort) {
        view_dispatcher_send_custom_event(app->view_dispatcher, SpoolBuddyEventOk);
    }
}

/* The status line sits under the title: the OK button takes the bottom. */
static void render(SpoolBuddyApp* app) {
    Widget* widget = app->widget;
    widget_reset(widget);
    widget_add_string_element(widget, 64, 2, AlignCenter, AlignTop, FontPrimary, "SpoolBuddy");
    widget_add_string_element(
        widget, 64, 14, AlignCenter, AlignTop, FontSecondary, screen_status_text(&app->state));
    widget_add_string_multiline_element(
        widget, 64, 37, AlignCenter, AlignCenter, FontSecondary, "Hold a spool\nto the back");
    widget_add_button_element(widget, GuiButtonTypeCenter, "Transport", on_button, app);
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
    if(event.type != SceneManagerEventTypeCustom) return false;
    if(event.event == SpoolBuddyEventRedraw) {
        render(app);
        return true;
    }
    if(event.event == SpoolBuddyEventOk) {
        spoolbuddy_reduce_type(app, AppEventMenuTransport);
        return true;
    }
    return false;
}

void spoolbuddy_scene_idle_on_exit(void* ctx) {
    SpoolBuddyApp* app = ctx;
    widget_reset(app->widget);
}
