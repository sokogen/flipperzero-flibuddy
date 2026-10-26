#include "minitest.h"

#include "app_settings.h"

/* The fake file: what load hands back, what save received. */
static uint8_t file[sizeof(AppSettings)];
static size_t file_size;
static bool file_present;
static bool save_fails;
static int saves;

static bool fake_load(void* ctx, void* data, size_t size) {
    (void)ctx;
    if(!file_present || size != file_size) return false;
    memcpy(data, file, size);
    return true;
}

static bool fake_save(void* ctx, const void* data, size_t size) {
    (void)ctx;
    saves++;
    if(save_fails || size > sizeof(file)) return false;
    memcpy(file, data, size);
    file_size = size;
    file_present = true;
    return true;
}

static const AppSettingsStorage storage = {.load = fake_load, .save = fake_save, .ctx = NULL};

static void reset_file(void) {
    memset(file, 0, sizeof(file));
    file_size = 0;
    file_present = false;
    save_fails = false;
    saves = 0;
}

static void put_file(uint8_t version, uint8_t transport) {
    file[0] = version;
    file[1] = transport;
    file_size = sizeof(AppSettings);
    file_present = true;
}

static AppSettings loaded(void) {
    AppSettings s;
    memset(&s, 0xAA, sizeof(s));
    app_settings_load(&s, &storage);
    return s;
}

static void test_layout_is_version_then_transport(void) {
    CHECK_EQ_INT(sizeof(AppSettings), 2);
    CHECK_EQ_INT(APP_SETTINGS_VERSION, 1);
    CHECK_EQ_INT(APP_SETTINGS_MAGIC, 0x5B);
}

static void test_defaults_are_usb(void) {
    AppSettings s;
    app_settings_defaults(&s);
    CHECK_EQ_INT(s.version, APP_SETTINGS_VERSION);
    CHECK_EQ_INT(app_settings_transport(&s), TransportKindUsb);
}

static void test_missing_file_loads_defaults(void) {
    reset_file();
    AppSettings s = loaded();
    CHECK_EQ_INT(s.version, APP_SETTINGS_VERSION);
    CHECK_EQ_INT(app_settings_transport(&s), TransportKindUsb);
}

static void test_saved_bluetooth_loads(void) {
    reset_file();
    put_file(1, 1);
    AppSettings s = loaded();
    CHECK_EQ_INT(app_settings_transport(&s), TransportKindBluetooth);
    put_file(1, 0);
    s = loaded();
    CHECK_EQ_INT(app_settings_transport(&s), TransportKindUsb);
}

static void test_wrong_version_loads_defaults(void) {
    reset_file();
    put_file(2, 1);
    AppSettings s = loaded();
    CHECK_EQ_INT(s.version, APP_SETTINGS_VERSION);
    CHECK_EQ_INT(app_settings_transport(&s), TransportKindUsb);
    put_file(0, 1);
    s = loaded();
    CHECK_EQ_INT(app_settings_transport(&s), TransportKindUsb);
}

static void test_unknown_transport_loads_defaults(void) {
    reset_file();
    put_file(1, 7);
    AppSettings s = loaded();
    CHECK_EQ_INT(s.transport, TransportKindUsb);
}

static void test_wrong_size_loads_defaults(void) {
    reset_file();
    put_file(1, 1);
    file_size = 1;
    AppSettings s = loaded();
    CHECK_EQ_INT(app_settings_transport(&s), TransportKindUsb);
}

static void test_save_writes_version_and_transport(void) {
    reset_file();
    AppSettings s;
    app_settings_defaults(&s);
    app_settings_set_transport(&s, TransportKindBluetooth);
    CHECK(app_settings_save(&s, &storage));
    CHECK_EQ_INT(saves, 1);
    CHECK_EQ_INT(file_size, 2);
    CHECK_EQ_INT(file[0], 1);
    CHECK_EQ_INT(file[1], 1);
    AppSettings back = loaded();
    CHECK_EQ_INT(app_settings_transport(&back), TransportKindBluetooth);
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

int main(void) {
    RUN_TEST(test_layout_is_version_then_transport);
    RUN_TEST(test_defaults_are_usb);
    RUN_TEST(test_missing_file_loads_defaults);
    RUN_TEST(test_saved_bluetooth_loads);
    RUN_TEST(test_wrong_version_loads_defaults);
    RUN_TEST(test_unknown_transport_loads_defaults);
    RUN_TEST(test_wrong_size_loads_defaults);
    RUN_TEST(test_save_writes_version_and_transport);
    RUN_TEST(test_failed_save_is_reported);
    RUN_TEST(test_set_transport_ignores_unknown_kinds);
    return MINITEST_RESULT();
}
