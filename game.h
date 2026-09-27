/*
 * game.h - "TFT4 Invaders": the FR6989 Invaders game, in color, on the tft4
 *          driver (Educational BoosterPack MKII 128x128 TFT, MSP-EXP430FR6989).
 *
 * The game only draws into tft4's Back buffer; the platform (main.c) owns the
 * clocks, timers, input and calls LcdPresent / LcdPresentFull.
 */
#ifndef GAME_H
#define GAME_H

#include <stdint.h>

#define GAME_FPS    25          /* frame rate the platform calls game_frame() at */

#define BTN_LEFT    0x01        /* S1 or joystick left */
#define BTN_RIGHT   0x02        /* S2 or joystick right */

/* game_frame() result */
#define GAME_PRESENT_FULL  0x01 /* the palette changed: send the whole screen */

void    game_init(void);
uint8_t game_frame(uint8_t buttons);    /* update one tick, draw into Back */

#ifdef GAME_SIM
/* Read-only view for the emulator test's autopilot. */
typedef struct GameDebug {
    uint8_t  state;             /* 0 title, 1 play, 2 dying, 3 wave, 4 pause, 5 over */
    int16_t  px;
    uint16_t score;
    uint8_t  lives, wave, aliveCount;
    int16_t  formX, formY;
    uint8_t  alive[4];
    struct { int16_t x, y; uint8_t on; } eshot[6];
} GameDebug;
void game_debug(GameDebug *d);
#endif

#endif /* GAME_H */
