/* Scene list of the FAP. flibuddy_app.c maps each AppScreen to one of
 * them (scene_for); scenes render from the state and send user input to
 * flibuddy_reduce(). */
#pragma once

#include <gui/scene_manager.h>

#define FLIBUDDY_SCENES(X)       \
    X(idle, Idle)                \
    X(reading, Reading)          \
    X(result, Result)            \
    X(enter_weight, EnterWeight) \
    X(waiting, Waiting)          \
    X(done, Done)                \
    X(transport, Transport)

#define FLIBUDDY_SCENE_ENUM(name, Name) FliBuddyScene##Name,
typedef enum {
    FLIBUDDY_SCENES(FLIBUDDY_SCENE_ENUM) FliBuddySceneCount,
} FliBuddyScene;
#undef FLIBUDDY_SCENE_ENUM

#define FLIBUDDY_SCENE_DECLARE(name, Name)                                     \
    void flibuddy_scene_##name##_on_enter(void* ctx);                          \
    bool flibuddy_scene_##name##_on_event(void* ctx, SceneManagerEvent event); \
    void flibuddy_scene_##name##_on_exit(void* ctx);
FLIBUDDY_SCENES(FLIBUDDY_SCENE_DECLARE)
#undef FLIBUDDY_SCENE_DECLARE

extern const SceneManagerHandlers flibuddy_scene_handlers;
