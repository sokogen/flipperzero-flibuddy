/* Scene list of the FAP. spoolbuddy_app.c maps each AppScreen to one of
 * them (scene_for); scenes render from the state and send user input to
 * spoolbuddy_reduce(). */
#pragma once

#include <gui/scene_manager.h>

#define SPOOLBUDDY_SCENES(X)     \
    X(idle, Idle)                \
    X(reading, Reading)          \
    X(result, Result)            \
    X(enter_weight, EnterWeight) \
    X(waiting, Waiting)          \
    X(done, Done)

#define SPOOLBUDDY_SCENE_ENUM(name, Name) SpoolBuddyScene##Name,
typedef enum {
    SPOOLBUDDY_SCENES(SPOOLBUDDY_SCENE_ENUM) SpoolBuddySceneCount,
} SpoolBuddyScene;
#undef SPOOLBUDDY_SCENE_ENUM

#define SPOOLBUDDY_SCENE_DECLARE(name, Name)                                     \
    void spoolbuddy_scene_##name##_on_enter(void* ctx);                          \
    bool spoolbuddy_scene_##name##_on_event(void* ctx, SceneManagerEvent event); \
    void spoolbuddy_scene_##name##_on_exit(void* ctx);
SPOOLBUDDY_SCENES(SPOOLBUDDY_SCENE_DECLARE)
#undef SPOOLBUDDY_SCENE_DECLARE

extern const SceneManagerHandlers spoolbuddy_scene_handlers;
