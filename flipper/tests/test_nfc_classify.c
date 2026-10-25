#include "minitest.h"
#include "dump_loaders.h"

#include "nfc_classify.h"

static TagDump mfc;
static TagDump ntag;
static char text[TAG_SUMMARY_MAX];

static void test_sak_mifare_classic_1k_and_4k(void) {
    TagType type = TagTypeNtag;
    CHECK(tag_type_from_sak(0x08, &type));
    CHECK_EQ_INT(type, TagTypeMfc);
    type = TagTypeNtag;
    CHECK(tag_type_from_sak(0x18, &type));
    CHECK_EQ_INT(type, TagTypeMfc);
}

static void test_sak_ntag(void) {
    TagType type = TagTypeMfc;
    CHECK(tag_type_from_sak(0x00, &type));
    CHECK_EQ_INT(type, TagTypeNtag);
}

static void test_sak_unsupported(void) {
    /* MIFARE Mini, Plus SL2, ISO 14443-4 (DESFire, bank cards), SAK with the
     * "UID not complete" bit */
    const uint8_t others[] = {0x09, 0x10, 0x11, 0x20, 0x28, 0x38, 0x04, 0x88};
    for(size_t i = 0; i < sizeof(others); i++) {
        TagType type = TagTypeNtag;
        CHECK(!tag_type_from_sak(others[i], &type));
        CHECK_EQ_INT(type, TagTypeNtag); /* untouched */
    }
}

static void test_summary_bambu(void) {
    load_mfc(&mfc);
    size_t len = tag_summary_text(&mfc, text, sizeof(text));
    CHECK_EQ_INT(len, strlen(text));
    CHECK_STR_EQ(
        text,
        "MIFARE Classic\n"
        "UID 5A3C9E21\n"
        "PLA\n"
        "PLA Basic\n"
        "Tray FCFFA95B29EA71C5\n"
        "     A36D7A067DF82014\n"
        "Sectors read 15/16");
}

static void test_summary_bambu_missing_blocks(void) {
    /* sectors 1 and 2 locked: no material, no detailed type, no block 9 */
    load_mfc(&mfc);
    for(uint8_t b = 4; b < 12; b++)
        mfc.block_present &= ~(1ULL << b);
    tag_summary_text(&mfc, text, sizeof(text));
    CHECK_STR_EQ(
        text,
        "MIFARE Classic\n"
        "UID 5A3C9E21\n"
        "PLA\n"
        "Sectors read 13/16");
}

static void test_summary_mfc_nothing_read(void) {
    load_mfc(&mfc);
    mfc.block_present = 0;
    tag_summary_text(&mfc, text, sizeof(text));
    CHECK_STR_EQ(text, "MIFARE Classic\nUID 5A3C9E21\nSectors read 0/16");
}

static void test_summary_ascii_is_sanitized(void) {
    /* control and non-ASCII bytes become '?', the text ends at the first
     * NUL, trailing spaces go */
    static const uint8_t block2[16] = {'P', 'E', 'T', 0x01, 'G', 0xC3, ' ', ' ', 0, 'X'};
    static const uint8_t block4[16] = {' ', ' ', ' ', ' ', 0};
    load_mfc(&mfc);
    CHECK(tag_dump_set_block(&mfc, 2, block2));
    CHECK(tag_dump_set_block(&mfc, 4, block4));
    tag_summary_text(&mfc, text, sizeof(text));
    CHECK_STR_EQ(
        text,
        "MIFARE Classic\n"
        "UID 5A3C9E21\n"
        "PET?G?\n"
        "Tray FCFFA95B29EA71C5\n"
        "     A36D7A067DF82014\n"
        "Sectors read 15/16");
}

static void test_summary_full_16_char_ascii(void) {
    static const uint8_t block4[16] = {
        'P', 'L', 'A', ' ', 'S', 'i', 'l', 'k', '+', ' ', 'R', 'a', 'i', 'n', 'b', 'w'};
    load_mfc(&mfc);
    CHECK(tag_dump_set_block(&mfc, 4, block4));
    tag_summary_text(&mfc, text, sizeof(text));
    CHECK(strstr(text, "\nPLA Silk+ Rainbw\n") != NULL);
}

static void test_summary_ntag(void) {
    load_ntag(&ntag);
    tag_summary_text(&ntag, text, sizeof(text));
    CHECK_STR_EQ(text, "NTAG\nUID 04112233445566\nPages 135");
}

static void test_summary_truncates_to_capacity(void) {
    char small[10];
    memset(small, 'x', sizeof(small));
    load_mfc(&mfc);
    size_t len = tag_summary_text(&mfc, small, sizeof(small));
    CHECK_EQ_INT(len, 9);
    CHECK_STR_EQ(small, "MIFARE Cl");
    CHECK_EQ_INT(tag_summary_text(&mfc, small, 0), 0);
    CHECK_EQ_INT(small[0], 'M'); /* nothing written with cap 0 */
}

static void test_summary_fits_the_maximum(void) {
    /* a 10-byte UID and every Bambu line present still fit */
    static const uint8_t uid[10] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10};
    static uint8_t full[16];
    memset(full, 'W', sizeof(full));
    load_mfc(&mfc);
    CHECK(tag_dump_set_uid(&mfc, uid, sizeof(uid)));
    CHECK(tag_dump_set_block(&mfc, 2, full));
    CHECK(tag_dump_set_block(&mfc, 4, full));
    size_t len = tag_summary_text(&mfc, text, sizeof(text));
    CHECK(len < sizeof(text) - 1);
    CHECK(strstr(text, "UID 0102030405060708090A\n") != NULL);
    CHECK(strstr(text, "Sectors read 15/16") != NULL);
}

int main(void) {
    RUN_TEST(test_sak_mifare_classic_1k_and_4k);
    RUN_TEST(test_sak_ntag);
    RUN_TEST(test_sak_unsupported);
    RUN_TEST(test_summary_bambu);
    RUN_TEST(test_summary_bambu_missing_blocks);
    RUN_TEST(test_summary_mfc_nothing_read);
    RUN_TEST(test_summary_ascii_is_sanitized);
    RUN_TEST(test_summary_full_16_char_ascii);
    RUN_TEST(test_summary_ntag);
    RUN_TEST(test_summary_truncates_to_capacity);
    RUN_TEST(test_summary_fits_the_maximum);
    return MINITEST_RESULT();
}
