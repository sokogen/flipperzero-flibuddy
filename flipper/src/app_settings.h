/* The app's persisted settings: which transport to run.
 *
 * The file is a saved_struct (magic APP_SETTINGS_MAGIC, version
 * APP_SETTINGS_VERSION) at APP_SETTINGS_PATH. The file access sits behind
 * AppSettingsStorage so that the choice logic here is tested on the host;
 * app_settings_file.c is the SDK backend. A missing or unreadable file, a
 * wrong version or an unknown transport loads the defaults (USB).
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "transport.h"

#define APP_SETTINGS_PARENT  "/ext/apps_data"
#define APP_SETTINGS_DIR     APP_SETTINGS_PARENT "/spoolbuddy"
#define APP_SETTINGS_PATH    APP_SETTINGS_DIR "/settings.bin"
#define APP_SETTINGS_MAGIC   0x5B
#define APP_SETTINGS_VERSION 1

typedef struct {
    uint8_t version; /* APP_SETTINGS_VERSION */
    uint8_t transport; /* TransportKind */
} AppSettings;

typedef struct {
    /* Read exactly `size` bytes of the stored struct; false when there is
     * none, it does not match or cannot be read. */
    bool (*load)(void* ctx, void* data, size_t size);
    /* Store `size` bytes; false when the file could not be written. */
    bool (*save)(void* ctx, const void* data, size_t size);
    void* ctx;
} AppSettingsStorage;

void app_settings_defaults(AppSettings* settings);

/* Always leaves valid settings: the stored ones or the defaults. */
void app_settings_load(AppSettings* settings, const AppSettingsStorage* storage);

bool app_settings_save(const AppSettings* settings, const AppSettingsStorage* storage);

TransportKind app_settings_transport(const AppSettings* settings);

/* Unknown kinds are ignored. */
void app_settings_set_transport(AppSettings* settings, TransportKind kind);
