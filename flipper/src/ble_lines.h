/* NDJSON over the SpoolBuddy GATT service, as a pure state machine.
 *
 * Outbound, ble_lines_send() is the packet function of a line_sender: it
 * cuts each packet into notifications of up to ATT MTU - 3 bytes (20 until
 * the MTU exchange says more, never more than BLE_LINES_CHUNK_MAX). One
 * notification is in flight at a time: the next chunk is handed to the
 * stack only once it took the current one. A busy stack gets the same
 * chunk again after wait(), at most BLE_LINES_BUSY_RETRIES times; a lost
 * link ends the packet at once.
 *
 * Inbound, the bytes written to RX are framed into lines by a line_buffer.
 *
 * Threads: the chunk size may be set from the BLE event thread while a
 * sender reads it; everything else belongs to one thread per direction.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "line_buffer.h"
#include "line_sender.h"

#define BLE_LINES_CHUNK_MIN    20 /* the default ATT MTU 23 - 3 */
#define BLE_LINES_CHUNK_MAX    243 /* the characteristics' size */
#define BLE_LINES_BUSY_RETRIES 3

typedef enum {
    BleNotifyOk, /* the stack took the chunk */
    BleNotifyBusy, /* no room in the stack now */
    BleNotifyLost, /* no host subscribed to TX */
} BleNotifyResult;

typedef BleNotifyResult (*BleLinesNotifyFn)(const uint8_t* data, size_t len, void* ctx);

/* Waits until the stack may have room again (or a short timeout); false
 * when the link is gone. */
typedef bool (*BleLinesWaitFn)(void* ctx);

typedef struct {
    volatile uint16_t chunk;
    uint32_t busy; /* busy answers so far */
    BleLinesNotifyFn notify;
    BleLinesWaitFn wait;
    void* ctx;
    LineBuffer lines;
} BleLines;

/* `storage` of `cap` bytes holds the line being received (line_buffer.h). */
void ble_lines_init(
    BleLines* bl,
    char* storage,
    size_t cap,
    LineBufferCallback on_line,
    void* line_ctx,
    BleLinesNotifyFn notify,
    BleLinesWaitFn wait,
    void* ctx);

/* The MTU the exchange agreed on; the chunk becomes mtu - 3 within
 * BLE_LINES_CHUNK_MIN..BLE_LINES_CHUNK_MAX. */
void ble_lines_set_mtu(BleLines* bl, uint16_t mtu);

/* The link is gone: the next one starts at BLE_LINES_CHUNK_MIN. */
void ble_lines_reset_chunk(BleLines* bl);

size_t ble_lines_chunk(const BleLines* bl);

/* LineSenderPacketFn; `ctx` is the BleLines. A zero-length packet sends
 * nothing. NotSent when no chunk went out, MaybeSent when only some did. */
LinePacketResult ble_lines_send(const uint8_t* data, size_t len, void* ctx);

uint32_t ble_lines_busy(const BleLines* bl);

/* Feeds bytes written to RX; returns the number of lines delivered. */
size_t ble_lines_receive(BleLines* bl, const uint8_t* data, size_t len);

/* A new host session: forgets a partial line. */
void ble_lines_reset_rx(BleLines* bl);
