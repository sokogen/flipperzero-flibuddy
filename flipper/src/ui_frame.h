/* What a Flipper screen shows, built from the app state without the SDK
 * (docs/design/flipper-ui-spec.md; the screens are numbered there).
 *
 * The draw callback runs on the GUI thread, so it never reads AppState:
 * the app builds a UiFrame after every state change and every tick into
 * the view's locked model, and ui_draw.c lays the frame out. All wording
 * and every choice of what to show live here and are tested on the host;
 * the drawing code only places text, icons and shapes, fits text to the
 * width and wraps `body`.
 *
 * Which fields a screen uses:
 *
 *   all         screen, anim, icon (the header's transport icon), title
 *   Waiting     note (version), line_icon + line[0] (transport), line[1]
 *   Ready       bar (last outcome, "" none), line[0..2], right
 *   Reading     line[0]
 *   LookingUp   line[0] (material from the tag, "" when unknown), line[1]
 *   Result      kind, mark + lum, line[0..2], in_base (a check before
 *               line[1]), level (remaining bar, -1 none) or bar, chips
 *   Menu        item[], count, sel, top
 *   Details     key[] / line[] rows (count)
 *   Confirm     line[0..2], left / right
 *   Weight      digit[], cursor, net, refused, line[0] or bar, center
 *   Busy        line[0..1]
 *   Saved       line[0]
 *   Toast       toast, line[0..2], progress, left / center / right
 *   LinkOnHost  line[0..1], left
 *   Error       body (wrapped, at most three lines), left / right,
 *               progress (a failed read's countdown, 0 none)
 *   Settings    item[] / value[] / fixed[], count, sel, top
 *   About       line[0..3]
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "app_state.h"

#define UI_TEXT_MAX  48
#define UI_ITEM_MAX  24
#define UI_KEY_MAX   8
#define UI_LINES     5
#define UI_LIST_MAX  6 /* APP_MENU_MAX and AppSettingCount */
#define UI_BODY_MAX  (PROTO_LINES_MAX * (PROTO_LINE_CHARS + 1) + PROTO_ERROR_MAX + 1)
#define UI_TOAST_MAX 1000 /* progress when the whole toast time is left */

typedef enum {
    UiIconNone, /* also the dark phase of a blinking icon */
    UiIconUsb,
    UiIconBt,
} UiIcon;

/* The mark left of a result's title. */
typedef enum {
    UiMarkBlank, /* an empty circle: no colour known */
    UiMarkSwatch, /* a disc dithered by `lum` */
} UiMark;

/* What the frame needs besides the state. */
typedef struct {
    uint32_t now_ms; /* for the toast's progress */
    uint32_t anim; /* animation step, one per tick */
    const char* version; /* "0.1.0" */
    const char* firmware; /* "1.5.1" */
    const char* device_name; /* the Bluetooth name */
    const char* host_app; /* the host's hello `app`, "" before one */
} UiEnv;

typedef struct {
    AppScreen screen;
    AppResultKind kind;
    AppToast toast;
    uint8_t anim;
    UiIcon icon;
    UiIcon line_icon;
    char title[UI_TEXT_MAX];
    char note[UI_ITEM_MAX];
    char line[UI_LINES][UI_TEXT_MAX];
    char key[UI_LINES][UI_KEY_MAX];
    char bar[UI_TEXT_MAX];
    char body[UI_BODY_MAX];
    char left[UI_ITEM_MAX];
    char center[UI_ITEM_MAX];
    char right[UI_ITEM_MAX];
    UiMark mark;
    uint8_t lum;
    uint8_t count;
    uint8_t sel;
    uint8_t top;
    char item[UI_LIST_MAX][UI_ITEM_MAX];
    char value[UI_LIST_MAX][UI_ITEM_MAX];
    bool fixed[UI_LIST_MAX]; /* a value without ◀▶ */
    uint8_t digit[APP_WEIGHT_DIGITS];
    uint8_t cursor; /* 0: the net/gross chip, 1..4: a digit */
    bool net;
    bool refused; /* gross below the core: Save does nothing */
    uint16_t progress; /* 0..UI_TOAST_MAX */
    bool in_base; /* Result: the spool is in Bambuddy */
    int16_t level; /* Result: remaining per mille of the label, -1 none */
} UiFrame;

void ui_frame_build(UiFrame* frame, const AppState* s, const UiEnv* env);
