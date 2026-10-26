#include "screen_text.h"

#include <stdio.h>
#include <string.h>

/* Append-only text into a fixed buffer; stops quietly when full. */
typedef struct {
    char* out;
    size_t cap;
    size_t len;
} Text;

static Text text_start(char* out, size_t cap) {
    if(cap > 0) out[0] = '\0';
    return (Text){.out = out, .cap = cap, .len = 0};
}

static void put_str(Text* t, const char* s) {
    while(*s && t->len + 1 < t->cap) {
        t->out[t->len++] = *s++;
        t->out[t->len] = '\0';
    }
}

/* Starts a new line unless the text is still empty. */
static void put_line(Text* t, const char* s) {
    if(t->len > 0) put_str(t, "\n");
    put_str(t, s);
}

static void put_lines(Text* t, const ProtoLines* lines) {
    for(uint8_t i = 0; i < lines->count && i < PROTO_LINES_MAX; i++) {
        put_line(t, lines->line[i]);
    }
}

size_t screen_lines_text(const ProtoLines* lines, char* out, size_t cap) {
    Text t = text_start(out, cap);
    put_lines(&t, lines);
    return t.len;
}

/* The host's lines and error, or `fallback` when it sent neither. */
static void
    put_host_failure(Text* t, const ProtoLines* lines, const char* error, const char* fallback) {
    put_lines(t, lines);
    if(error[0]) put_line(t, error);
    if(t->len == 0) put_str(t, fallback);
}

static const char* local_error(AppError error) {
    switch(error) {
    case AppErrorReadFailed:
        return "Could not read the tag";
    case AppErrorTimeout:
        return "No answer from the host in 10 s";
    case AppErrorHostLost:
        return "Host disconnected";
    case AppErrorSendFailed:
        return "Could not send to the host";
    case AppErrorLookup:
    case AppErrorHost:
    case AppErrorNone:
        break;
    }
    return "Error";
}

size_t screen_outcome_text(const AppState* s, char* out, size_t cap) {
    Text t = text_start(out, cap);
    if(s->screen != AppScreenError) {
        put_lines(&t, &s->result.lines);
        if(t.len == 0) put_str(&t, "Done");
        return t.len;
    }
    switch(s->error) {
    case AppErrorLookup:
        put_host_failure(&t, &s->lookup.lines, s->lookup.error, "Lookup failed");
        break;
    case AppErrorHost:
        put_host_failure(&t, &s->result.lines, s->result.error, "Not saved");
        break;
    default:
        put_str(&t, local_error(s->error));
        break;
    }
    return t.len;
}

static const char* mode_name(WeightMode mode) {
    return mode == WeightModeNet ? "net" : "gross";
}

size_t screen_intent_text(const Intent* intent, char* out, size_t cap) {
    Text t = text_start(out, cap);
    if(intent == NULL) return 0;
    switch(intent->action) {
    case IntentActionWeigh: {
        char grams[24];
        snprintf(grams, sizeof(grams), "%u g ", (unsigned)intent->grams);
        put_str(&t, grams);
        put_str(&t, mode_name(intent->mode));
        break;
    }
    case IntentActionNew:
        put_str(&t, "New spool");
        break;
    case IntentActionCreateOnHost:
        put_str(&t, "Create on host");
        break;
    case IntentActionLinkOnHost:
        put_str(&t, "Link on host");
        break;
    }
    return t.len;
}

const char* screen_weight_header(WeightMode mode) {
    return mode == WeightModeNet ? "Net weight, g" : "Gross weight, g";
}

const char* screen_mode_item(WeightMode mode) {
    return mode == WeightModeNet ? "Mode: net" : "Mode: gross";
}
