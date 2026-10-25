#include "nfc_classify.h"

#include <stdio.h>
#include <string.h>

#define SAK_MFC_1K 0x08
#define SAK_MFC_4K 0x18
#define SAK_NTAG   0x00

#define BLOCK_MATERIAL      2
#define BLOCK_DETAILED_TYPE 4
#define BLOCK_TRAY_UUID     9
#define TRAY_HEX_PER_LINE   8 /* bytes */

bool tag_type_from_sak(uint8_t sak, TagType* type) {
    switch(sak) {
    case SAK_MFC_1K:
    case SAK_MFC_4K:
        *type = TagTypeMfc;
        return true;
    case SAK_NTAG:
        *type = TagTypeNtag;
        return true;
    default:
        return false;
    }
}

/* Append-only text into a fixed buffer; stops quietly when full. */
typedef struct {
    char* out;
    size_t cap;
    size_t len;
} Text;

static void put_char(Text* t, char c) {
    if(t->len + 1 < t->cap) {
        t->out[t->len++] = c;
        t->out[t->len] = '\0';
    }
}

static void put_str(Text* t, const char* s) {
    while(*s)
        put_char(t, *s++);
}

static void put_hex(Text* t, const uint8_t* bytes, size_t len) {
    static const char digits[] = "0123456789ABCDEF";
    for(size_t i = 0; i < len; i++) {
        put_char(t, digits[bytes[i] >> 4]);
        put_char(t, digits[bytes[i] & 0x0F]);
    }
}

/* A block as a printable line; false when it holds no visible text. */
static bool
    block_ascii(const uint8_t block[TAG_DUMP_BLOCK_LEN], char out[TAG_DUMP_BLOCK_LEN + 1]) {
    size_t len = 0;
    while(len < TAG_DUMP_BLOCK_LEN && block[len] != 0) {
        uint8_t c = block[len];
        out[len++] = (c >= 0x20 && c < 0x7F) ? (char)c : '?';
    }
    while(len > 0 && out[len - 1] == ' ')
        len--;
    out[len] = '\0';
    return len > 0;
}

static void put_block_line(Text* t, const TagDump* dump, uint8_t block) {
    char ascii[TAG_DUMP_BLOCK_LEN + 1];
    if(!tag_dump_block_present(dump, block)) return;
    if(!block_ascii(dump->blocks[block], ascii)) return;
    put_str(t, ascii);
    put_char(t, '\n');
}

static void put_mfc(Text* t, const TagDump* dump) {
    put_block_line(t, dump, BLOCK_MATERIAL);
    put_block_line(t, dump, BLOCK_DETAILED_TYPE);
    if(tag_dump_block_present(dump, BLOCK_TRAY_UUID)) {
        const uint8_t* tray = dump->blocks[BLOCK_TRAY_UUID];
        put_str(t, "Tray ");
        put_hex(t, tray, TRAY_HEX_PER_LINE);
        put_str(t, "\n     ");
        put_hex(t, tray + TRAY_HEX_PER_LINE, TAG_DUMP_BLOCK_LEN - TRAY_HEX_PER_LINE);
        put_char(t, '\n');
    }
    unsigned read = 0;
    for(uint8_t s = 0; s < TAG_DUMP_MFC_SECTORS; s++)
        if(!tag_dump_sector_missing(dump, s)) read++;
    char count[24];
    snprintf(count, sizeof(count), "Sectors read %u/%u", read, (unsigned)TAG_DUMP_MFC_SECTORS);
    put_str(t, count);
}

size_t tag_summary_text(const TagDump* dump, char* out, size_t cap) {
    Text t = {.out = out, .cap = cap, .len = 0};
    if(cap == 0) return 0;
    out[0] = '\0';
    put_str(&t, dump->type == TagTypeMfc ? "MIFARE Classic\nUID " : "NTAG\nUID ");
    put_hex(&t, dump->uid, dump->uid_len);
    put_char(&t, '\n');
    if(dump->type == TagTypeMfc) {
        put_mfc(&t, dump);
    } else {
        char count[16];
        snprintf(count, sizeof(count), "Pages %u", (unsigned)dump->page_count);
        put_str(&t, count);
    }
    return t.len;
}
