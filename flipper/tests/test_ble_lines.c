#include "minitest.h"

#include "ble_lines.h"
#include "line_sender.h"

#define MAX_NOTES 64

/* The fake stack: answers each notification from `answers` (Ok once they
 * run out); accepted notifications land on the wire. */
static char wire[2048];
static size_t wire_len;
static size_t note_len[MAX_NOTES];
static int notes; /* accepted */
static int offers; /* handed to the stack, accepted or not */
static char offered[MAX_NOTES][32]; /* the first bytes of each offer */
static BleNotifyResult answers[MAX_NOTES];
static int answer_count;
static int waits;
static bool wait_result;

static BleNotifyResult notify(const uint8_t* data, size_t len, void* ctx) {
    (void)ctx;
    if(offers < MAX_NOTES) {
        size_t n = len < sizeof(offered[0]) - 1 ? len : sizeof(offered[0]) - 1;
        memcpy(offered[offers], data, n);
        offered[offers][n] = '\0';
    }
    BleNotifyResult answer = offers < answer_count ? answers[offers] : BleNotifyOk;
    offers++;
    if(answer != BleNotifyOk) return answer;
    memcpy(wire + wire_len, data, len);
    wire_len += len;
    wire[wire_len] = '\0';
    if(notes < MAX_NOTES) note_len[notes] = len;
    notes++;
    return BleNotifyOk;
}

static bool wait(void* ctx) {
    (void)ctx;
    waits++;
    return wait_result;
}

static char lines_seen[4][64];
static int line_count;

static void on_line(const char* line, size_t len, void* ctx) {
    (void)ctx;
    if(line_count < 4) {
        memcpy(lines_seen[line_count], line, len + 1);
    }
    line_count++;
}

static BleLines bl;
static char storage[64];

static void setup(void) {
    wire_len = 0;
    wire[0] = '\0';
    notes = 0;
    offers = 0;
    answer_count = 0;
    waits = 0;
    wait_result = true;
    line_count = 0;
    ble_lines_init(&bl, storage, sizeof(storage), on_line, NULL, notify, wait, NULL);
}

static void answer(int count, BleNotifyResult result) {
    for(int i = 0; i < count; i++)
        answers[answer_count++] = result;
}

static LinePacketResult send_bytes(size_t len) {
    static uint8_t data[512];
    for(size_t i = 0; i < len; i++)
        data[i] = (uint8_t)('a' + i % 26);
    return ble_lines_send(data, len, &bl);
}

static void test_chunk_is_20_until_the_mtu_exchange(void) {
    setup();
    CHECK_EQ_INT(ble_lines_chunk(&bl), 20);
    ble_lines_set_mtu(&bl, 23);
    CHECK_EQ_INT(ble_lines_chunk(&bl), 20);
}

static void test_chunk_follows_the_mtu(void) {
    setup();
    ble_lines_set_mtu(&bl, 185);
    CHECK_EQ_INT(ble_lines_chunk(&bl), 182);
}

static void test_chunk_never_exceeds_243(void) {
    setup();
    ble_lines_set_mtu(&bl, 247);
    CHECK_EQ_INT(ble_lines_chunk(&bl), 243);
    ble_lines_set_mtu(&bl, 517);
    CHECK_EQ_INT(ble_lines_chunk(&bl), 243);
}

static void test_chunk_never_drops_below_20(void) {
    setup();
    ble_lines_set_mtu(&bl, 10);
    CHECK_EQ_INT(ble_lines_chunk(&bl), 20);
    ble_lines_set_mtu(&bl, 0);
    CHECK_EQ_INT(ble_lines_chunk(&bl), 20);
}

static void test_lost_link_goes_back_to_20(void) {
    setup();
    ble_lines_set_mtu(&bl, 185);
    ble_lines_reset_chunk(&bl);
    CHECK_EQ_INT(ble_lines_chunk(&bl), 20);
}

static void test_bytes_go_out_in_chunks_of_20(void) {
    setup();
    CHECK_EQ_INT(send_bytes(45), LinePacketSent);
    CHECK_EQ_INT(notes, 3);
    CHECK_EQ_INT(note_len[0], 20);
    CHECK_EQ_INT(note_len[1], 20);
    CHECK_EQ_INT(note_len[2], 5);
    CHECK_EQ_INT(wire_len, 45);
}

static void test_bytes_go_out_in_chunks_of_182(void) {
    setup();
    ble_lines_set_mtu(&bl, 185);
    CHECK_EQ_INT(send_bytes(400), LinePacketSent);
    CHECK_EQ_INT(notes, 3);
    CHECK_EQ_INT(note_len[0], 182);
    CHECK_EQ_INT(note_len[1], 182);
    CHECK_EQ_INT(note_len[2], 36);
}

static void test_exact_chunk_is_one_notification(void) {
    setup();
    CHECK_EQ_INT(send_bytes(20), LinePacketSent);
    CHECK_EQ_INT(notes, 1);
    CHECK_EQ_INT(note_len[0], 20);
}

static void test_zero_length_packet_sends_nothing(void) {
    setup();
    CHECK_EQ_INT(ble_lines_send(NULL, 0, &bl), LinePacketSent);
    CHECK_EQ_INT(offers, 0);
}

static void test_busy_stack_gets_the_same_chunk_again(void) {
    setup();
    answer(1, BleNotifyOk);
    answer(2, BleNotifyBusy);
    CHECK_EQ_INT(send_bytes(45), LinePacketSent);
    /* the second chunk is offered until taken; the third waits for it */
    CHECK_EQ_INT(offers, 5);
    CHECK_STR_EQ(offered[1], offered[2]);
    CHECK_STR_EQ(offered[2], offered[3]);
    CHECK(strcmp(offered[3], offered[4]) != 0);
    CHECK_EQ_INT(waits, 2);
    CHECK_EQ_INT(ble_lines_busy(&bl), 2);
    CHECK_EQ_INT(wire_len, 45);
    CHECK_STR_EQ(wire, "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrs");
}

static void test_stack_busy_for_too_long_sends_nothing(void) {
    setup();
    answer(MAX_NOTES, BleNotifyBusy);
    CHECK_EQ_INT(send_bytes(45), LinePacketNotSent);
    CHECK_EQ_INT(offers, 1 + BLE_LINES_BUSY_RETRIES);
    CHECK_EQ_INT(waits, BLE_LINES_BUSY_RETRIES);
    CHECK_EQ_INT(wire_len, 0);
}

static void test_stack_busy_after_the_first_chunk_may_have_sent(void) {
    setup();
    answer(1, BleNotifyOk);
    answer(MAX_NOTES - 1, BleNotifyBusy);
    CHECK_EQ_INT(send_bytes(45), LinePacketMaybeSent);
    CHECK_EQ_INT(wire_len, 20);
}

static void test_lost_link_stops_at_once(void) {
    setup();
    answer(1, BleNotifyLost);
    CHECK_EQ_INT(send_bytes(45), LinePacketNotSent);
    CHECK_EQ_INT(offers, 1);
    CHECK_EQ_INT(waits, 0);
}

static void test_link_lost_while_waiting_stops(void) {
    setup();
    answer(1, BleNotifyBusy);
    wait_result = false;
    CHECK_EQ_INT(send_bytes(45), LinePacketNotSent);
    CHECK_EQ_INT(offers, 1);
    CHECK_EQ_INT(waits, 1);
}

static void test_lines_go_out_through_the_line_sender(void) {
    setup();
    LineSender ls;
    line_sender_init(&ls, ble_lines_chunk(&bl), ble_lines_send, &bl);
    const char* line = "{\"type\":\"hello\",\"app\":\"spoolbuddy-fap/0.1.0\"}";
    CHECK_EQ_INT(line_sender_send(&ls, line, strlen(line)), TransportSent);
    CHECK_EQ_INT(wire_len, strlen(line) + 1);
    CHECK_MEM_EQ(wire, line, strlen(line));
    CHECK_EQ_INT(wire[wire_len - 1], '\n');
    for(int i = 0; i < notes; i++)
        CHECK(note_len[i] > 0 && note_len[i] <= 20);
}

static void test_line_ending_on_a_chunk_boundary_sends_no_empty_notification(void) {
    setup();
    LineSender ls;
    line_sender_init(&ls, ble_lines_chunk(&bl), ble_lines_send, &bl);
    /* 39 bytes and the '\n' fill two chunks: the line sender asks for a
     * zero-length packet, which BLE does not need */
    char line[39];
    memset(line, 'x', sizeof(line));
    CHECK_EQ_INT(line_sender_send(&ls, line, sizeof(line)), TransportSent);
    CHECK_EQ_INT(notes, 2);
    CHECK_EQ_INT(offers, 2);
}

static void test_received_bytes_become_lines(void) {
    setup();
    const char* a = "{\"a\":1}\n{\"b\"";
    const char* b = ":2}\n";
    ble_lines_receive(&bl, (const uint8_t*)a, strlen(a));
    CHECK_EQ_INT(line_count, 1);
    CHECK_STR_EQ(lines_seen[0], "{\"a\":1}");
    ble_lines_receive(&bl, (const uint8_t*)b, strlen(b));
    CHECK_EQ_INT(line_count, 2);
    CHECK_STR_EQ(lines_seen[1], "{\"b\":2}");
}

static void test_new_session_forgets_a_partial_line(void) {
    setup();
    const char* a = "{\"a\":";
    const char* b = "{\"b\":2}\n";
    ble_lines_receive(&bl, (const uint8_t*)a, strlen(a));
    ble_lines_reset_rx(&bl);
    ble_lines_receive(&bl, (const uint8_t*)b, strlen(b));
    CHECK_EQ_INT(line_count, 1);
    CHECK_STR_EQ(lines_seen[0], "{\"b\":2}");
}

int main(void) {
    RUN_TEST(test_chunk_is_20_until_the_mtu_exchange);
    RUN_TEST(test_chunk_follows_the_mtu);
    RUN_TEST(test_chunk_never_exceeds_243);
    RUN_TEST(test_chunk_never_drops_below_20);
    RUN_TEST(test_lost_link_goes_back_to_20);
    RUN_TEST(test_bytes_go_out_in_chunks_of_20);
    RUN_TEST(test_bytes_go_out_in_chunks_of_182);
    RUN_TEST(test_exact_chunk_is_one_notification);
    RUN_TEST(test_zero_length_packet_sends_nothing);
    RUN_TEST(test_busy_stack_gets_the_same_chunk_again);
    RUN_TEST(test_stack_busy_for_too_long_sends_nothing);
    RUN_TEST(test_stack_busy_after_the_first_chunk_may_have_sent);
    RUN_TEST(test_lost_link_stops_at_once);
    RUN_TEST(test_link_lost_while_waiting_stops);
    RUN_TEST(test_lines_go_out_through_the_line_sender);
    RUN_TEST(test_line_ending_on_a_chunk_boundary_sends_no_empty_notification);
    RUN_TEST(test_received_bytes_become_lines);
    RUN_TEST(test_new_session_forgets_a_partial_line);
    return MINITEST_RESULT();
}
