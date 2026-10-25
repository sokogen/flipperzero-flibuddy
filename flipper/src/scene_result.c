#include <gui/scene_manager.h>

#include "nfc_classify.h"
#include "scenes.h"
#include "spoolbuddy_app.h"

/* Without a host: what the Flipper read itself. With a host: its lookup
 * lines. Back closes. */
static void build_text(SpoolBuddyApp* app) {
    const AppState* s = &app->state;
    if(s->result_kind == AppResultNoHost) {
        tag_summary_text(&s->scan.tag, app->text, sizeof(app->text));
        return;
    }
    app->text[0] = '\0';
    for(uint8_t i = 0; i < s->lookup.lines.count; i++) {
        if(i > 0) strlcat(app->text, "\n", sizeof(app->text));
        strlcat(app->text, s->lookup.lines.line[i], sizeof(app->text));
    }
}

static void render(SpoolBuddyApp* app) {
    build_text(app);
    Widget* widget = app->widget;
    widget_reset(widget);
    widget_add_text_scroll_element(widget, 0, 0, 128, 64, app->text);
}

void spoolbuddy_scene_result_on_enter(void* ctx) {
    SpoolBuddyApp* app = ctx;
    render(app);
    view_dispatcher_switch_to_view(app->view_dispatcher, SpoolBuddyViewWidget);
}

bool spoolbuddy_scene_result_on_event(void* ctx, SceneManagerEvent event) {
    SpoolBuddyApp* app = ctx;
    if(event.type == SceneManagerEventTypeBack) {
        spoolbuddy_reduce_type(app, AppEventBack);
        return true;
    }
    if(event.type == SceneManagerEventTypeCustom && event.event == SpoolBuddyEventRedraw) {
        render(app);
        return true;
    }
    return false;
}

void spoolbuddy_scene_result_on_exit(void* ctx) {
    SpoolBuddyApp* app = ctx;
    widget_reset(app->widget);
}
