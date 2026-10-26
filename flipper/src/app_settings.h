/* The app's persisted settings: the transport, Auto-save new, Feedback and
 * Sound.
 *
 * The file is a saved_struct (magic APP_SETTINGS_MAGIC, version
 * APP_SETTINGS_VERSION) at APP_SETTINGS_PATH. The file access sits behind
 * AppSettingsStorage so that the choice logic here is tested on the host;
 * app_settings_file.c is the SDK backend. A version 1 file keeps its
 * transport and takes the defaults for the rest. A missing or unreadable
 * file, another version or any out-of-range field loads the defaults (USB,
 * Auto-save off, Vibro+LED, Sound off).
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "transport.h"

#define APP_SETTINGS_PARENT  "/ext/apps_data"
#define APP_SETTINGS_DIR     APP_SETTINGS_PARENT "/flibuddy"
#define APP_SETTINGS_PATH    APP_SETTINGS_DIR "/settings.bin"
#define APP_SETTINGS_MAGIC   0x5B
#define APP_SETTINGS_VERSION 2

/* Stored in the settings file, so the numbers never change. */
typedef enum {
    AppFeedbackVibroLed = 0,
    AppFeedbackLed = 1,
    AppFeedbackOff = 2,
} AppFeedback;

typedef struct {
    uint8_t version; /* APP_SETTINGS_VERSION */
    uint8_t transport; /* TransportKind */
    uint8_t autosave; /* 0 or 1 */
    uint8_t feedback; /* AppFeedback */
    uint8_t sound; /* 0 or 1 */
} AppSettings;

/* The version 1 file, read only to migrate it. */
typedef struct {
    uint8_t version; /* 1 */
    uint8_t transport; /* TransportKind */
} AppSettingsV1;

typedef struct {
    /* Read exactly `size` bytes of a struct stored as `version`; false when
     * there is none, it does not match or cannot be read. */
    bool (*load)(void* ctx, uint8_t version, void* data, size_t size);
    /* Store `size` bytes as APP_SETTINGS_VERSION; false when the file could
     * not be written. */
    bool (*save)(void* ctx, const void* data, size_t size);
    void* ctx;
} AppSettingsStorage;

void app_settings_defaults(AppSettings* settings);

/* Always leaves valid settings: the stored ones, migrated ones or the
 * defaults. */
void app_settings_load(AppSettings* settings, const AppSettingsStorage* storage);

bool app_settings_save(const AppSettings* settings, const AppSettingsStorage* storage);

TransportKind app_settings_transport(const AppSettings* settings);

/* Unknown kinds are ignored. */
void app_settings_set_transport(AppSettings* settings, TransportKind kind);

bool app_settings_autosave(const AppSettings* settings);

void app_settings_set_autosave(AppSettings* settings, bool on);

AppFeedback app_settings_feedback(const AppSettings* settings);

/* Unknown values are ignored. */
void app_settings_set_feedback(AppSettings* settings, AppFeedback feedback);

bool app_settings_sound(const AppSettings* settings);

void app_settings_set_sound(AppSettings* settings, bool on);
