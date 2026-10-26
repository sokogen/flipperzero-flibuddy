/* The Flipper app's screen flow as a pure reducer.
 *
 *   Idle → Reading → WaitingLookup → Result{Found|UnknownPrefill|
 *   UnknownBare|NoHost} → EnterWeight → WaitingResult → Done|Error → Idle
 *   Idle → Transport → Idle
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
 * intent_encode(intent_store_current(s->intents)). The caller stamps every
 * event with its clock (now_ms) and sends AppEventTimeout once
 * app_result_timed_out() says the `result` is overdue. When the host cannot
 * have the scan, or surely did not get the intent, it sends
 * AppEventSendFailed: no answer would come, so a scan shows the local facts
 * (Result{NoHost}) and an intent an error. An intent the host may have got
 * waits for its result or the timeout.
 *
 * The net/gross mode belongs to the session. It toggles on the Found menu
 * and on EnterWeight; the EnterWeight pre-fill follows it: gross is the
 * last gross weight (fallback label + core), net is gross - core (fallback
 * the label weight).
 *
 * The transport menu opens from Idle. Choosing another kind than the one
 * in use answers AppEffectSwitchTransport: the caller saves the setting
 * and restarts the transport; the host is lost through host_link as the old
 * port closes. The caller reports a transport that did not open with
 * AppEventTransportFailed; choosing that same kind again then retries it. The BLE status is only recorded, for the status line
 * (screen_status_text); it never changes the screen or `connected`. The
 * caller sets `transport` from the saved settings after app_state_init().
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "intents.h"
#include "proto_decode.h"
#include "tag_dump.h"
#include "transport.h"

/* How long the Flipper waits for a `result` (PROTOCOL.md, Timeouts). */
#define APP_RESULT_TIMEOUT_MS 10000u

typedef enum {
    AppScreenIdle,
    AppScreenReading,
    AppScreenWaitingLookup,
    AppScreenResult,
    AppScreenEnterWeight,
    AppScreenWaitingResult,
    AppScreenDone,
    AppScreenError,
    AppScreenTransport, /* menu: USB, Bluetooth */
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
    AppErrorSendFailed, /* the intent could not be sent */
} AppError;

typedef enum {
    AppBleOff, /* not advertising, or Bluetooth is not the transport */
    AppBleAdvertising,
    AppBleConnected, /* a host subscribed to TX; it may not have said hello */
} AppBleStatus;

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
    AppEventTimeout, /* see app_result_timed_out() */
    AppEventSendFailed, /* the scan or intent of the last effect was not sent */
    AppEventBack, /* back, or OK on Done / Error */
    AppEventMenuTransport, /* OK on Idle */
    AppEventTransportChosen, /* .transport */
    AppEventBleStatus, /* .ble */
    AppEventTransportFailed, /* the transport in use did not open */
} AppEventType;

typedef struct {
    AppEventType type;
    uint32_t now_ms; /* the caller's millisecond clock; may wrap */
    union {
        const TagDump* tag;
        const ProtoLookup* lookup;
        const ProtoResult* result;
        uint16_t grams;
        TransportKind transport;
        AppBleStatus ble;
    };
} AppEvent;

typedef enum {
    AppEffectNone,
    AppEffectSendScan,
    AppEffectSendIntent,
    AppEffectSwitchTransport, /* to s->transport */
} AppEffect;

typedef struct {
    AppScreen screen;
    AppResultKind result_kind; /* on Result and EnterWeight */
    AppError error; /* on Error */
    bool connected;
    TransportKind transport; /* in use */
    bool transport_failed; /* it did not open; choosing it again retries */
    AppBleStatus ble;
    WeightMode mode; /* kept for the whole session */
    uint16_t weight_default; /* pre-fill of EnterWeight, follows mode */
    uint32_t intent_sent_ms; /* now_ms of the event that sent the intent */
    Scan scan; /* the tag on screen */
    ProtoLookup lookup; /* the host's answer for scan */
    ProtoResult result; /* the host's answer for the last intent */
    IdSeq scan_ids;
    IdSeq intent_ids;
    IntentStore* intents;
    Intent draft; /* scratch for the intent being built: too big for the 4 KB app stack */
} AppState;

/* Idle, no host, USB with BLE off, gross mode. `first_scan` and `first_intent` seed the id
 * counters (see IdSeq). */
void app_state_init(
    AppState* s,
    IntentStore* intents,
    uint32_t first_scan,
    uint32_t first_intent);

AppEffect app_reduce(AppState* s, const AppEvent* e);

/* True while WaitingResult once APP_RESULT_TIMEOUT_MS have passed since the
 * intent went out (wrap-safe). */
bool app_result_timed_out(const AppState* s, uint32_t now_ms);
