/* What the Flipper screens say, as pure functions of the app state
 * (app_state.h), so that the wording is tested on the host. Scenes only
 * lay the text out.
 */
#pragma once

#include <stddef.h>

#include "app_state.h"
#include "intents.h"
#include "proto_decode.h"

/* Room for every text below and its NUL: all host lines and an error. */
#define SCREEN_TEXT_MAX (PROTO_LINES_MAX * (PROTO_LINE_CHARS + 1) + PROTO_ERROR_MAX + 1)

/* The text builders write at most cap - 1 characters and a NUL (nothing
 * when cap is 0) and return the length written. */

/* The host's lines, separated by '\n'. */
size_t screen_lines_text(const ProtoLines* lines, char* out, size_t cap);

/* Done: the `result` lines ("Done" when there are none). Error: the host's
 * lines and error for a failed lookup or intent, else what went wrong
 * locally. */
size_t screen_outcome_text(const AppState* s, char* out, size_t cap);

/* What the in-flight intent does, for the waiting screen: "734 g gross",
 * "New spool", "Create on host", "Link on host"; "" for NULL. */
size_t screen_intent_text(const Intent* intent, char* out, size_t cap);

/* EnterWeight header: "Gross weight, g" / "Net weight, g". */
const char* screen_weight_header(WeightMode mode);

/* The Found menu item that toggles the mode: "Mode: gross" / "Mode: net". */
const char* screen_mode_item(WeightMode mode);
