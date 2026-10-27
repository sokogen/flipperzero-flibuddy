#include "minitest.h"

#include "app_settings.h"

/* The fake file: the saved_struct version in its header, the payload that
 * load hands back, what save received. Like saved_struct, load fails unless
 * both the version and the size match. */
static uint8_t file[16];
static uint8_t file_version;
static size_t file_size;
static bool file_present;
static bool save_fails;
static int saves;

static bool fake_load(void* ctx, uint8_t version, void* data, size_t size) {
    (void)ctx;
    if(!file_present || version != file_version || size != file_size) return false;
    memcpy(data, file, size);
    return true;
}

static bool fake_save(void* ctx, const void* data, size_t size) {
    (void)ctx;
    saves++;
    if(save_fails || size > sizeof(file)) return false;
    memcpy(file, data, size);
    file_size = size;
    file_version = APP_SETTINGS_VERSION;
    file_present = true;
    return true;
}

static const AppSettingsStorage storage = {.load = fake_load, .save = fake_save, .ctx = NULL};

static void reset_file(void) {
    memset(file, 0, sizeof(file));
    file_version = 0;
    file_size = 0;
    file_present = false;
    save_fails = false;
    saves = 0;
}

/* A version 1 file: the payload was {version, transport}. */
static void put_v1_file(uint8_t transport) {
    reset_file();
    file_version = 1;
    file[0] = 1;
    file[1] = transport;
    file_size = 2;
    file_present = true;
}

static void put_v2_file(uint8_t transport, uint8_t autosave, uint8_t feedback, uint8_t sound) {
    reset_file();
    file_version = 2;
    file[0] = 2;
    file[1] = transport;
    file[2] = autosave;
    file[3] = feedback;
    file[4] = sound;
    file_size = 5;
    file_present = true;
}

static AppSettings loaded(void) {
    AppSettings s;
    memset(&s, 0xAA, sizeof(s));
    app_settings_load(&s, &storage);
    return s;
}

static void check_defaults(const AppSettings* s) {
    CHECK_EQ_INT(s->version, APP_SETTINGS_VERSION);
    CHECK_EQ_INT(app_settings_transport(s), TransportKindUsb);
    CHECK(!app_settings_autosave(s));
    CHECK_EQ_INT(app_settings_feedback(s), AppFeedbackVibroLed);
    CHECK(!app_settings_sound(s));
}

static void test_settings_live_in_the_flibuddy_dir(void) {
    CHECK_STR_EQ(APP_SETTINGS_DIR, "/ext/apps_data/flibuddy");
    CHECK_STR_EQ(APP_SETTINGS_PATH, "/ext/apps_data/flibuddy/settings.bin");
}

static void test_layout_is_version_transport_autosave_feedback_sound(void) {
    CHECK_EQ_INT(sizeof(AppSettings), 5);
    CHECK_EQ_INT(sizeof(AppSettingsV1), 2);
    CHECK_EQ_INT(APP_SETTINGS_VERSION, 2);
    CHECK_EQ_INT(APP_SETTINGS_MAGIC, 0x5B);
    /* stored numbers, never renumbered */
    CHECK_EQ_INT(AppFeedbackVibroLed, 0);
    CHECK_EQ_INT(AppFeedbackLed, 1);
    CHECK_EQ_INT(AppFeedbackOff, 2);
}

static void test_defaults_are_usb_autosave_off_vibro_led_silent(void) {
    AppSettings s;
    memset(&s, 0xAA, sizeof(s));
    app_settings_defaults(&s);
    check_defaults(&s);
}

static void test_missing_file_loads_defaults(void) {
    reset_file();
    AppSettings s = loaded();
    check_defaults(&s);
}

static void test_saved_v2_file_loads(void) {
    put_v2_file(TransportKindBluetooth, 1, AppFeedbackOff, 1);
    AppSettings s = loaded();
    CHECK_EQ_INT(app_settings_transport(&s), TransportKindBluetooth);
    CHECK(app_settings_autosave(&s));
    CHECK_EQ_INT(app_settings_feedback(&s), AppFeedbackOff);
    CHECK(app_settings_sound(&s));

    put_v2_file(TransportKindUsb, 0, AppFeedbackLed, 0);
    s = loaded();
    CHECK_EQ_INT(app_settings_transport(&s), TransportKindUsb);
    CHECK(!app_settings_autosave(&s));
    CHECK_EQ_INT(app_settings_feedback(&s), AppFeedbackLed);
    CHECK(!app_settings_sound(&s));
}

static void test_v1_file_keeps_the_transport_and_defaults_the_rest(void) {
    put_v1_file(TransportKindBluetooth);
    AppSettings s = loaded();
    CHECK_EQ_INT(s.version, APP_SETTINGS_VERSION);
    CHECK_EQ_INT(app_settings_transport(&s), TransportKindBluetooth);
    CHECK(!app_settings_autosave(&s));
    CHECK_EQ_INT(app_settings_feedback(&s), AppFeedbackVibroLed);
    CHECK(!app_settings_sound(&s));

    put_v1_file(TransportKindUsb);
    s = loaded();
    CHECK_EQ_INT(app_settings_transport(&s), TransportKindUsb);
}

static void test_v1_file_with_unknown_transport_loads_defaults(void) {
    put_v1_file(7);
    AppSettings s = loaded();
    check_defaults(&s);
}

static void test_v1_payload_with_a_wrong_inner_version_loads_defaults(void) {
    put_v1_file(TransportKindBluetooth);
    file[0] = 3;
    AppSettings s = loaded();
    check_defaults(&s);
}

static void test_migrated_v1_saves_as_v2(void) {
    put_v1_file(TransportKindBluetooth);
    AppSettings s = loaded();
    CHECK(app_settings_save(&s, &storage));
    CHECK_EQ_INT(file_version, 2);
    CHECK_EQ_INT(file_size, 5);
    AppSettings back = loaded();
    CHECK_EQ_INT(app_settings_transport(&back), TransportKindBluetooth);
    CHECK(!app_settings_autosave(&back));
}

static void test_other_versions_load_defaults(void) {
    put_v2_file(TransportKindBluetooth, 1, AppFeedbackLed, 1);
    file_version = 3;
    AppSettings s = loaded();
    check_defaults(&s);

    put_v2_file(TransportKindBluetooth, 1, AppFeedbackLed, 1);
    file_version = 0;
    s = loaded();
    check_defaults(&s);

    /* the header says 2, the payload says otherwise */
    put_v2_file(TransportKindBluetooth, 1, AppFeedbackLed, 1);
    file[0] = 1;
    s = loaded();
    check_defaults(&s);
}

static void test_wrong_size_loads_defaults(void) {
    /* a version 2 header on a version 1 sized payload */
    put_v1_file(TransportKindBluetooth);
    file_version = 2;
    AppSettings s = loaded();
    check_defaults(&s);

    put_v2_file(TransportKindBluetooth, 1, AppFeedbackLed, 1);
    file_size = 4;
    s = loaded();
    check_defaults(&s);

    put_v2_file(TransportKindBluetooth, 1, AppFeedbackLed, 1);
    file_size = 6;
    s = loaded();
    check_defaults(&s);
}

static void test_out_of_range_fields_load_defaults(void) {
    put_v2_file(7, 0, AppFeedbackLed, 0);
    AppSettings s = loaded();
    check_defaults(&s);

    put_v2_file(TransportKindBluetooth, 2, AppFeedbackLed, 0);
    s = loaded();
    check_defaults(&s);

    put_v2_file(TransportKindBluetooth, 1, 3, 0);
    s = loaded();
    check_defaults(&s);

    put_v2_file(TransportKindBluetooth, 1, AppFeedbackLed, 0xFF);
    s = loaded();
    check_defaults(&s);
}

static void test_save_round_trips_every_field(void) {
    reset_file();
    AppSettings s;
    app_settings_defaults(&s);
    app_settings_set_transport(&s, TransportKindBluetooth);
    app_settings_set_autosave(&s, true);
    app_settings_set_feedback(&s, AppFeedbackLed);
    app_settings_set_sound(&s, true);
    CHECK(app_settings_save(&s, &storage));
    CHECK_EQ_INT(saves, 1);
    CHECK_EQ_INT(file_version, 2);
    CHECK_EQ_INT(file_size, 5);
    CHECK_EQ_INT(file[0], 2);
    CHECK_EQ_INT(file[1], TransportKindBluetooth);
    CHECK_EQ_INT(file[2], 1);
    CHECK_EQ_INT(file[3], AppFeedbackLed);
    CHECK_EQ_INT(file[4], 1);
    AppSettings back = loaded();
    CHECK_EQ_INT(app_settings_transport(&back), TransportKindBluetooth);
    CHECK(app_settings_autosave(&back));
    CHECK_EQ_INT(app_settings_feedback(&back), AppFeedbackLed);
    CHECK(app_settings_sound(&back));
}

static void test_failed_save_is_reported(void) {
    reset_file();
    save_fails = true;
    AppSettings s;
    app_settings_defaults(&s);
    CHECK(!app_settings_save(&s, &storage));
}

static void test_set_transport_ignores_unknown_kinds(void) {
    AppSettings s;
    app_settings_defaults(&s);
    app_settings_set_transport(&s, TransportKindBluetooth);
    app_settings_set_transport(&s, (TransportKind)9);
    CHECK_EQ_INT(app_settings_transport(&s), TransportKindBluetooth);
}

static void test_set_feedback_ignores_unknown_values(void) {
    AppSettings s;
    app_settings_defaults(&s);
    app_settings_set_feedback(&s, AppFeedbackOff);
    CHECK_EQ_INT(app_settings_feedback(&s), AppFeedbackOff);
    app_settings_set_feedback(&s, (AppFeedback)3);
    CHECK_EQ_INT(app_settings_feedback(&s), AppFeedbackOff);
    app_settings_set_feedback(&s, AppFeedbackVibroLed);
    CHECK_EQ_INT(app_settings_feedback(&s), AppFeedbackVibroLed);
}

static void test_set_autosave_and_sound_toggle(void) {
    AppSettings s;
    app_settings_defaults(&s);
    app_settings_set_autosave(&s, true);
    app_settings_set_sound(&s, true);
    CHECK_EQ_INT(s.autosave, 1);
    CHECK_EQ_INT(s.sound, 1);
    app_settings_set_autosave(&s, false);
    app_settings_set_sound(&s, false);
    CHECK(!app_settings_autosave(&s));
    CHECK(!app_settings_sound(&s));
}

int main(void) {
    RUN_TEST(test_settings_live_in_the_flibuddy_dir);
    RUN_TEST(test_layout_is_version_transport_autosave_feedback_sound);
    RUN_TEST(test_defaults_are_usb_autosave_off_vibro_led_silent);
    RUN_TEST(test_missing_file_loads_defaults);
    RUN_TEST(test_saved_v2_file_loads);
    RUN_TEST(test_v1_file_keeps_the_transport_and_defaults_the_rest);
    RUN_TEST(test_v1_file_with_unknown_transport_loads_defaults);
    RUN_TEST(test_v1_payload_with_a_wrong_inner_version_loads_defaults);
    RUN_TEST(test_migrated_v1_saves_as_v2);
    RUN_TEST(test_other_versions_load_defaults);
    RUN_TEST(test_wrong_size_loads_defaults);
    RUN_TEST(test_out_of_range_fields_load_defaults);
    RUN_TEST(test_save_round_trips_every_field);
    RUN_TEST(test_failed_save_is_reported);
    RUN_TEST(test_set_transport_ignores_unknown_kinds);
    RUN_TEST(test_set_feedback_ignores_unknown_values);
    RUN_TEST(test_set_autosave_and_sound_toggle);
    return MINITEST_RESULT();
}
