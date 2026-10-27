/* Reads one filament spool tag into a TagDump (Flipper only).
 *
 * tag_reader_start() runs a worker thread that first waits until the tag
 * it read last has left the field (tag_watch.h), so a spool left on the
 * Flipper is read once; then it waits for an ISO 14443-3A tag
 * (nfc_scanner), reports TagReaderEventDetected, reads the tag with
 * tag_reader_read() and reports TagReaderEventRead or TagReaderEventFailed;
 * then the worker ends, so one start reads at most one tag. Tags of other
 * technologies are ignored. Callbacks run on the worker thread.
 *
 * tag_reader_stop() stops the NFC and joins the worker; it waits for a read
 * in progress to finish (the SDK's sync pollers cannot be cancelled), and
 * no callback runs after it returns. A tag whose read finished that way
 * reported nothing and is not remembered, so the next start reads it.
 */
#pragma once

#include <stdbool.h>

#include "tag_dump.h"

typedef enum {
    TagReaderEventDetected, /* a tag is in the field; reading starts */
    TagReaderEventRead, /* the dump passed to start() holds the tag */
    TagReaderEventFailed, /* lost, unsupported SAK, or no data */
} TagReaderEvent;

typedef void (*TagReaderCallback)(TagReaderEvent event, void* ctx);

typedef struct TagReader TagReader;

TagReader* tag_reader_alloc(void);

/* Stops the reader if needed. */
void tag_reader_free(TagReader* reader);

/* Starts waiting for a tag; `out` must stay valid until the next stop().
 * A reader stays started until stop(), even after its worker has ended;
 * start() does nothing while it is started. */
void tag_reader_start(TagReader* reader, TagDump* out, TagReaderCallback callback, void* ctx);

void tag_reader_stop(TagReader* reader);

/* Call start, stop and is_started from one thread (the GUI thread). */
bool tag_reader_is_started(const TagReader* reader);

/* Reads the tag in the field, blocking: UID, SAK and ATQA, then for SAK
 * 0x08/0x18 every MIFARE Classic sector with the Bambu Key A derived from
 * the 4-byte UID (sectors that fail stay missing), for SAK 0x00 every NTAG
 * page. Call it from a FuriThread (the sync pollers wait on thread flags).
 * When it fails `out` still holds the UID if a tag answered (uid_len 0
 * otherwise).
 */
bool tag_reader_read(TagReader* reader, TagDump* out);
