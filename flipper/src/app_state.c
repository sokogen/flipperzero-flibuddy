#include "app_state.h"

#include <string.h>

void app_state_init(
    AppState* s,
    IntentStore* intents,
    uint32_t first_scan,
    uint32_t first_intent) {
    memset(s, 0, sizeof(*s));
    s->screen = AppScreenIdle;
    s->mode = WeightModeGross;
    s->intents = intents;
    id_seq_init(&s->scan_ids, 's', first_scan);
    id_seq_init(&s->intent_ids, 'i', first_intent);
}

static void go_idle(AppState* s) {
    s->screen = AppScreenIdle;
    s->error = AppErrorNone;
}

static void go_error(AppState* s, AppError error) {
    s->screen = AppScreenError;
    s->error = error;
}

static void go_result(AppState* s, AppResultKind kind) {
    s->screen = AppScreenResult;
    s->result_kind = kind;
}

/* Last gross weight when known, else label + core, capped to the input range. */
static uint16_t weight_default(const ProtoDefaults* d) {
    if(d->has_gross) return d->gross;
    if(!d->has_label) return 0;
    unsigned sum = (unsigned)d->label + (d->has_core ? d->core : 0);
    return (uint16_t)(sum > PROTO_GRAMS_MAX ? PROTO_GRAMS_MAX : sum);
}

static AppEffect on_tag_read(AppState* s, const TagDump* tag) {
    memset(&s->lookup, 0, sizeof(s->lookup));
    memset(&s->result, 0, sizeof(s->result));
    s->scan.tag = *tag;
    if(!id_seq_next(&s->scan_ids, s->scan.id)) {
        go_error(s, AppErrorReadFailed);
        return AppEffectNone;
    }
    if(!s->connected) {
        go_result(s, AppResultNoHost);
        return AppEffectNone;
    }
    s->screen = AppScreenWaitingLookup;
    return AppEffectSendScan;
}

static void on_lookup(AppState* s, const ProtoLookup* lookup) {
    if(strcmp(lookup->scan_id, s->scan.id) != 0) return;
    s->lookup = *lookup;
    switch(lookup->status) {
    case ProtoLookupFound:
        go_result(s, AppResultFound);
        break;
    case ProtoLookupUnknown:
        go_result(s, lookup->prefill ? AppResultUnknownPrefill : AppResultUnknownBare);
        break;
    case ProtoLookupError:
        go_error(s, AppErrorLookup);
        break;
    }
}

static AppEffect send_intent(AppState* s, const Intent* intent) {
    if(!intent_store_put(s->intents, intent)) return AppEffectNone;
    memset(&s->result, 0, sizeof(s->result));
    s->screen = AppScreenWaitingResult;
    return AppEffectSendIntent;
}

static AppEffect on_menu_action(AppState* s, IntentAction action) {
    bool offered = false;
    switch(s->result_kind) {
    case AppResultUnknownPrefill:
        offered = action == IntentActionNew || action == IntentActionLinkOnHost;
        break;
    case AppResultUnknownBare:
        offered = action == IntentActionCreateOnHost || action == IntentActionLinkOnHost;
        break;
    case AppResultFound:
    case AppResultNoHost:
        break;
    }
    if(!offered || !s->connected) return AppEffectNone;
    if(!intent_new_action(&s->draft, &s->intent_ids, &s->scan, action)) return AppEffectNone;
    return send_intent(s, &s->draft);
}

static AppEffect on_weight(AppState* s, uint16_t grams) {
    if(!s->connected) return AppEffectNone;
    if(!intent_new_weigh(&s->draft, &s->intent_ids, &s->scan, grams, s->mode)) return AppEffectNone;
    return send_intent(s, &s->draft);
}

static void on_result(AppState* s, const ProtoResult* result) {
    if(!intent_store_resolve(s->intents, result->id)) return;
    s->result = *result;
    if(result->ok) {
        s->screen = AppScreenDone;
        s->error = AppErrorNone;
    } else {
        go_error(s, AppErrorHost);
    }
}

static void on_host_lost(AppState* s) {
    s->connected = false;
    switch(s->screen) {
    case AppScreenWaitingLookup:
    case AppScreenResult:
    case AppScreenEnterWeight:
        go_result(s, AppResultNoHost);
        break;
    case AppScreenWaitingResult:
        go_error(s, AppErrorHostLost);
        break;
    default:
        break;
    }
}

static AppEffect reduce_idle(AppState* s, const AppEvent* e) {
    if(e->type == AppEventTagDetected) s->screen = AppScreenReading;
    return AppEffectNone;
}

static AppEffect reduce_reading(AppState* s, const AppEvent* e) {
    switch(e->type) {
    case AppEventTagRead:
        return on_tag_read(s, e->tag);
    case AppEventReadFailed:
        go_error(s, AppErrorReadFailed);
        break;
    case AppEventBack:
        go_idle(s);
        break;
    default:
        break;
    }
    return AppEffectNone;
}

static AppEffect reduce_waiting_lookup(AppState* s, const AppEvent* e) {
    if(e->type == AppEventLookupReceived)
        on_lookup(s, e->lookup);
    else if(e->type == AppEventBack)
        go_idle(s);
    return AppEffectNone;
}

static AppEffect reduce_result(AppState* s, const AppEvent* e) {
    switch(e->type) {
    case AppEventMenuWeigh:
        if(s->result_kind == AppResultFound && s->connected) {
            s->weight_default = weight_default(&s->lookup.defaults);
            s->screen = AppScreenEnterWeight;
        }
        break;
    case AppEventMenuNew:
        return on_menu_action(s, IntentActionNew);
    case AppEventMenuCreateOnHost:
        return on_menu_action(s, IntentActionCreateOnHost);
    case AppEventMenuLinkOnHost:
        return on_menu_action(s, IntentActionLinkOnHost);
    case AppEventBack:
        go_idle(s);
        break;
    default:
        break;
    }
    return AppEffectNone;
}

static AppEffect reduce_enter_weight(AppState* s, const AppEvent* e) {
    switch(e->type) {
    case AppEventToggleMode:
        s->mode = s->mode == WeightModeGross ? WeightModeNet : WeightModeGross;
        break;
    case AppEventWeightEntered:
        return on_weight(s, e->grams);
    case AppEventBack:
        s->screen = AppScreenResult;
        break;
    default:
        break;
    }
    return AppEffectNone;
}

static AppEffect reduce_waiting_result(AppState* s, const AppEvent* e) {
    if(e->type == AppEventResultReceived)
        on_result(s, e->result);
    else if(e->type == AppEventTimeout)
        go_error(s, AppErrorTimeout);
    return AppEffectNone;
}

AppEffect app_reduce(AppState* s, const AppEvent* e) {
    if(e->type == AppEventHostConnected) {
        s->connected = true;
        return AppEffectNone;
    }
    if(e->type == AppEventHostLost) {
        on_host_lost(s);
        return AppEffectNone;
    }
    switch(s->screen) {
    case AppScreenIdle:
        return reduce_idle(s, e);
    case AppScreenReading:
        return reduce_reading(s, e);
    case AppScreenWaitingLookup:
        return reduce_waiting_lookup(s, e);
    case AppScreenResult:
        return reduce_result(s, e);
    case AppScreenEnterWeight:
        return reduce_enter_weight(s, e);
    case AppScreenWaitingResult:
        return reduce_waiting_result(s, e);
    case AppScreenDone:
    case AppScreenError:
        if(e->type == AppEventBack) go_idle(s);
        break;
    }
    return AppEffectNone;
}
