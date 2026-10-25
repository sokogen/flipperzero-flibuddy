/* Fills a TagDump from the generated fixture vectors. Include after
 * minitest.h; failed setters count as test failures. */
#pragma once

#include "minitest.h"
#include "vectors/tag_dumps.h"

#include "tag_dump.h"

static inline bool sector_is_missing_in_vectors(unsigned sector) {
    for(size_t i = 0; i < MFC_MISSING_COUNT; i++)
        if(MFC_MISSING_SECTORS[i] == sector) return true;
    return false;
}

/* The Bambu fixture as the reader would leave it: every block of the
 * readable sectors (trailers included) present, the missing sectors not. */
static inline void load_mfc(TagDump* d) {
    tag_dump_init(d, TagTypeMfc);
    CHECK(tag_dump_set_uid(d, MFC_UID, sizeof(MFC_UID)));
    d->sak = MFC_SAK;
    memcpy(d->atqa, MFC_ATQA, sizeof(MFC_ATQA));
    for(uint8_t b = 0; b < TAG_DUMP_MFC_BLOCKS; b++)
        if(!sector_is_missing_in_vectors(b / TAG_DUMP_MFC_BLOCKS_PER_SECTOR))
            CHECK(tag_dump_set_block(d, b, MFC_BLOCKS[b]));
}

static inline void load_ntag(TagDump* d) {
    tag_dump_init(d, TagTypeNtag);
    CHECK(tag_dump_set_uid(d, NTAG_UID, sizeof(NTAG_UID)));
    d->sak = NTAG_SAK;
    memcpy(d->atqa, NTAG_ATQA, sizeof(NTAG_ATQA));
    for(size_t p = 0; p < NTAG_PAGE_COUNT; p++) CHECK(tag_dump_append_page(d, NTAG_PAGES[p]));
}
