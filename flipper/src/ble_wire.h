/* The raw bytes between the Flipper BLE stack and the SpoolBuddy GATT
 * service (ble_spoolbuddy_svc.h), free of SDK headers so that they are
 * tested on the host: the UUIDs, the advertised name and address, and the
 * stack events the service handles.
 *
 * UUIDs are LSB first, as the ST stack takes them. An event is the packet
 * the BLE event dispatcher hands to service handlers (hci_uart_pckt in the
 * ST transport layer): [0] packet type, [1] event code, [2] parameter
 * length, the parameters. A vendor event (0xFF) starts its parameters with
 * a 16-bit little-endian ACI event code. The stack's own definitions are
 * not in the SDK, so the codes are repeated here from the STM32WB copro
 * headers that firmware 1.5.1 builds with.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* 51C07E84-E37E-4D52-AC6D-B2003116F506 */
#define BLE_WIRE_SERVICE_UUID \
    {0x06, 0xF5, 0x16, 0x31, 0x00, 0xB2, 0x6D, 0xAC, 0x52, 0x4D, 0x7E, 0xE3, 0x84, 0x7E, 0xC0, 0x51}
/* D250A7B1-D301-43F6-928E-BF2CA5D115BD: host -> Flipper, write */
#define BLE_WIRE_RX_UUID \
    {0xBD, 0x15, 0xD1, 0xA5, 0x2C, 0xBF, 0x8E, 0x92, 0xF6, 0x43, 0x01, 0xD3, 0xB1, 0xA7, 0x50, 0xD2}
/* C3AB2366-401D-482C-9002-B0A046C2A4E4: Flipper -> host, notify */
#define BLE_WIRE_TX_UUID \
    {0xE4, 0xA4, 0xC2, 0x46, 0xA0, 0xB0, 0x02, 0x90, 0x2C, 0x48, 0x1D, 0x40, 0x66, 0x23, 0xAB, 0xC3}

/* An advertisement holds 31 bytes: the flags (3) and the 128-bit service
 * UUID (18) leave 10 for the name AD, its length byte, type byte and 8
 * chars. "Flipper <name>" does not fit, so the name is the Flipper's own. */
#define BLE_WIRE_ADV_NAME_CHARS 8
#define BLE_WIRE_ADV_NAME_SIZE  (1 + BLE_WIRE_ADV_NAME_CHARS + 1) /* type, chars, NUL */

/* Writes the AD type (complete or, past 8 chars, shortened local name) and
 * the name into `out` (BLE_WIRE_ADV_NAME_SIZE bytes), NUL-terminated;
 * "Flipper" when the Flipper has no name. GAP also takes it, without the
 * type byte, as the device name. */
void ble_wire_adv_name(char* out, const char* flipper_name);

/* The address the service advertises with: the Flipper's, with byte 2
 * changed, so that a central never mixes it up with the default profile
 * (whose bonds and cached GATT table it may hold) or the HID profile
 * (byte 2 + 1). */
void ble_wire_mac(uint8_t out[6], const uint8_t flipper_mac[6]);

typedef enum {
    BleWireEventOther, /* not for the service: pass it on */
    BleWireEventRx, /* the host wrote `data` to RX */
    BleWireEventSubscribe, /* the host wrote TX's CCCD: `subscribed` */
    BleWireEventMtu, /* the ATT MTU exchange agreed on `mtu` */
    BleWireEventDisconnected, /* the link is gone */
} BleWireEventType;

typedef struct {
    BleWireEventType type;
    const uint8_t* data; /* inside the packet */
    size_t len;
    bool subscribed; /* notifications on */
    uint16_t mtu;
} BleWireEvent;

/* The attribute handles the service got from the stack: the RX value
 * (declaration + 1) and TX's CCCD (declaration + 2). */
typedef struct {
    uint16_t rx_value;
    uint16_t tx_cccd;
} BleWireHandles;

/* Lengths inside the packet are checked against its parameter length; a
 * packet that does not add up is Other. */
BleWireEvent ble_wire_decode(const uint8_t* packet, const BleWireHandles* handles);
