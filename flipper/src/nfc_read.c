#include <furi.h>
#include <nfc/nfc.h>
#include <nfc/nfc_scanner.h>
#include <nfc/protocols/iso14443_3a/iso14443_3a_poller_sync.h>
#include <nfc/protocols/mf_classic/mf_classic_poller_sync.h>
#include <nfc/protocols/mf_ultralight/mf_ultralight_poller_sync.h>

#include "bambu_keys.h"
#include "nfc_classify.h"
#include "nfc_read.h"

#define READER_STACK    3072 /* HKDF runs on it */
#define RESCAN_DELAY_MS 500 /* after a tag of another technology */

typedef enum {
    ReaderFlagStop = 1 << 0,
    ReaderFlagDetected = 1 << 1,
} ReaderFlag;

struct TagReader {
    Nfc* nfc;
    NfcScanner* scanner;
    FuriThread* worker;
    TagDump* out;
    TagReaderCallback callback;
    void* ctx;
    bool started; /* GUI thread: started and not joined yet */
    volatile bool stopping;
    volatile bool found_3a; /* the last detection was ISO 14443-3A */
};

/* NFC worker thread. */
static void on_scanner_event(NfcScannerEvent event, void* ctx) {
    TagReader* r = ctx;
    if(event.type != NfcScannerEventTypeDetected) return;
    bool found = false;
    for(size_t i = 0; i < event.data.protocol_num; i++) {
        NfcProtocol p = event.data.protocols[i];
        if(p == NfcProtocolIso14443_3a || nfc_protocol_has_parent(p, NfcProtocolIso14443_3a))
            found = true;
    }
    r->found_3a = found;
    furi_thread_flags_set(furi_thread_get_id(r->worker), ReaderFlagDetected);
}

/* Whether a tag still answers; tells "no sector opened" from "tag gone". */
static bool tag_present(TagReader* r) {
    Iso14443_3aData iso;
    return iso14443_3a_poller_sync_read(r->nfc, &iso) == Iso14443_3aErrorNone;
}

static bool read_mfc(TagReader* r, TagDump* out) {
    /* Bambu keys come from a 4-byte UID; any other tag keeps every sector
     * missing and the host can still match it by UID. */
    if(out->uid_len != BAMBU_UID_LEN) return true;

    uint8_t derived[BAMBU_KEYS_LEN];
    bambu_derive_keys(out->uid, derived);
    MfClassicDeviceKeys* keys = malloc(sizeof(MfClassicDeviceKeys));
    memset(keys, 0, sizeof(MfClassicDeviceKeys));
    for(uint8_t s = 0; s < BAMBU_SECTOR_COUNT; s++) {
        bambu_sector_key(derived, s, keys->key_a[s].data);
        keys->key_a_mask |= 1ULL << s;
    }

    MfClassicData* data = mf_classic_alloc();
    MfClassicError error = mf_classic_poller_sync_read(r->nfc, keys, data);
    bool ok = true;
    if(error == MfClassicErrorNone || error == MfClassicErrorPartialRead) {
        for(uint8_t b = 0; b < TAG_DUMP_MFC_BLOCKS; b++)
            if(mf_classic_is_block_read(data, b)) tag_dump_set_block(out, b, data->block[b].data);
    } else {
        ok = tag_present(r);
    }
    FURI_LOG_I("FliBuddy", "mfc read: error %d, ok %d", error, ok);

    mf_classic_free(data);
    free(keys);
    memset(derived, 0, sizeof(derived));
    return ok;
}

static bool read_ntag(TagReader* r, TagDump* out) {
    MfUltralightData* data = mf_ultralight_alloc();
    MfUltralightError error = mf_ultralight_poller_sync_read_card(r->nfc, data, NULL);
    if(error == MfUltralightErrorNone) {
        for(uint16_t p = 0; p < data->pages_read; p++)
            if(!tag_dump_append_page(out, data->page[p].data)) break;
    }
    FURI_LOG_I("FliBuddy", "ntag read: error %d, pages %u", error, out->page_count);
    mf_ultralight_free(data);
    return out->page_count > 0; /* `scan` needs at least one page */
}

bool tag_reader_read(TagReader* r, TagDump* out) {
    Iso14443_3aData iso;
    if(iso14443_3a_poller_sync_read(r->nfc, &iso) != Iso14443_3aErrorNone) return false;
    TagType type;
    if(!tag_type_from_sak(iso.sak, &type)) {
        FURI_LOG_I("FliBuddy", "unsupported SAK %02X", iso.sak);
        return false;
    }
    tag_dump_init(out, type);
    if(!tag_dump_set_uid(out, iso.uid, iso.uid_len)) return false;
    out->sak = iso.sak;
    memcpy(out->atqa, iso.atqa, sizeof(out->atqa));
    return type == TagTypeMfc ? read_mfc(r, out) : read_ntag(r, out);
}

static void report(TagReader* r, TagReaderEvent event) {
    if(!r->stopping) r->callback(event, r->ctx);
}

/* Waits for an ISO 14443-3A tag; false when asked to stop. */
static bool wait_for_tag(TagReader* r) {
    for(;;) {
        r->found_3a = false;
        nfc_scanner_start(r->scanner, on_scanner_event, r);
        uint32_t flags = furi_thread_flags_wait(
            ReaderFlagStop | ReaderFlagDetected, FuriFlagWaitAny, FuriWaitForever);
        nfc_scanner_stop(r->scanner);
        if(!(flags & FuriFlagError) && (flags & ReaderFlagStop)) return false;
        if(r->found_3a) return true;
        flags = furi_thread_flags_wait(ReaderFlagStop, FuriFlagWaitAny, RESCAN_DELAY_MS);
        if(!(flags & FuriFlagError) && (flags & ReaderFlagStop)) return false;
    }
}

static int32_t reader_worker(void* ctx) {
    TagReader* r = ctx;
    if(!wait_for_tag(r)) return 0;
    report(r, TagReaderEventDetected);
    bool ok = tag_reader_read(r, r->out);
    report(r, ok ? TagReaderEventRead : TagReaderEventFailed);
    return 0;
}

TagReader* tag_reader_alloc(void) {
    TagReader* r = malloc(sizeof(TagReader));
    memset(r, 0, sizeof(TagReader));
    r->nfc = nfc_alloc();
    r->scanner = nfc_scanner_alloc(r->nfc);
    r->worker = furi_thread_alloc_ex("FliBuddyNfc", READER_STACK, reader_worker, r);
    return r;
}

void tag_reader_free(TagReader* r) {
    tag_reader_stop(r);
    furi_thread_free(r->worker);
    nfc_scanner_free(r->scanner);
    nfc_free(r->nfc);
    free(r);
}

void tag_reader_start(TagReader* r, TagDump* out, TagReaderCallback callback, void* ctx) {
    if(r->started) return;
    r->started = true;
    r->out = out;
    r->callback = callback;
    r->ctx = ctx;
    r->stopping = false;
    furi_thread_start(r->worker);
}

void tag_reader_stop(TagReader* r) {
    if(!r->started) return;
    r->stopping = true;
    FuriThreadId id = furi_thread_get_id(r->worker);
    if(id) furi_thread_flags_set(id, ReaderFlagStop);
    furi_thread_join(r->worker);
    r->started = false;
}

bool tag_reader_is_started(const TagReader* r) {
    return r->started;
}
