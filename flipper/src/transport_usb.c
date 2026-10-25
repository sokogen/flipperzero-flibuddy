#include <furi.h>
#include <furi_hal.h>
#include <furi_hal_usb_cdc.h>
#include <cli/cli_vcp.h>

#include "line_buffer.h"
#include "proto_encode.h"
#include "transport_usb.h"

#define USB_CDC_IF 0
#define USB_TX_TIMEOUT_MS 100 /* per packet; the host is not reading after that */
#define USB_WORKER_STACK 2048

typedef enum {
    UsbEventStop = 1 << 0,
    UsbEventRx = 1 << 1,
    UsbEventCtrlLine = 1 << 2,
} UsbEvent;

#define USB_EVENTS_ALL (UsbEventStop | UsbEventRx | UsbEventCtrlLine)

typedef struct {
    Transport base;
    FuriHalUsbInterface* usb_prev;
    FuriThread* worker;
    FuriSemaphore* tx_done; /* taken while a packet is in flight */
    FuriMutex* tx_lock;
    LineBuffer lines;
    char* line_storage;
    TransportRxCallback rx_callback;
    void* rx_ctx;
    volatile bool dtr;
    bool opened;
} UsbTransport;

static void cdc_tx_done(void* ctx) {
    UsbTransport* t = ctx;
    furi_semaphore_release(t->tx_done);
}

static void cdc_rx(void* ctx) {
    UsbTransport* t = ctx;
    furi_thread_flags_set(furi_thread_get_id(t->worker), UsbEventRx);
}

static void cdc_state(void* ctx, CdcState state) {
    UsbTransport* t = ctx;
    if(state == CdcStateDisconnected) {
        t->dtr = false;
        furi_thread_flags_set(furi_thread_get_id(t->worker), UsbEventCtrlLine);
    }
}

static void cdc_ctrl_line(void* ctx, CdcCtrlLine ctrl_lines) {
    UsbTransport* t = ctx;
    t->dtr = (ctrl_lines & CdcCtrlLineDTR) != 0;
    furi_thread_flags_set(furi_thread_get_id(t->worker), UsbEventCtrlLine);
}

static CdcCallbacks cdc_callbacks = {
    .tx_ep_callback = cdc_tx_done,
    .rx_ep_callback = cdc_rx,
    .state_callback = cdc_state,
    .ctrl_line_callback = cdc_ctrl_line,
    .config_callback = NULL,
};

static void on_line(const char* line, size_t len, void* ctx) {
    UsbTransport* t = ctx;
    if(t->rx_callback) t->rx_callback(line, len, t->rx_ctx);
}

static int32_t usb_worker(void* ctx) {
    UsbTransport* t = ctx;
    uint8_t packet[CDC_DATA_SZ];
    bool was_open = false;
    for(;;) {
        uint32_t events = furi_thread_flags_wait(USB_EVENTS_ALL, FuriFlagWaitAny, FuriWaitForever);
        if(events & FuriFlagError) continue;
        if(events & UsbEventStop) break;
        if(events & UsbEventCtrlLine) {
            bool open = t->dtr;
            /* a new host session never continues the old one's partial line */
            if(open != was_open) line_buffer_reset(&t->lines);
            was_open = open;
        }
        if(events & UsbEventRx) {
            int32_t len;
            while((len = furi_hal_cdc_receive(USB_CDC_IF, packet, sizeof(packet))) > 0) {
                line_buffer_feed(&t->lines, packet, (size_t)len);
            }
        }
    }
    return 0;
}

static void cli_vcp_set(bool enabled) {
    CliVcp* cli_vcp = furi_record_open(RECORD_CLI_VCP);
    if(enabled) {
        cli_vcp_enable(cli_vcp);
    } else {
        cli_vcp_disable(cli_vcp);
    }
    furi_record_close(RECORD_CLI_VCP);
}

static bool usb_open(Transport* base) {
    UsbTransport* t = (UsbTransport*)base;
    if(t->opened) return true;

    t->usb_prev = furi_hal_usb_get_config();
    cli_vcp_set(false);
    furi_hal_usb_unlock();
    if(!furi_hal_usb_set_config(&usb_cdc_single, NULL)) {
        cli_vcp_set(true);
        return false;
    }

    line_buffer_reset(&t->lines);
    furi_thread_start(t->worker);
    furi_hal_cdc_set_callbacks(USB_CDC_IF, &cdc_callbacks, t);
    t->dtr = (furi_hal_cdc_get_ctrl_line_state(USB_CDC_IF) & CdcCtrlLineDTR) != 0;
    t->opened = true;
    return true;
}

static void usb_close(Transport* base) {
    UsbTransport* t = (UsbTransport*)base;
    if(!t->opened) return;

    furi_hal_cdc_set_callbacks(USB_CDC_IF, NULL, NULL);
    furi_thread_flags_set(furi_thread_get_id(t->worker), UsbEventStop);
    furi_thread_join(t->worker);
    t->dtr = false;
    t->opened = false;

    furi_hal_usb_unlock();
    furi_check(furi_hal_usb_set_config(t->usb_prev, NULL));
    cli_vcp_set(true);
}

static bool send_packet(UsbTransport* t, uint8_t* data, uint16_t len) {
    if(furi_semaphore_acquire(t->tx_done, furi_ms_to_ticks(USB_TX_TIMEOUT_MS)) != FuriStatusOk) {
        return false;
    }
    furi_hal_cdc_send(USB_CDC_IF, data, len);
    return true;
}

static bool usb_send_line(Transport* base, const char* line, size_t len) {
    UsbTransport* t = (UsbTransport*)base;
    if(!t->opened || !t->dtr || len >= PROTO_LINE_MAX) return false;

    uint8_t packet[CDC_DATA_SZ];
    size_t total = len + 1; /* the line and its '\n' */
    size_t sent = 0;
    size_t last = 0;
    bool ok = true;

    furi_mutex_acquire(t->tx_lock, FuriWaitForever);
    while(ok && sent < total) {
        size_t n = MIN(total - sent, sizeof(packet));
        for(size_t i = 0; i < n; i++) {
            packet[i] = sent + i < len ? (uint8_t)line[sent + i] : '\n';
        }
        ok = send_packet(t, packet, (uint16_t)n);
        sent += n;
        last = n;
    }
    /* a transfer that ends on a full packet needs a zero-length packet */
    if(ok && last == CDC_DATA_SZ) ok = send_packet(t, NULL, 0);
    furi_mutex_release(t->tx_lock);
    return ok;
}

static void usb_set_rx_callback(Transport* base, TransportRxCallback callback, void* ctx) {
    UsbTransport* t = (UsbTransport*)base;
    furi_check(!t->opened);
    t->rx_callback = callback;
    t->rx_ctx = ctx;
}

static bool usb_is_connected(const Transport* base) {
    const UsbTransport* t = (const UsbTransport*)base;
    return t->opened && t->dtr;
}

Transport* transport_usb_alloc(void) {
    UsbTransport* t = malloc(sizeof(UsbTransport));
    memset(t, 0, sizeof(UsbTransport));
    t->base.open = usb_open;
    t->base.close = usb_close;
    t->base.send_line = usb_send_line;
    t->base.set_rx_callback = usb_set_rx_callback;
    t->base.is_connected = usb_is_connected;
    t->line_storage = malloc(PROTO_LINE_MAX);
    line_buffer_init(&t->lines, t->line_storage, PROTO_LINE_MAX, on_line, t);
    t->tx_done = furi_semaphore_alloc(1, 1);
    t->tx_lock = furi_mutex_alloc(FuriMutexTypeNormal);
    t->worker = furi_thread_alloc_ex("SpoolBuddyUsb", USB_WORKER_STACK, usb_worker, t);
    return &t->base;
}

void transport_usb_free(Transport* base) {
    UsbTransport* t = (UsbTransport*)base;
    usb_close(base);
    furi_thread_free(t->worker);
    furi_mutex_free(t->tx_lock);
    furi_semaphore_free(t->tx_done);
    free(t->line_storage);
    free(t);
}
