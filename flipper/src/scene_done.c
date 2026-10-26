#include <gui/scene_manager.h>

#include "scenes.h"
#include "flibuddy_app.h"

/* Done: the host's result lines. Error: what went wrong, under a title. */
static void build_text(FliBuddyApp* app) {
    static const char title[] = "\e#Error\n";
    size_t head = 0;
    if(app->state.screen == AppScreenError) {
        memcpy(app->text, title, sizeof(title) - 1);
        head = sizeof(title) - 1;
    }
    screen_outcome_text(&app->state, app->text + head, sizeof(app->text) - head);
}

static void on_button(GuiButtonType button, InputType type, void* ctx) {
    FliBuddyApp* app = ctx;
    if(button == GuiButtonTypeCenter && type == InputTypeShort) {
        view_dispatcher_send_custom_event(app->view_dispatcher, FliBuddyEventOk);
    }
}

static void render(FliBuddyApp* app) {
    build_text(app);
    Widget* widget = app->widget;
    widget_reset(widget);
    widget_add_text_scroll_element(widget, 0, 0, 128, 52, app->text);
    widget_add_button_element(widget, GuiButtonTypeCenter, "OK", on_button, app);
}

void flibuddy_scene_done_on_enter(void* ctx) {
    FliBuddyApp* app = ctx;
    render(app);
    view_dispatcher_switch_to_view(app->view_dispatcher, FliBuddyViewWidget);
}

bool flibuddy_scene_done_on_event(void* ctx, SceneManagerEvent event) {
    FliBuddyApp* app = ctx;
    if(event.type == SceneManagerEventTypeBack ||
       (event.type == SceneManagerEventTypeCustom && event.event == FliBuddyEventOk)) {
        flibuddy_reduce_type(app, AppEventBack);
        return true;
    }
    if(event.type == SceneManagerEventTypeCustom && event.event == FliBuddyEventRedraw) {
        render(app);
        return true;
    }
    return false;
}

void flibuddy_scene_done_on_exit(void* ctx) {
    FliBuddyApp* app = ctx;
    widget_reset(app->widget);
}
