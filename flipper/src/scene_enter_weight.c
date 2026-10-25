#include <gui/scene_manager.h>

#include "scenes.h"
#include "spoolbuddy_app.h"

/* The weight of a found spool, pre-filled from the host's defaults in the
 * session's mode (net or gross, toggled on the Result menu). OK sends the
 * `weigh` intent; Back returns to the menu. */

static void on_number(void* ctx, int32_t number) {
    SpoolBuddyApp* app = ctx;
    app->entered_grams = number;
    view_dispatcher_send_custom_event(app->view_dispatcher, SpoolBuddyEventWeightEntered);
}

void spoolbuddy_scene_enter_weight_on_enter(void* ctx) {
    SpoolBuddyApp* app = ctx;
    const AppState* s = &app->state;
    number_input_set_header_text(app->number_input, screen_weight_header(s->mode));
    number_input_set_result_callback(
        app->number_input, on_number, app, s->weight_default, 0, PROTO_GRAMS_MAX);
    view_dispatcher_switch_to_view(app->view_dispatcher, SpoolBuddyViewNumberInput);
}

bool spoolbuddy_scene_enter_weight_on_event(void* ctx, SceneManagerEvent event) {
    SpoolBuddyApp* app = ctx;
    if(event.type == SceneManagerEventTypeBack) {
        spoolbuddy_reduce_type(app, AppEventBack);
        return true;
    }
    if(event.type != SceneManagerEventTypeCustom) return false;
    if(event.event == SpoolBuddyEventWeightEntered) {
        int32_t grams = app->entered_grams;
        if(grams >= 0 && grams <= PROTO_GRAMS_MAX) {
            spoolbuddy_reduce(
                app, &(AppEvent){.type = AppEventWeightEntered, .grams = (uint16_t)grams});
        }
        return true;
    }
    /* a redraw would reset the digits being typed; the screen shows no
     * state that changes while it is open */
    return event.event == SpoolBuddyEventRedraw;
}

void spoolbuddy_scene_enter_weight_on_exit(void* ctx) {
    UNUSED(ctx);
}
