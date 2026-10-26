#include <gui/scene_manager.h>

#include "scenes.h"
#include "flibuddy_app.h"

/* An intent is in flight: what was sent, until the host's `result` or
 * APP_RESULT_TIMEOUT_MS (flibuddy_app.c, on_tick). Back cannot cancel
 * it. */
static void render(FliBuddyApp* app) {
    screen_intent_text(intent_store_current(app->state.intents), app->text, sizeof(app->text));
    Widget* widget = app->widget;
    widget_reset(widget);
    widget_add_string_element(widget, 64, 14, AlignCenter, AlignCenter, FontPrimary, "Saving");
    widget_add_string_element(widget, 64, 32, AlignCenter, AlignCenter, FontSecondary, app->text);
    widget_add_string_element(
        widget, 64, 50, AlignCenter, AlignCenter, FontSecondary, "Waiting for the host");
}

void flibuddy_scene_waiting_on_enter(void* ctx) {
    FliBuddyApp* app = ctx;
    render(app);
    view_dispatcher_switch_to_view(app->view_dispatcher, FliBuddyViewWidget);
}

bool flibuddy_scene_waiting_on_event(void* ctx, SceneManagerEvent event) {
    FliBuddyApp* app = ctx;
    if(event.type == SceneManagerEventTypeBack) {
        flibuddy_reduce_type(app, AppEventBack); /* ignored while waiting */
        return true;
    }
    if(event.type == SceneManagerEventTypeCustom && event.event == FliBuddyEventRedraw) {
        render(app);
        return true;
    }
    return false;
}

void flibuddy_scene_waiting_on_exit(void* ctx) {
    FliBuddyApp* app = ctx;
    widget_reset(app->widget);
}
