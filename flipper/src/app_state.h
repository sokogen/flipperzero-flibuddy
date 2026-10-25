/* The Flipper app's screen flow as a pure reducer.
 *
 *   Idle → Reading → WaitingLookup → Result{Found|UnknownPrefill|
 *   UnknownBare|NoHost} → EnterWeight → WaitingResult → Done|Error → Idle
 *
 * app_reduce() applies one event to the state and returns the I/O the
 * caller must perform; it never touches the GUI, NFC or the transport.
 * Scenes render from the state. Events that do not apply to the current
 * screen are ignored, and so are a `lookup` for another scan and a `result`
 * for an intent that is not in flight. The Flipper offers `new` only for an
 * unknown tag with prefill, and no action at all without a host.
 *
 * On AppEffectSendScan the caller sends proto_encode_scan(&s->scan.tag,
 * s->scan.id); on AppEffectSendIntent it sends
 * intent_encode(intent_store_current(s->intents)) and starts the result
 * timeout, which comes back as AppEventTimeout.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "intents.h"
#include "proto_decode.h"
#include "tag_dump.h"

typedef enum {
    AppScreenIdle,
    AppScreenReading,
    AppScreenWaitingLookup,
    AppScreenResult,
    AppScreenEnterWeight,
    AppScreenWaitingResult,
    AppScreenDone,
    AppScreenError,
} AppScreen;

typedef enum {
    AppResultFound, /* menu: Enter weight, Close */
    AppResultUnknownPrefill, /* menu: New, Link on host, Close */
    AppResultUnknownBare, /* menu: Create on host, Link on host, Close */
    AppResultNoHost, /* local facts only, menu: Close */
} AppResultKind;

typedef enum {
    AppErrorNone,
    AppErrorReadFailed, /* the tag could not be read */
    AppErrorLookup, /* the host answered `lookup` with status error; see lookup */
    AppErrorHost, /* the host answered `result` with ok false; see result */
    AppErrorTimeout, /* no `result` in time */
    AppErrorHostLost, /* the host went away while an intent was in flight */
} AppError;

typedef enum {
    AppEventHostConnected,
    AppEventHostLost,
    AppEventTagDetected, /* the reader found a tag and starts reading it */
    AppEventTagRead, /* .tag */
    AppEventReadFailed,
    AppEventLookupReceived, /* .lookup */
    AppEventMenuWeigh,
    AppEventMenuNew,
    AppEventMenuCreateOnHost,
    AppEventMenuLinkOnHost,
    AppEventToggleMode,
    AppEventWeightEntered, /* .grams */
    AppEventResultReceived, /* .result */
    AppEventTimeout,
    AppEventBack, /* back, or OK on Done / Error */
} AppEventType;

typedef struct {
    AppEventType type;
    union {
        const TagDump* tag;
        const ProtoLookup* lookup;
        const ProtoResult* result;
        uint16_t grams;
    };
} AppEvent;

typedef enum {
    AppEffectNone,
    AppEffectSendScan,
    AppEffectSendIntent,
} AppEffect;

typedef struct {
    AppScreen screen;
    AppResultKind result_kind; /* on Result and EnterWeight */
    AppError error; /* on Error */
    bool connected;
    WeightMode mode; /* kept for the whole session */
    uint16_t weight_default; /* pre-fill of EnterWeight */
    Scan scan; /* the tag on screen */
    ProtoLookup lookup; /* the host's answer for scan */
    ProtoResult result; /* the host's answer for the last intent */
    IdSeq scan_ids;
    IdSeq intent_ids;
    IntentStore* intents;
    Intent draft; /* scratch for the intent being built: too big for the 4 KB app stack */
} AppState;

/* Idle, no host, gross mode. `first_scan` and `first_intent` seed the id
 * counters (see IdSeq). */
void app_state_init(
    AppState* s,
    IntentStore* intents,
    uint32_t first_scan,
    uint32_t first_intent);

AppEffect app_reduce(AppState* s, const AppEvent* e);
