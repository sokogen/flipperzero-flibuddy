#include <gui/scene_manager.h>

#include "scenes.h"
#include "spoolbuddy_app.h"

static const char* error_text(const AppState* s) {
    switch(s->error) {
    case AppErrorReadFailed:
        return "Could not read the tag";
    case AppErrorLookup:
        return s->lookup.error[0] ? s->lookup.error : "Lookup failed";
    case AppErrorHost:
        return s->result.error[0] ? s->result.error : "Not saved";
    case AppErrorTimeout:
        return "No answer from the host";
    case AppErrorHostLost:
        return "Host disconnected";
    case AppErrorNone:
        break;
    }
    return "Error";
}

/* Done: the host's result lines. Error: what went wrong. */
static void build_text(SpoolBuddyApp* app) {
    const AppState* s = &app->state;
    if(s->screen == AppScreenError) {
        snprintf(app->text, sizeof(app->text), "\e#Error\n%s", error_text(s));
        return;
    }
    app->text[0] = '\0';
    for(uint8_t i = 0; i < s->result.lines.count; i++) {
        if(i > 0) strlcat(app->text, "\n", sizeof(app->text));
        strlcat(app->text, s->result.lines.line[i], sizeof(app->text));
    }
}

static void on_button(GuiButtonType button, InputType type, void* ctx) {
    SpoolBuddyApp* app = ctx;
    if(button == GuiButtonTypeCenter && type == InputTypeShort) {
        view_dispatcher_send_custom_event(app->view_dispatcher, SpoolBuddyEventOk);
    }
}

static void render(SpoolBuddyApp* app) {
    build_text(app);
    Widget* widget = app->widget;
    widget_reset(widget);
    widget_add_text_scroll_element(widget, 0, 0, 128, 52, app->text);
    widget_add_button_element(widget, GuiButtonTypeCenter, "OK", on_button, app);
}

void spoolbuddy_scene_done_on_enter(void* ctx) {
    SpoolBuddyApp* app = ctx;
    render(app);
    view_dispatcher_switch_to_view(app->view_dispatcher, SpoolBuddyViewWidget);
}

bool spoolbuddy_scene_done_on_event(void* ctx, SceneManagerEvent event) {
    SpoolBuddyApp* app = ctx;
    if(event.type == SceneManagerEventTypeBack ||
       (event.type == SceneManagerEventTypeCustom && event.event == SpoolBuddyEventOk)) {
        spoolbuddy_reduce_type(app, AppEventBack);
        return true;
    }
    if(event.type == SceneManagerEventTypeCustom && event.event == SpoolBuddyEventRedraw) {
        render(app);
        return true;
    }
    return false;
}

void spoolbuddy_scene_done_on_exit(void* ctx) {
    SpoolBuddyApp* app = ctx;
    widget_reset(app->widget);
}
