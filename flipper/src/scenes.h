/* Scene list of the FAP. One scene per AppScreen, added task by task. */
#pragma once

#include <gui/scene_manager.h>

#define SPOOLBUDDY_SCENES(X) X(idle, Idle)

#define SPOOLBUDDY_SCENE_ENUM(name, Name) SpoolBuddyScene##Name,
typedef enum {
    SPOOLBUDDY_SCENES(SPOOLBUDDY_SCENE_ENUM) SpoolBuddySceneCount,
} SpoolBuddyScene;
#undef SPOOLBUDDY_SCENE_ENUM

#define SPOOLBUDDY_SCENE_DECLARE(name, Name)                                  \
    void spoolbuddy_scene_##name##_on_enter(void* ctx);                     \
    bool spoolbuddy_scene_##name##_on_event(void* ctx, SceneManagerEvent event); \
    void spoolbuddy_scene_##name##_on_exit(void* ctx);
SPOOLBUDDY_SCENES(SPOOLBUDDY_SCENE_DECLARE)
#undef SPOOLBUDDY_SCENE_DECLARE

extern const SceneManagerHandlers spoolbuddy_scene_handlers;
