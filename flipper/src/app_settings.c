#include "app_settings.h"

static bool known_transport(unsigned kind) {
    return kind == TransportKindUsb || kind == TransportKindBluetooth;
}

static bool known_feedback(unsigned feedback) {
    return feedback == AppFeedbackVibroLed || feedback == AppFeedbackLed ||
           feedback == AppFeedbackOff;
}

static bool valid(const AppSettings* s) {
    return s->version == APP_SETTINGS_VERSION && known_transport(s->transport) &&
           s->autosave <= 1 && known_feedback(s->feedback) && s->sound <= 1;
}

void app_settings_defaults(AppSettings* settings) {
    settings->version = APP_SETTINGS_VERSION;
    settings->transport = TransportKindUsb;
    settings->autosave = 0;
    settings->feedback = AppFeedbackVibroLed;
    settings->sound = 0;
}

void app_settings_load(AppSettings* settings, const AppSettingsStorage* storage) {
    AppSettings stored;
    AppSettingsV1 v1;
    if(storage->load(storage->ctx, APP_SETTINGS_VERSION, &stored, sizeof(stored)) &&
       valid(&stored)) {
        *settings = stored;
    } else if(
        storage->load(storage->ctx, 1, &v1, sizeof(v1)) && v1.version == 1 &&
        known_transport(v1.transport)) {
        app_settings_defaults(settings);
        settings->transport = v1.transport;
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

bool app_settings_autosave(const AppSettings* settings) {
    return settings->autosave != 0;
}

void app_settings_set_autosave(AppSettings* settings, bool on) {
    settings->autosave = on ? 1 : 0;
}

AppFeedback app_settings_feedback(const AppSettings* settings) {
    return (AppFeedback)settings->feedback;
}

void app_settings_set_feedback(AppSettings* settings, AppFeedback feedback) {
    if(known_feedback(feedback)) settings->feedback = (uint8_t)feedback;
}

bool app_settings_sound(const AppSettings* settings) {
    return settings->sound != 0;
}

void app_settings_set_sound(AppSettings* settings, bool on) {
    settings->sound = on ? 1 : 0;
}
