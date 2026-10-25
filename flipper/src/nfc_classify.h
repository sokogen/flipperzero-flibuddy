/* Pure helpers around the NFC reader (nfc_read.h): which tags the app
 * reads, and what it shows about a tag when no host is connected.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "tag_dump.h"

/* Room for the longest tag_summary_text() output and its NUL. */
#define TAG_SUMMARY_MAX 160

/* SAK 0x08 (MIFARE Classic 1K) and 0x18 (4K, read as its first 1K) → mfc;
 * 0x00 (NTAG21x / Ultralight) → ntag. Any other SAK is not supported and
 * leaves *type untouched. */
bool tag_type_from_sak(uint8_t sak, TagType* type);

/* The "no host" screen text, lines separated by '\n':
 *
 *   MIFARE Classic | NTAG
 *   UID <hex>
 *   <block 2 ASCII>             mfc, when present and not blank (material)
 *   <block 4 ASCII>             mfc, likewise (detailed type)
 *   Tray <block 9 hex, 8 bytes> mfc, when present, on two lines
 *        <next 8 bytes>
 *   Sectors read N/16 | Pages N
 *
 * Block text stops at the first NUL, turns other control and non-ASCII
 * bytes into '?' and drops trailing spaces. Writes at most cap - 1
 * characters and a NUL (nothing when cap is 0); returns the length written.
 */
size_t tag_summary_text(const TagDump* dump, char* out, size_t cap);
