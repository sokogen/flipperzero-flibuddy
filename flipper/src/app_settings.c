#include "app_settings.h"

static bool known_transport(unsigned kind) {
    return kind == TransportKindUsb || kind == TransportKindBluetooth;
}

void app_settings_defaults(AppSettings* settings) {
    settings->version = APP_SETTINGS_VERSION;
    settings->transport = TransportKindUsb;
}

void app_settings_load(AppSettings* settings, const AppSettingsStorage* storage) {
    AppSettings stored;
    if(storage->load(storage->ctx, &stored, sizeof(stored)) &&
       stored.version == APP_SETTINGS_VERSION && known_transport(stored.transport)) {
        *settings = stored;
    } else {
        app_settings_defaults(settings);
    }
}

bool app_settings_save(const AppSettings* settings, const AppSettingsStorage* storage) {
    return storage->save(storage->ctx, settings, sizeof(*settings));
}

TransportKind app_settings_transport(const AppSettings* settings) {
    return (TransportKind)settings->transport;
}

void app_settings_set_transport(AppSettings* settings, TransportKind kind) {
    if(known_transport(kind)) settings->transport = (uint8_t)kind;
}
