/* A line-oriented link to the host (NDJSON over USB CDC now, BLE later).
 *
 * The transport frames received bytes into lines (see line_buffer.h) and
 * hands each one to the rx callback on its own worker thread, so the
 * callback must be thread-safe and quick. send_line() appends the '\n' and
 * may block briefly; it returns false when the port is not open or the host
 * does not drain it. is_connected() reports whether a host holds the port
 * open (DTR for USB), not whether it said `hello` (see host_link.h).
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>

typedef void (*TransportRxCallback)(const char* line, size_t len, void* ctx);

typedef struct Transport Transport;

struct Transport {
    bool (*open)(Transport* transport);
    void (*close)(Transport* transport);
    bool (*send_line)(Transport* transport, const char* line, size_t len);
    /* Set before open(); the callback must stay valid until close(). */
    void (*set_rx_callback)(Transport* transport, TransportRxCallback callback, void* ctx);
    bool (*is_connected)(const Transport* transport);
};

static inline bool transport_open(Transport* transport) {
    return transport->open(transport);
}

static inline void transport_close(Transport* transport) {
    transport->close(transport);
}

static inline bool transport_send_line(Transport* transport, const char* line, size_t len) {
    return transport->send_line(transport, line, len);
}

static inline void
    transport_set_rx_callback(Transport* transport, TransportRxCallback callback, void* ctx) {
    transport->set_rx_callback(transport, callback, ctx);
}

static inline bool transport_is_connected(const Transport* transport) {
    return transport->is_connected(transport);
}
