#include <furi.h>
#include <bt/bt_service/bt.h>

#include "ble_lines.h"
#include "ble_spoolbuddy_svc.h"
#include "line_sender.h"
#include "proto_encode.h"
#include "transport_ble.h"

#define TAG "SpoolBuddyBle"

#define BLE_WORKER_STACK 2048
#define BLE_RX_STREAM    1024 /* bytes written to RX, waiting for the worker */
#define BLE_TX_WAIT_MS   100 /* for room in the stack, per busy answer */

_Static_assert(BLE_LINES_CHUNK_MAX <= LINE_SENDER_PACKET_MAX, "a chunk must fit the line sender");

typedef enum {
    BleEventStop = 1 << 0,
    BleEventRx = 1 << 1,
    BleEventSessionEnd = 1 << 2, /* the host unsubscribed or the link went */
} BleEvent;

#define BLE_EVENTS_ALL (BleEventStop | BleEventRx | BleEventSessionEnd)

typedef struct {
    Transport base;
    Bt* bt;
    FuriHalBleProfileBase* profile;
    SpoolBuddyBleCallbacks callbacks;
    FuriThread* worker;
    FuriStreamBuffer* rx_stream;
    FuriSemaphore* tx_ready; /* released when the stack has room again */
    FuriMutex* tx_lock; /* guards sender */
    LineSender sender;
    BleLines lines;
    char* line_storage;
    TransportRxCallback rx_callback;
    void* rx_ctx;
    volatile BtStatus status;
    volatile bool subscribed;
    bool opened;
} BleTransport;

static void worker_flags(BleTransport* t, uint32_t flags) {
    furi_thread_flags_set(furi_thread_get_id(t->worker), flags);
}

/* BLE event thread, through the service. */
static void svc_rx(const uint8_t* data, size_t len, void* ctx) {
    BleTransport* t = ctx;
    if(furi_stream_buffer_send(t->rx_stream, data, len, 0) < len) {
        FURI_LOG_W(TAG, "rx overflow");
    }
    worker_flags(t, BleEventRx);
}

static void svc_subscribe(bool subscribed, void* ctx) {
    BleTransport* t = ctx;
    t->subscribed = subscribed;
    if(!subscribed) worker_flags(t, BleEventSessionEnd);
}

static void svc_mtu(uint16_t mtu, void* ctx) {
    BleTransport* t = ctx;
    ble_lines_set_mtu(&t->lines, mtu);
}

static void svc_tx_pool(void* ctx) {
    BleTransport* t = ctx;
    furi_semaphore_release(t->tx_ready);
}

static void svc_disconnect(void* ctx) {
    BleTransport* t = ctx;
    t->subscribed = false;
    ble_lines_reset_chunk(&t->lines);
    furi_semaphore_release(t->tx_ready); /* a waiting sender gives up */
    worker_flags(t, BleEventSessionEnd);
}

/* Bt service thread. */
static void bt_status_changed(BtStatus status, void* ctx) {
    BleTransport* t = ctx;
    if(t) t->status = status;
}

static void on_line(const char* line, size_t len, void* ctx) {
    BleTransport* t = ctx;
    if(t->rx_callback) t->rx_callback(line, len, t->rx_ctx);
}

static int32_t ble_worker(void* ctx) {
    BleTransport* t = ctx;
    uint8_t bytes[64];
    size_t len;
    for(;;) {
        uint32_t events = furi_thread_flags_wait(BLE_EVENTS_ALL, FuriFlagWaitAny, FuriWaitForever);
        if(events & FuriFlagError) continue;
        if(events & BleEventStop) break;
        if(events & BleEventSessionEnd) {
            /* a new host session never continues the old one's partial line */
            while(furi_stream_buffer_receive(t->rx_stream, bytes, sizeof(bytes), 0) > 0) {
            }
            ble_lines_reset_rx(&t->lines);
        }
        if(events & BleEventRx) {
            while((len = furi_stream_buffer_receive(t->rx_stream, bytes, sizeof(bytes), 0)) > 0) {
                ble_lines_receive(&t->lines, bytes, len);
            }
        }
    }
    return 0;
}

/* Sender thread, under tx_lock. */
static BleNotifyResult notify_chunk(const uint8_t* data, size_t len, void* ctx) {
    BleTransport* t = ctx;
    if(!t->subscribed) return BleNotifyLost;
    return spoolbuddy_ble_notify(t->profile, data, len) ? BleNotifyOk : BleNotifyBusy;
}

static bool wait_for_room(void* ctx) {
    BleTransport* t = ctx;
    furi_semaphore_acquire(t->tx_ready, furi_ms_to_ticks(BLE_TX_WAIT_MS));
    return t->subscribed;
}

static bool ble_open(Transport* base) {
    BleTransport* t = (BleTransport*)base;
    if(t->opened) return true;

    t->bt = furi_record_open(RECORD_BT);
    t->status = BtStatusOff;
    t->subscribed = false;
    ble_lines_reset_chunk(&t->lines);
    ble_lines_reset_rx(&t->lines);
    furi_stream_buffer_reset(t->rx_stream);
    furi_thread_start(t->worker);
    bt_set_status_changed_callback(t->bt, bt_status_changed, t);

    t->profile = bt_profile_start(t->bt, spoolbuddy_ble_profile, &t->callbacks);
    if(!t->profile) {
        FURI_LOG_E(TAG, "profile not started");
        bt_profile_restore_default(t->bt);
        bt_set_status_changed_callback(t->bt, NULL, NULL);
        worker_flags(t, BleEventStop);
        furi_thread_join(t->worker);
        furi_record_close(RECORD_BT);
        t->bt = NULL;
        return false;
    }
    t->opened = true;
    return true;
}

static void ble_close(Transport* base) {
    BleTransport* t = (BleTransport*)base;
    if(!t->opened) return;

    t->opened = false;
    t->subscribed = false;
    bt_disconnect(t->bt);
    /* stops the profile, after which no service callback runs */
    if(!bt_profile_restore_default(t->bt)) FURI_LOG_E(TAG, "default profile not restored");
    t->profile = NULL;
    /* cleared last: status changes up to here find the transport alive */
    bt_set_status_changed_callback(t->bt, NULL, NULL);
    worker_flags(t, BleEventStop);
    furi_thread_join(t->worker);
    furi_record_close(RECORD_BT);
    t->bt = NULL;
    t->status = BtStatusOff;
}

static bool ble_is_connected(const Transport* base) {
    const BleTransport* t = (const BleTransport*)base;
    return t->opened && t->status == BtStatusConnected && t->subscribed;
}

static TransportSendResult ble_send_line(Transport* base, const char* line, size_t len) {
    BleTransport* t = (BleTransport*)base;
    if(!ble_is_connected(base) || len >= PROTO_LINE_MAX) return TransportNotSent;

    furi_mutex_acquire(t->tx_lock, FuriWaitForever);
    line_sender_set_packet_size(&t->sender, ble_lines_chunk(&t->lines));
    TransportSendResult result = line_sender_send(&t->sender, line, len);
    furi_mutex_release(t->tx_lock);
    return result;
}

static void ble_set_rx_callback(Transport* base, TransportRxCallback callback, void* ctx) {
    BleTransport* t = (BleTransport*)base;
    furi_check(!t->opened);
    t->rx_callback = callback;
    t->rx_ctx = ctx;
}

Transport* transport_ble_alloc(void) {
    BleTransport* t = malloc(sizeof(BleTransport));
    memset(t, 0, sizeof(BleTransport));
    t->base.open = ble_open;
    t->base.close = ble_close;
    t->base.send_line = ble_send_line;
    t->base.set_rx_callback = ble_set_rx_callback;
    t->base.is_connected = ble_is_connected;
    t->callbacks = (SpoolBuddyBleCallbacks){
        .on_rx = svc_rx,
        .on_subscribe = svc_subscribe,
        .on_mtu = svc_mtu,
        .on_tx_pool = svc_tx_pool,
        .on_disconnect = svc_disconnect,
        .ctx = t,
    };
    t->status = BtStatusOff;
    t->line_storage = malloc(PROTO_LINE_MAX);
    ble_lines_init(
        &t->lines, t->line_storage, PROTO_LINE_MAX, on_line, t, notify_chunk, wait_for_room, t);
    line_sender_init(&t->sender, ble_lines_chunk(&t->lines), ble_lines_send, &t->lines);
    t->rx_stream = furi_stream_buffer_alloc(BLE_RX_STREAM, 1);
    t->tx_ready = furi_semaphore_alloc(1, 0);
    t->tx_lock = furi_mutex_alloc(FuriMutexTypeNormal);
    t->worker = furi_thread_alloc_ex("SpoolBuddyBle", BLE_WORKER_STACK, ble_worker, t);
    return &t->base;
}

void transport_ble_free(Transport* base) {
    BleTransport* t = (BleTransport*)base;
    ble_close(base);
    furi_thread_free(t->worker);
    furi_mutex_free(t->tx_lock);
    furi_semaphore_free(t->tx_ready);
    furi_stream_buffer_free(t->rx_stream);
    free(t->line_storage);
    free(t);
}

TransportBleStatus transport_ble_status(const Transport* base) {
    const BleTransport* t = (const BleTransport*)base;
    if(!t->opened) return TransportBleOff;
    switch(t->status) {
    case BtStatusAdvertising:
        return TransportBleAdvertising;
    case BtStatusConnected:
        return TransportBleConnected;
    default:
        return TransportBleOff;
    }
}
