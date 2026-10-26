#include <gui/scene_manager.h>

#include "nfc_classify.h"
#include "scenes.h"
#include "flibuddy_app.h"

/* Two views: the text (without a host what the Flipper read itself, with a
 * host its lookup lines) and, behind OK, the menu of actions the result
 * offers. The scene state remembers which one is open; Idle resets it to
 * the text, so a returning EnterWeight lands on the menu again. */
typedef enum {
    ResultViewText,
    ResultViewMenu,
} ResultView;

typedef enum {
    ResultItemWeigh,
    ResultItemMode,
    ResultItemNew,
    ResultItemCreateOnHost,
    ResultItemLinkOnHost,
    ResultItemClose,
} ResultItem;

static void on_item(void* ctx, uint32_t index) {
    FliBuddyApp* app = ctx;
    app->menu_item = index;
    view_dispatcher_send_custom_event(app->view_dispatcher, FliBuddyEventMenuItem + index);
}

static void on_button(GuiButtonType button, InputType type, void* ctx) {
    FliBuddyApp* app = ctx;
    if(button == GuiButtonTypeCenter && type == InputTypeShort) {
        view_dispatcher_send_custom_event(app->view_dispatcher, FliBuddyEventOk);
    }
}

static bool no_host(const FliBuddyApp* app) {
    return app->state.result_kind == AppResultNoHost;
}

static void render_text(FliBuddyApp* app) {
    const AppState* s = &app->state;
    if(no_host(app)) {
        tag_summary_text(&s->scan.tag, app->text, sizeof(app->text));
    } else {
        screen_lines_text(&s->lookup.lines, app->text, sizeof(app->text));
    }
    Widget* widget = app->widget;
    widget_reset(widget);
    widget_add_text_scroll_element(widget, 0, 0, 128, 52, app->text);
    widget_add_button_element(
        widget, GuiButtonTypeCenter, no_host(app) ? "Close" : "Actions", on_button, app);
    view_dispatcher_switch_to_view(app->view_dispatcher, FliBuddyViewWidget);
}

static void add_item(FliBuddyApp* app, ResultItem item, const char* label) {
    submenu_add_item(app->submenu, label, item, on_item, app);
}

static void render_menu(FliBuddyApp* app) {
    const AppState* s = &app->state;
    Submenu* menu = app->submenu;
    submenu_reset(menu);
    submenu_set_header(menu, s->lookup.lines.count > 0 ? s->lookup.lines.line[0] : "Spool");
    switch(s->result_kind) {
    case AppResultFound:
        add_item(app, ResultItemWeigh, "Enter weight");
        add_item(app, ResultItemMode, screen_mode_item(s->mode));
        break;
    case AppResultUnknownPrefill:
        add_item(app, ResultItemNew, "New");
        add_item(app, ResultItemLinkOnHost, "Link on host");
        break;
    case AppResultUnknownBare:
        add_item(app, ResultItemCreateOnHost, "Create on host");
        add_item(app, ResultItemLinkOnHost, "Link on host");
        break;
    case AppResultNoHost:
        break;
    }
    add_item(app, ResultItemClose, "Close");
    submenu_set_selected_item(menu, app->menu_item);
    view_dispatcher_switch_to_view(app->view_dispatcher, FliBuddyViewSubmenu);
}

static void show(FliBuddyApp* app, ResultView view) {
    /* without a host there is nothing to do but close */
    if(no_host(app)) view = ResultViewText;
    scene_manager_set_scene_state(app->scene_manager, FliBuddySceneResult, view);
    if(view == ResultViewMenu) {
        render_menu(app);
    } else {
        render_text(app);
    }
}

static ResultView current_view(FliBuddyApp* app) {
    return scene_manager_get_scene_state(app->scene_manager, FliBuddySceneResult);
}

static void on_menu_item(FliBuddyApp* app, uint32_t item) {
    static const AppEventType events[] = {
        [ResultItemWeigh] = AppEventMenuWeigh,
        [ResultItemMode] = AppEventToggleMode,
        [ResultItemNew] = AppEventMenuNew,
        [ResultItemCreateOnHost] = AppEventMenuCreateOnHost,
        [ResultItemLinkOnHost] = AppEventMenuLinkOnHost,
        [ResultItemClose] = AppEventBack,
    };
    if(item <= ResultItemClose) flibuddy_reduce_type(app, events[item]);
}

void flibuddy_scene_result_on_enter(void* ctx) {
    FliBuddyApp* app = ctx;
    show(app, current_view(app));
}

bool flibuddy_scene_result_on_event(void* ctx, SceneManagerEvent event) {
    FliBuddyApp* app = ctx;
    if(event.type == SceneManagerEventTypeBack) {
        if(current_view(app) == ResultViewMenu) {
            show(app, ResultViewText);
        } else {
            flibuddy_reduce_type(app, AppEventBack);
        }
        return true;
    }
    if(event.type != SceneManagerEventTypeCustom) return false;
    if(event.event == FliBuddyEventOk) {
        if(no_host(app)) {
            flibuddy_reduce_type(app, AppEventBack);
        } else {
            app->menu_item = 0;
            show(app, ResultViewMenu);
        }
        return true;
    }
    if(event.event >= FliBuddyEventMenuItem) {
        on_menu_item(app, event.event - FliBuddyEventMenuItem);
        return true;
    }
    if(event.event == FliBuddyEventRedraw) {
        show(app, current_view(app));
        return true;
    }
    return false;
}

void flibuddy_scene_result_on_exit(void* ctx) {
    FliBuddyApp* app = ctx;
    widget_reset(app->widget);
    submenu_reset(app->submenu);
}
