#pragma once

// Starts watching for the game's SDL window and attaches the touch overlay
// (touch_controls.m). Call on the main thread before the game's main().
void ut_touch_controls_start(void);
