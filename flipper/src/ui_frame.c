#include "ui_frame.h"

#include <string.h>

#include "nfc_classify.h"
#include "ui_text.h"

/* Append-only text into a fixed buffer; stops quietly when full. */
typedef struct {
    char* out;
    size_t cap;
    size_t len;
} Text;

#define TEXT(buf) text_start((buf), sizeof(buf))

static Text text_start(char* out, size_t cap) {
    out[0] = '\0';
    return (Text){.out = out, .cap = cap, .len = 0};
}

static void put(Text* t, const char* s) {
    while(*s && t->len + 1 < t->cap) {
        t->out[t->len++] = *s++;
        t->out[t->len] = '\0';
    }
}

static void put_uint(Text* t, uint32_t n) {
    char digits[11];
    size_t i = sizeof(digits) - 1;
    digits[i] = '\0';
    do {
        digits[--i] = (char)('0' + n % 10);
        n /= 10;
    } while(n > 0);
    put(t, digits + i);
}

static void put_hex(Text* t, uint32_t n, unsigned digits) {
    static const char hex[] = "0123456789ABCDEF";
    char out[9];
    for(unsigned i = 0; i < digits; i++)
        out[i] = hex[(n >> (4 * (digits - 1 - i))) & 0x0F];
    out[digits] = '\0';
    put(t, out);
}

static void set(char* out, size_t cap, const char* s) {
    Text t = text_start(out, cap);
    put(&t, s);
}

#define SET(buf, s) set((buf), sizeof(buf), (s))

/* ---- facts about the tag and spool on screen ---- */

static bool rgba_of(const AppState* s, uint32_t* rgba) {
    if(s->has_spool) {
        *rgba = s->spool.rgba;
        return s->spool.has_rgba;
    }
    *rgba = s->lookup.tag_info.rgba;
    return s->lookup.has_tag_info && s->lookup.tag_info.has_rgba;
}

/* Line `i` the host sent for a found spool it gave no `spool` for (the
 * protocol's fallback), else NULL. The lines are shown verbatim in order,
 * with no meaning given to a position: the host drops the empty ones. */
static const char* host_line(const AppState* s, uint8_t i) {
    if(s->has_spool || s->lookup.status != ProtoLookupFound) return NULL;
    return i < s->lookup.lines.count && i < PROTO_LINES_MAX ? s->lookup.lines.line[i] : NULL;
}

/* What the tag itself says: the detailed type, else the material. */
static bool local_name(const AppState* s, char out[TAG_BLOCK_TEXT_MAX]) {
    return tag_block_text(&s->scan.tag, TAG_BLOCK_DETAILED_TYPE, out) ||
           tag_block_text(&s->scan.tag, TAG_BLOCK_MATERIAL, out);
}

/* The spool's name from Bambuddy, the host's reading of the tag or the tag
 * itself; "Spool" when none says. The host's `lines` are never a name: the
 * host drops empty ones, so what comes first is not always the name. */
static void put_name(Text* t, const AppState* s) {
    char name[UI_TEXT_MAX];
    name[0] = '\0';
    if(s->has_spool) {
        ui_spool_name(s->spool.material, s->spool.subtype, name, sizeof(name));
    } else if(s->lookup.has_tag_info) {
        ui_spool_name(s->lookup.tag_info.material, s->lookup.tag_info.subtype, name, sizeof(name));
    }
    if(name[0] == '\0') local_name(s, name);
    put(t, name[0] ? name : "Spool");
}

/* "PLA Basic Jade White" */
static void put_name_and_colour(Text* t, const AppState* s) {
    put_name(t, s);
    if(s->has_spool && s->spool.color_name[0]) {
        put(t, " ");
        put(t, s->spool.color_name);
    }
}

static void put_colour(Text* t, const AppState* s) {
    uint32_t rgba;
    if(s->has_spool && s->spool.color_name[0]) {
        put(t, s->spool.color_name);
    } else if(rgba_of(s, &rgba)) {
        put(t, "Color #");
        put_hex(t, rgba >> 8, 6);
    } else {
        put(t, ui_tag_type_name(&s->scan.tag));
    }
}

static void result_title(const AppState* s, char* out, size_t cap) {
    Text t = text_start(out, cap);
    char local[TAG_BLOCK_TEXT_MAX];
    switch(s->result_kind) {
    case AppResultKnown:
        if(host_line(s, 0)) {
            put(&t, host_line(s, 0));
            break;
        }
        put_name(&t, s);
        break;
    case AppResultUnknownPrefill:
        put_name(&t, s);
        break;
    case AppResultUnknownBare:
        put(&t, "Spool tag");
        break;
    case AppResultBlank:
        put(&t, "Blank tag");
        break;
    case AppResultNoHost:
        put(&t, local_name(s, local) ? local : ui_tag_type_name(&s->scan.tag));
        break;
    }
}

static UiIcon transport_icon(const AppState* s, const UiEnv* env) {
    if(s->transport == TransportKindUsb) return UiIconUsb;
    bool blinking = s->ble == AppBleAdvertising && !s->connected && !s->transport_failed;
    return blinking && (env->anim & 1) ? UiIconNone : UiIconBt;
}

/* ---- screens ---- */

static void build_waiting(UiFrame* f, const AppState* s, const UiEnv* env) {
    SET(f->title, "FliBuddy");
    Text t = TEXT(f->note);
    put(&t, "v");
    put(&t, env->version);
    f->line_icon = f->icon;
    t = TEXT(f->line[0]);
    if(s->transport == TransportKindUsb) {
        put(&t, s->transport_failed ? "USB unavailable" : "USB: no host app");
    } else if(s->transport_failed || s->ble == AppBleOff) {
        put(&t, "Bluetooth off");
    } else if(s->ble == AppBleAdvertising) {
        put(&t, "Visible as ");
        put(&t, env->device_name);
    } else {
        put(&t, "Bluetooth: no host app");
    }
    t = TEXT(f->line[1]);
    put(&t, "Waiting for host");
    for(uint32_t i = 0; i < env->anim % 4; i++)
        put(&t, ".");
    SET(f->right, "Settings");
}

static void put_outcome(Text* t, const AppState* s) {
    switch(s->last) {
    case AppOutcomeSaved:
        put(t, "Saved ");
        put_name(t, s);
        if(s->has_spool) {
            put(t, " ");
            put_uint(t, s->spool.remaining);
            put(t, " g");
        }
        break;
    case AppOutcomeAdded:
        put(t, "Added ");
        put_name(t, s);
        break;
    case AppOutcomeMarkedNew:
        put(t, "New ");
        put_name(t, s);
        if(s->has_spool) {
            put(t, " ");
            put_uint(t, s->spool.label);
            put(t, " g");
        }
        break;
    case AppOutcomeMarkedEmpty:
        put(t, "Empty ");
        put_name(t, s);
        break;
    case AppOutcomeDeleted:
        put(t, "Deleted ");
        put_name(t, s);
        break;
    case AppOutcomeNone:
        break;
    }
}

static void build_ready(UiFrame* f, const AppState* s) {
    SET(f->title, "FliBuddy");
    Text t = TEXT(f->bar);
    put_outcome(&t, s);
    if(f->bar[0]) {
        SET(f->line[0], "Next spool");
        SET(f->line[1], "Hold tag to");
        SET(f->line[2], "the back");
    } else {
        SET(f->line[0], "Ready");
        SET(f->line[1], "Hold spool tag");
        SET(f->line[2], "to the back");
    }
    SET(f->right, "Settings");
}

static void build_result(UiFrame* f, const AppState* s) {
    result_title(s, f->title, sizeof(f->title));
    uint32_t rgba;
    if(rgba_of(s, &rgba)) {
        f->mark = UiMarkSwatch;
        f->lum = ui_luminance(rgba);
    }
    Text t = TEXT(f->line[0]);
    if(s->result_kind == AppResultNoHost) {
        put(&t, ui_tag_type_name(&s->scan.tag));
    } else if(host_line(s, 1)) {
        put(&t, host_line(s, 1));
    } else {
        put_colour(&t, s);
    }
    t = TEXT(f->line[1]);
    put(&t, "Tag ");
    char uid[2 * TAG_DUMP_MAX_UID + 1];
    ui_uid_short(s->scan.tag.uid, s->scan.tag.uid_len, uid, sizeof(uid));
    put(&t, uid);
    SET(f->left, "Menu");
    switch(s->result_kind) {
    case AppResultKnown:
        t = TEXT(f->line[2]);
        if(s->has_spool && s->spool.archived) {
            put(&t, "Archived");
        } else if(s->has_spool) {
            put_uint(&t, s->spool.remaining);
            put(&t, " g left of ");
            put_uint(&t, s->spool.label);
        } else if(host_line(s, 2)) {
            put(&t, host_line(s, 2));
        }
        SET(f->center, "Weigh");
        SET(f->right, "New");
        break;
    case AppResultUnknownPrefill:
    case AppResultUnknownBare:
        SET(f->bar, "Not in Bambuddy");
        SET(f->center, s->result_kind == AppResultUnknownPrefill ? "Add" : "Create");
        SET(f->right, "Link");
        break;
    case AppResultBlank:
        SET(f->bar, "No spool data");
        SET(f->center, "Link");
        break;
    case AppResultNoHost:
        SET(f->bar, "No host");
        break;
    }
}

static const char* menu_label(AppMenuItem item) {
    switch(item) {
    case AppMenuWeigh:
        return "Weigh";
    case AppMenuMarkNew:
        return "Mark as new";
    case AppMenuMarkEmpty:
        return "Mark as empty";
    case AppMenuRelink:
        return "Relink on host";
    case AppMenuDetails:
        return "Tag details";
    case AppMenuDelete:
        return "Delete spool";
    case AppMenuAddNew:
        return "Add new";
    case AppMenuAddAndWeigh:
        return "Add and weigh";
    case AppMenuCreateOnHost:
        return "Create on host";
    case AppMenuLinkOnHost:
        return "Link on host";
    }
    return "";
}

static void build_menu(UiFrame* f, const AppState* s) {
    result_title(s, f->title, sizeof(f->title));
    AppMenuItem items[APP_MENU_MAX];
    f->count = app_menu_items(s, items);
    for(uint8_t i = 0; i < f->count; i++)
        SET(f->item[i], menu_label(items[i]));
    f->sel = s->sel;
    f->top = s->top;
}

static void build_details(UiFrame* f, const AppState* s) {
    const TagDump* tag = &s->scan.tag;
    SET(f->title, "Tag details");
    uint8_t n = 0;
    SET(f->key[n], "Type");
    SET(f->line[n++], ui_tag_type_name(tag));
    SET(f->key[n], "UID");
    ui_uid_colons(tag->uid, tag->uid_len, f->line[n++], UI_TEXT_MAX);
    SET(f->key[n], "Data");
    Text t = TEXT(f->line[n++]);
    if(tag->type == TagTypeMfc) {
        put_uint(&t, tag_sectors_read(tag));
        put(&t, "/16 sectors");
    } else {
        put_uint(&t, tag->page_count);
        put(&t, " pages");
    }
    uint32_t rgba;
    if(rgba_of(s, &rgba)) {
        SET(f->key[n], "RGBA");
        t = TEXT(f->line[n++]);
        put_hex(&t, rgba, 8);
    }
    bool has_label = s->has_spool || (s->lookup.has_tag_info && s->lookup.tag_info.has_label);
    if(has_label) {
        SET(f->key[n], "Label");
        t = TEXT(f->line[n++]);
        put_uint(&t, s->has_spool ? s->spool.label : s->lookup.tag_info.label);
        put(&t, " g");
    }
    f->count = n;
}

static void build_confirm_delete(UiFrame* f, const AppState* s) {
    SET(f->title, "Delete spool?");
    Text t = TEXT(f->line[0]);
    put_name_and_colour(&t, s);
    SET(f->line[1], "Removes it from");
    SET(f->line[2], "Bambuddy for good.");
    SET(f->left, "Cancel");
    SET(f->right, "Delete");
}

static void build_weight(UiFrame* f, const AppState* s) {
    SET(f->title, "Weight");
    memcpy(f->digit, s->weight.digit, sizeof(f->digit));
    f->cursor = s->weight.cursor;
    f->net = s->mode == WeightModeNet;
    f->refused = app_weight_below_core(s);
    unsigned grams = app_weight_grams(s);
    unsigned core = app_weight_core(s);
    Text t = TEXT(f->line[0]);
    if(f->refused) {
        SET(f->bar, "Below core weight");
    } else if(f->net) {
        put(&t, "Saves ");
        put_uint(&t, grams);
        put(&t, " g left");
    } else if(core > 0) {
        put(&t, "Net ");
        put_uint(&t, grams - core);
        put(&t, " g - core ");
        put_uint(&t, core);
    } else {
        put(&t, "Core weight unknown");
    }
    SET(f->center, "Save");
}

static void build_busy(UiFrame* f, const AppState* s) {
    const Intent* held = &s->held;
    switch(held->action) {
    case IntentActionWeigh:
        SET(f->title, "Saving");
        break;
    case IntentActionNew:
        SET(f->title, "Adding");
        break;
    case IntentActionDelete:
        SET(f->title, "Deleting");
        break;
    default:
        SET(f->title, "Updating");
        break;
    }
    Text t = TEXT(f->line[0]);
    put_name(&t, s);
    if(held->action == IntentActionWeigh) {
        unsigned core = app_weight_core(s);
        bool net = held->mode == WeightModeNet;
        if(net || (core > 0 && held->grams >= core)) {
            put(&t, " - ");
            put_uint(&t, net ? held->grams : held->grams - core);
            put(&t, " g");
        }
    }
    SET(f->line[1], "Waiting for Bambuddy");
}

static void build_saved(UiFrame* f, const AppState* s) {
    SET(f->title, "Saved");
    Text t = TEXT(f->line[0]);
    put_name(&t, s);
    if(s->has_spool) {
        put(&t, " - ");
        put_uint(&t, s->spool.remaining);
        put(&t, " g left");
    }
}

static void build_toast(UiFrame* f, const AppState* s, const UiEnv* env) {
    Text t = TEXT(f->line[0]);
    put_name_and_colour(&t, s);
    t = TEXT(f->line[1]);
    switch(s->toast) {
    case AppToastAdded:
        SET(f->title, "Added to Bambuddy");
        if(s->has_spool) {
            put(&t, "Spool #");
            put_uint(&t, (uint32_t)s->spool.id);
            put(&t, " - ");
            put_uint(&t, s->spool.remaining);
            put(&t, " g");
        }
        SET(f->center, "Weigh");
        SET(f->right, "Next");
        return; /* no deadline */
    case AppToastMarkedNew:
        SET(f->title, "Marked as new");
        put_uint(&t, s->spool.label);
        put(&t, " g left - full");
        SET(f->left, "Undo");
        SET(f->center, "Weigh");
        break;
    case AppToastMarkedEmpty:
        SET(f->title, "Marked as empty");
        put(&t, "0 g left - archived");
        SET(f->left, "Undo");
        break;
    case AppToastDeleted:
        SET(f->title, "Deleted");
        put(&t, "Tag is free to reuse");
        break;
    }
    uint32_t left = app_timer_left_ms(s, env->now_ms);
    f->progress = (uint16_t)(left * UI_TOAST_MAX / APP_TOAST_MS);
    t = TEXT(f->line[2]);
    put(&t, "Next spool in ");
    put_uint(&t, (left + 999) / 1000);
    put(&t, " s");
}

static void build_link(UiFrame* f, const AppState* s) {
    bool create = s->held.action == IntentActionCreateOnHost;
    SET(f->title, create ? "Create on host" : "Link tag");
    SET(f->line[0], create ? "Finish the spool in" : "Pick the spool in");
    SET(f->line[1], "FliBuddy on host");
    SET(f->left, "Cancel");
}

static const char* host_error_title(IntentAction action) {
    switch(action) {
    case IntentActionWeigh:
        return "Not saved";
    case IntentActionNew:
        return "Not added";
    case IntentActionDelete:
        return "Not deleted";
    case IntentActionFull:
    case IntentActionEmpty:
        return "Not updated";
    case IntentActionLinkOnHost:
    case IntentActionCreateOnHost:
        break;
    }
    return "Not linked";
}

/* The host's lines and error, one per line, or `fallback`. */
static void put_host_text(Text* t, const ProtoLines* lines, const char* error, const char* fallback) {
    for(uint8_t i = 0; i < lines->count && i < PROTO_LINES_MAX; i++) {
        if(t->len > 0) put(t, "\n");
        put(t, lines->line[i]);
    }
    if(error[0]) {
        if(t->len > 0) put(t, "\n");
        put(t, error);
    }
    if(t->len == 0) put(t, fallback);
}

static void build_error(UiFrame* f, const AppState* s) {
    Text t = TEXT(f->body);
    switch(s->error) {
    case AppErrorReadFailed:
        SET(f->title, "Tag not read");
        put(&t, "Hold the tag still against the back and try again.");
        break;
    case AppErrorLookup:
        SET(f->title, "Lookup failed");
        put_host_text(
            &t, &s->lookup.lines, s->lookup.error, "The host could not look the tag up.");
        break;
    case AppErrorHost:
        SET(f->title, host_error_title(s->held.action));
        put_host_text(&t, &s->result.lines, s->result.error, "Bambuddy did not take the change.");
        break;
    case AppErrorTimeout:
        SET(f->title, "No host reply");
        put(&t, "No reply in 10 s. Open FliBuddy on the Mac or iPhone.");
        break;
    case AppErrorHostLost:
        SET(f->title, "Host lost");
        put(&t, "The host went away before it answered.");
        break;
    case AppErrorSendFailed:
        SET(f->title, "Not sent");
        put(&t, "Could not send to the host.");
        break;
    case AppErrorNone:
        SET(f->title, "Error");
        break;
    }
    SET(f->left, "Back");
    if(s->retryable && s->connected) SET(f->right, "Retry");
}

static const char* on_off(bool on) {
    return on ? "On" : "Off";
}

static const char* feedback_name(AppFeedback feedback) {
    switch(feedback) {
    case AppFeedbackVibroLed:
        return "Vibro+LED";
    case AppFeedbackLed:
        return "LED";
    case AppFeedbackOff:
        break;
    }
    return "Off";
}

static void build_settings(UiFrame* f, const AppState* s, const UiEnv* env) {
    static const char* const labels[AppSettingCount] = {
        [AppSettingConnection] = "Connection",
        [AppSettingAutosave] = "Auto-save new",
        [AppSettingFeedback] = "Feedback",
        [AppSettingSound] = "Sound",
        [AppSettingVersion] = "Version",
    };
    const AppSettings* st = &s->settings;
    SET(f->title, "Settings");
    f->count = AppSettingCount;
    for(uint8_t i = 0; i < AppSettingCount; i++)
        SET(f->item[i], labels[i]);
    SET(f->value[AppSettingConnection],
        app_settings_transport(st) == TransportKindBluetooth ? "Bluetooth" : "USB");
    SET(f->value[AppSettingAutosave], on_off(app_settings_autosave(st)));
    SET(f->value[AppSettingFeedback], feedback_name(app_settings_feedback(st)));
    SET(f->value[AppSettingSound], on_off(app_settings_sound(st)));
    SET(f->value[AppSettingVersion], env->version);
    f->fixed[AppSettingVersion] = true;
    f->sel = s->sel;
    f->top = s->top;
}

static void build_about(UiFrame* f, const AppState* s, const UiEnv* env) {
    SET(f->title, "FliBuddy");
    SET(f->line[0], "for Bambuddy");
    Text t = TEXT(f->line[1]);
    put(&t, "Version ");
    put(&t, env->version);
    t = TEXT(f->line[2]);
    put(&t, "Protocol ");
    put_uint(&t, PROTO_VERSION);
    put(&t, " - fw ");
    put(&t, env->firmware);
    t = TEXT(f->line[3]);
    if(s->connected) {
        put(&t, "Host: ");
        put(&t, env->host_app[0] ? env->host_app : "connected");
        put(&t, s->transport == TransportKindBluetooth ? " - BLE" : " - USB");
    } else {
        put(&t, "Host: not connected");
    }
}

void ui_frame_build(UiFrame* f, const AppState* s, const UiEnv* env) {
    memset(f, 0, sizeof(*f));
    f->screen = s->screen;
    f->kind = s->result_kind;
    f->toast = s->toast;
    f->anim = (uint8_t)env->anim;
    f->icon = transport_icon(s, env);
    char local[TAG_BLOCK_TEXT_MAX];
    switch(s->screen) {
    case AppScreenWaiting:
        build_waiting(f, s, env);
        break;
    case AppScreenReady:
        build_ready(f, s);
        break;
    case AppScreenReading:
        SET(f->title, "Reading tag");
        SET(f->line[0], "Keep still");
        break;
    case AppScreenLookingUp:
        SET(f->title, "Looking up");
        if(local_name(s, local)) SET(f->line[0], local);
        SET(f->line[1], "Asking the host");
        break;
    case AppScreenResult:
        build_result(f, s);
        break;
    case AppScreenMenu:
        build_menu(f, s);
        break;
    case AppScreenDetails:
        build_details(f, s);
        break;
    case AppScreenConfirmDelete:
        build_confirm_delete(f, s);
        break;
    case AppScreenWeight:
        build_weight(f, s);
        break;
    case AppScreenBusy:
        build_busy(f, s);
        break;
    case AppScreenSaved:
        build_saved(f, s);
        break;
    case AppScreenToast:
        build_toast(f, s, env);
        break;
    case AppScreenLinkOnHost:
        build_link(f, s);
        break;
    case AppScreenError:
        build_error(f, s);
        break;
    case AppScreenSettings:
        build_settings(f, s, env);
        break;
    case AppScreenAbout:
        build_about(f, s, env);
        break;
    }
}
