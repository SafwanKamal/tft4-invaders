/*
 * game.c - "TFT4 Invaders": game logic and rendering. See game.h.
 *
 * The game logic is FR6989 Invaders (same rules, same timing); the drawing is
 * new: 16 colors through the tft4 driver, a 3-layer scrolling starfield,
 * explosion particles, scaled title text, and a palette flash when the
 * player is hit. Every frame is drawn from scratch into tft4's Back buffer
 * ("full redraw" mode); LcdPresent then sends only the pixels that changed.
 *
 * Screen layout (128 x 128):
 *     0..8    HUD: score / hi-score
 *    12..17   UFO lane
 *    24..     invader formation (4 rows x 8 columns), marches and descends
 *    96..103  three destructible bunkers
 *   110..115  player ship
 *   119       ground line
 *   120..127  lives, double-shot meter, wave number
 *
 * Controls: S1 / joystick left = left, S2 / joystick right = right, fire is
 *           automatic. Hold both for 1 s to pause; press any to resume.
 */
#include <string.h>
#include "game.h"
#include "tft4.h"
#include "sprites.h"

/* ---------------------------------------------------------------- colors */
enum { C_BLACK, C_NAVY, C_PLUM, C_DKGREEN, C_BROWN, C_DKGREY, C_LTGREY, C_WHITE,
       C_RED, C_ORANGE, C_YELLOW, C_GREEN, C_SKY, C_LAVENDER, C_PINK, C_PEACH };

/* ---------------------------------------------------------------- tuning */
#define FPS                 GAME_FPS
#define SCR_W               TFT4_WIDTH
#define HUD_H               10
#define UFO_Y               12
#define FORM_ROWS           4
#define FORM_COLS           8
#define COL_DX              12
#define ROW_DY              10
#define INV_W               8
#define INV_H               6
#define FORM_W              ((FORM_COLS - 1) * COL_DX + INV_W)
#define FORM_Y0             24
#define FORM_STEP_X         2
#define FORM_STEP_Y         4
#define BUNKERS             3
#define BUNKER_W            16
#define BUNKER_H            8
#define BUNKER_Y            96
#define PLAYER_W            9
#define PLAYER_H            6
#define PLAYER_Y            110
#define PLAYER_SPEED        2
#define GROUND_Y            119
#define UFO_W               16
#define UFO_H               6
#define PSHOT_H             5
#define PSHOT_SPEED         4
#define PSHOT_COOLDOWN      10
#define ESHOT_W             3
#define ESHOT_H             5
#define CAP_W               7
#define CAP_H               7
#define MAX_PSHOTS          4
#define MAX_ESHOTS          6
#define MAX_FX              8
#define DOUBLE_SHOT_FRAMES  (12 * FPS)
#define EXTRA_LIFE_SCORE    1500
#define START_LIVES         3
#define MAX_LIVES           5
#define STARS               36          /* 3 layers of 12 */
#define MAX_PARTS           40          /* explosion particles */

enum { ST_TITLE, ST_PLAY, ST_DYING, ST_WAVE, ST_PAUSE, ST_OVER };
enum { FX_NONE, FX_BOOM, FX_SPARK, FX_SCORE };
enum { HUE_FIRE, HUE_ICE };

typedef struct { int16_t x, y; uint8_t on; } Shot;
typedef struct { int16_t x, y; uint8_t kind, ttl; uint16_t val; } Fx;
typedef struct { int16_t x, y; int8_t vx, vy; uint8_t ttl, hue; } Part;  /* x, y in 1/16 px */
typedef struct { uint16_t y; uint8_t x; } Star;                            /* y in 1/256 px */

static const int16_t  kBunkerX[BUNKERS]   = { 14, 56, 98 };
static const uint16_t kBunkerMask[BUNKER_H] = { 0x0FF0, 0x3FFC, 0x7FFE, 0xFFFF, 0xFFFF, 0xFFFF, 0xF81F, 0xF00F };
static const uint8_t  kRowPoints[FORM_ROWS] = { 30, 20, 20, 10 };
static const uint16_t kUfoPoints[4]       = { 50, 100, 150, 300 };
static const uint8_t * const kInvader[FORM_ROWS][2] = {
    { SprSquidA, SprSquidB },
    { SprCrabA,  SprCrabB  },
    { SprCrabA,  SprCrabB  },
    { SprOctoA,  SprOctoB  },
};
/* star layers: speed (1/256 px per frame) and color */
static const uint16_t kStarSpeed[3] = { 48, 110, 230 };
static const uint8_t  kStarColor[3] = { C_NAVY, C_DKGREY, C_LTGREY };
/* 16 directions, radius 16 (particle velocity in 1/16 px per frame) */
static const int8_t kDirX[16] = { 16, 15, 11, 6, 0, -6, -11, -15, -16, -15, -11, -6, 0, 6, 11, 15 };
static const int8_t kDirY[16] = { 0, 6, 11, 15, 16, 15, 11, 6, 0, -6, -11, -15, -16, -15, -11, -6 };

/* ------------------------------------------------------------ game state */
static struct {
    uint8_t  state;
    uint16_t stateTimer;
    uint16_t frame;
    uint16_t rng;
    uint8_t  prevButtons, bothHeld, pauseArmed, newHi, flash;

    uint16_t score;
    uint8_t  lives, wave, extraGiven;

    int16_t  px;
    uint8_t  pCool;
    uint16_t doubleShot;
    Shot     pshot[MAX_PSHOTS];

    uint8_t  alive[FORM_ROWS];      /* bit c = column c alive */
    uint8_t  aliveCount;
    int16_t  formX, formY;
    int8_t   formDir;
    uint8_t  stepTimer, anim;

    Shot     eshot[MAX_ESHOTS];
    uint8_t  eCool;

    uint8_t  ufoOn;
    int8_t   ufoDir;
    int16_t  ufoX;
    uint16_t ufoTimer;

    uint8_t  capOn;
    int16_t  capX, capY;

    uint16_t bunker[BUNKERS][BUNKER_H];
    Fx       fx[MAX_FX];
    Part     part[MAX_PARTS];
    Star     star[STARS];
} g;

static uint8_t s_bunkerSpr[2 + BUNKER_H * BUNKER_W / 2];   /* built each frame */

/* High score survives power cycles: it lives in FRAM, in .TI.persistent
 * next to tft4's frame buffers. DATA_SECTION instead of PERSISTENT: the
 * driver's (assembly) part of that section is an ordinary initialized one,
 * and the linker won't mix it with the NOINIT kind PERSISTENT makes. */
#if defined(__TI_COMPILER_VERSION__) && !defined(__clang__)
#pragma DATA_SECTION(s_hiScore, ".TI.persistent")
static uint16_t s_hiScore = 0;
#else
static uint16_t s_hiScore = 0;
#endif

/* ------------------------------------------------------------- utilities */
static uint16_t rnd(void)                       /* xorshift16 */
{
    uint16_t x = g.rng;
    x ^= (uint16_t)(x << 7);
    x ^= (uint16_t)(x >> 9);
    x ^= (uint16_t)(x << 8);
    g.rng = x;
    return x;
}

static uint8_t overlap(int16_t ax, int16_t ay, int16_t aw, int16_t ah,
                       int16_t bx, int16_t by, int16_t bw, int16_t bh)
{
    return (ax < bx + bw) && (bx < ax + aw) && (ay < by + bh) && (by < ay + ah);
}

static char *putU(char *d, uint16_t v, uint8_t width)   /* zero-padded, width <= 5 */
{
    static const uint16_t kPlace[5] = { 10000, 1000, 100, 10, 1 };
    uint8_t i;
    for (i = 5 - width; i < 5; i++) {           /* by subtraction: the MSP430 */
        char c = '0';                           /* has no divide instruction */
        while (v >= kPlace[i]) { v -= kPlace[i]; c++; }
        *d++ = c;
    }
    *d = '\0';
    return d;
}

static char *putS(char *d, const char *s)
{
    while (*s) *d++ = *s++;
    *d = '\0';
    return d;
}

static void text(const char *s, int16_t x, int16_t y, uint8_t ink)
{
    FbText(s, x, y, TFT4_TEXT(ink, TFT4_CLEAR));
}

static void textC(const char *s, int16_t cx, int16_t cy, uint8_t ink)   /* centered */
{
    int16_t n = 0;
    while (s[n]) n++;
    text(s, cx - n * 3, cy - 4, ink);
}

/* Big text: the 6x8 font scaled up, each font row in its own color, with a
 * shadow. Runs of set pixels become one FbFillRect each. */
static void bigText(const char *s, int16_t cx, int16_t y, uint8_t scale, const uint8_t *rowColor)
{
    int16_t n = 0, x0, pass;
    while (s[n]) n++;
    x0 = cx - n * 3 * scale;
    for (pass = 0; pass < 2; pass++) {              /* shadow first, then the text */
        int16_t off = pass ? 0 : 1, i;
        for (i = 0; i < n; i++) {
            const uint8_t *gl = &Font6x8[(uint8_t)(s[i] - 32) * 8];
            uint8_t r;
            for (r = 0; r < 7; r++) {
                uint8_t bits = gl[r], c = 0;
                while (c < 5) {
                    uint8_t run = 0;
                    while (c + run < 5 && (bits & (0x20 >> (c + run)))) run++;
                    if (run) {
                        FbFillRect(x0 + (i * 6 + c) * scale + off, y + r * scale + off,
                                   TFT4_WH(run * scale, scale), pass ? rowColor[r] : C_PLUM);
                        c += run;
                    } else {
                        c++;
                    }
                }
            }
        }
    }
}

static void addFx(uint8_t kind, int16_t x, int16_t y, uint8_t ttl, uint16_t val)
{
    uint8_t i, best = 0;
    for (i = 0; i < MAX_FX; i++) {
        if (g.fx[i].kind == FX_NONE) { best = i; break; }
        if (g.fx[i].ttl < g.fx[best].ttl) best = i;       /* recycle oldest */
    }
    g.fx[best].kind = kind; g.fx[best].x = x; g.fx[best].y = y;
    g.fx[best].ttl = ttl;   g.fx[best].val = val;
}

/* n particles flying out of (x, y), in 16 directions with random speed */
static void burst(int16_t x, int16_t y, uint8_t n, uint8_t hue)
{
    uint8_t i, k = 0;
    while (n--) {
        uint16_t r = rnd();
        uint8_t d = r & 15, sp = 1 + ((r >> 4) & 3);    /* speed 1 + 1/2..1/16 */
        while (k < MAX_PARTS && g.part[k].ttl) k++;
        if (k == MAX_PARTS) {                           /* full: reuse the oldest */
            k = 0;
            for (i = 1; i < MAX_PARTS; i++) if (g.part[i].ttl < g.part[k].ttl) k = i;
        }
        g.part[k].x = x << 4;
        g.part[k].y = y << 4;
        g.part[k].vx = (int8_t)(kDirX[d] + (kDirX[d] >> sp));   /* 1..1.5 x */
        g.part[k].vy = (int8_t)(kDirY[d] + (kDirY[d] >> sp) - 6);
        g.part[k].ttl = 10 + ((r >> 8) & 7);
        g.part[k].hue = hue;
    }
}

static void addScore(uint16_t v)
{
    g.score = (g.score > 65535u - v) ? 65535u : (uint16_t)(g.score + v);
    if (!g.extraGiven && g.score >= EXTRA_LIFE_SCORE) {
        g.extraGiven = 1;
        if (g.lives < MAX_LIVES) g.lives++;
    }
}

/* --------------------------------------------------------------- bunkers */
static int8_t bunkerAt(int16_t x, int16_t y)    /* bunker index with a solid pixel, or -1 */
{
    uint8_t b;
    if (y < BUNKER_Y || y >= BUNKER_Y + BUNKER_H) return -1;
    for (b = 0; b < BUNKERS; b++) {
        int16_t dx = x - kBunkerX[b];
        if (dx >= 0 && dx < BUNKER_W)
            return (g.bunker[b][y - BUNKER_Y] & (0x8000u >> dx)) ? (int8_t)b : -1;
    }
    return -1;
}

static void bunkerClear(int16_t x, int16_t y)
{
    uint8_t b;
    if (y < BUNKER_Y || y >= BUNKER_Y + BUNKER_H) return;
    for (b = 0; b < BUNKERS; b++) {
        int16_t dx = x - kBunkerX[b];
        if (dx >= 0 && dx < BUNKER_W)
            g.bunker[b][y - BUNKER_Y] &= (uint16_t)~(0x8000u >> dx);
    }
}

static void bunkerErode(int16_t x, int16_t y)   /* ragged crater around (x, y) */
{
    int8_t dx, dy;
    for (dy = -2; dy <= 2; dy++) {
        for (dx = -2; dx <= 2; dx++) {
            uint8_t d = (uint8_t)((dx < 0 ? -dx : dx) + (dy < 0 ? -dy : dy));
            if (d <= 1 || (d <= 3 && (rnd() & 1)))
                bunkerClear(x + dx, y + dy);
        }
    }
    addFx(FX_SPARK, x - 1, y - 1, 3, 0);
}

static void bunkerClearRect(int16_t x, int16_t y, int16_t w, int16_t h)
{
    int16_t xx, yy;
    for (yy = y; yy < y + h; yy++)
        for (xx = x; xx < x + w; xx++)
            bunkerClear(xx, yy);
}

static void resetBunkers(void)
{
    uint8_t b;
    for (b = 0; b < BUNKERS; b++)
        memcpy(g.bunker[b], kBunkerMask, sizeof(g.bunker[b]));
}

/* ------------------------------------------------------------- formation */
static uint8_t aliveCols(void)
{
    return (uint8_t)(g.alive[0] | g.alive[1] | g.alive[2] | g.alive[3]);
}

static void formExtents(int8_t *minC, int8_t *maxC, int8_t *maxR)
{
    uint8_t cols = aliveCols();
    int8_t i;
    *minC = 0; *maxC = 0; *maxR = 0;
    for (i = 0; i < FORM_COLS; i++) if (cols & (1u << i)) { *minC = i; break; }
    for (i = FORM_COLS - 1; i >= 0; i--) if (cols & (1u << i)) { *maxC = i; break; }
    for (i = FORM_ROWS - 1; i >= 0; i--) if (g.alive[i]) { *maxR = i; break; }
}

static uint8_t stepInterval(void)
{
    int16_t i = 2 + g.aliveCount / 3 - (g.wave - 1);
    return (uint8_t)(i < 1 ? 1 : i);
}

static void resetWave(void)
{
    uint8_t r, lvl = (uint8_t)(g.wave - 1);
    for (r = 0; r < FORM_ROWS; r++) g.alive[r] = (uint8_t)((1u << FORM_COLS) - 1);
    g.aliveCount = FORM_ROWS * FORM_COLS;
    g.formX   = (SCR_W - FORM_W) / 2;
    g.formY   = FORM_Y0 + (lvl > 5 ? 5 : lvl) * FORM_STEP_Y;
    g.formDir = 1;
    g.stepTimer = 1;
    g.anim    = 0;
    g.eCool   = FPS;
    memset(g.pshot, 0, sizeof(g.pshot));
    memset(g.eshot, 0, sizeof(g.eshot));
    g.ufoOn   = 0;
    g.ufoTimer = (uint16_t)(FPS * 10 + rnd() % (FPS * 10));
    g.capOn   = 0;
    resetBunkers();
}

static void killPlayer(void)
{
    g.state = ST_DYING;
    g.stateTimer = 2 * FPS;
    if (g.lives) g.lives--;
    g.doubleShot = 0;
    g.capOn = 0;
    memset(g.eshot, 0, sizeof(g.eshot));
    burst(g.px + PLAYER_W / 2, PLAYER_Y + 2, 24, HUE_ICE);
    g.flash = 2;                                /* red flash through the palette */
}

static void gameOver(void)
{
    g.state = ST_OVER;
    g.stateTimer = 0;
    g.newHi = (g.score > s_hiScore);
    if (g.newHi) s_hiScore = g.score;          /* FRAM write */
}

static void updateFormation(void)
{
    int8_t minC, maxC, maxR, r, c;
    int16_t left, right, bottom;

    if (--g.stepTimer) return;
    g.stepTimer = stepInterval();

    formExtents(&minC, &maxC, &maxR);
    left  = g.formX + minC * COL_DX;
    right = g.formX + maxC * COL_DX + INV_W - 1;

    if ((g.formDir > 0 && right + FORM_STEP_X > SCR_W - 1) ||
        (g.formDir < 0 && left - FORM_STEP_X < 0)) {
        g.formY  += FORM_STEP_Y;
        g.formDir = (int8_t)-g.formDir;
    } else {
        g.formX += FORM_STEP_X * g.formDir;
    }
    g.anim ^= 1;

    bottom = g.formY + maxR * ROW_DY + INV_H - 1;

    if (bottom >= BUNKER_Y) {                   /* invaders crush the bunkers */
        for (r = 0; r < FORM_ROWS; r++)
            for (c = 0; c < FORM_COLS; c++)
                if (g.alive[r] & (1u << c))
                    bunkerClearRect(g.formX + c * COL_DX, g.formY + r * ROW_DY, INV_W, INV_H);
    }
    if (bottom >= PLAYER_Y) {                   /* invasion: game over */
        g.lives = 1;
        killPlayer();
    }
}

static void enemyFire(void)
{
    uint8_t i, active = 0, maxE, cols, c = 0, r, bit;
    int16_t maxDelay;

    if (g.eCool) { g.eCool--; return; }

    maxE = (uint8_t)(2 + g.wave);
    if (maxE > MAX_ESHOTS) maxE = MAX_ESHOTS;
    for (i = 0; i < MAX_ESHOTS; i++) active += g.eshot[i].on;
    cols = aliveCols();
    if (active >= maxE || !cols) return;

    if (rnd() & 1) {                            /* aim: column closest to player */
        int16_t best = 32767, pc = g.px + PLAYER_W / 2;
        for (i = 0; i < FORM_COLS; i++) {
            if (cols & (1u << i)) {
                int16_t d = g.formX + i * COL_DX + INV_W / 2 - pc;
                if (d < 0) d = -d;
                if (d < best) { best = d; c = i; }
            }
        }
    } else {                                    /* random live column */
        c = (uint8_t)(rnd() % FORM_COLS);
        while (!(cols & (1u << c))) c = (uint8_t)((c + 1) % FORM_COLS);
    }

    bit = (uint8_t)(1u << c);
    for (r = FORM_ROWS - 1; !(g.alive[r] & bit); r--) { }

    for (i = 0; i < MAX_ESHOTS; i++) {
        if (!g.eshot[i].on) {
            g.eshot[i].on = 1;
            g.eshot[i].x  = g.formX + c * COL_DX + (INV_W - ESHOT_W) / 2;
            g.eshot[i].y  = g.formY + r * ROW_DY + INV_H;
            break;
        }
    }

    maxDelay = 40 - 4 * (g.wave - 1);
    if (maxDelay < 12) maxDelay = 12;
    g.eCool = (uint8_t)(4 + rnd() % maxDelay);
}

/* ---------------------------------------------------------------- player */
static void movePlayer(uint8_t btn)
{
    if (btn == BTN_LEFT)  g.px -= PLAYER_SPEED;
    if (btn == BTN_RIGHT) g.px += PLAYER_SPEED;
    if (g.px < 0) g.px = 0;
    if (g.px > SCR_W - PLAYER_W) g.px = SCR_W - PLAYER_W;
}

static void spawnPShot(int16_t x)
{
    uint8_t i;
    for (i = 0; i < MAX_PSHOTS; i++) {
        if (!g.pshot[i].on) {
            g.pshot[i].on = 1;
            g.pshot[i].x  = x;
            g.pshot[i].y  = PLAYER_Y - PSHOT_H;
            return;
        }
    }
}

static void playerFire(void)                    /* automatic fire */
{
    uint8_t i, active = 0;
    if (g.pCool) { g.pCool--; return; }
    for (i = 0; i < MAX_PSHOTS; i++) active += g.pshot[i].on;

    if (g.doubleShot) {
        if (active > MAX_PSHOTS - 2) return;
        spawnPShot(g.px + 1);
        spawnPShot(g.px + PLAYER_W - 2);
    } else {
        if (active >= 2) return;
        spawnPShot(g.px + PLAYER_W / 2);
    }
    g.pCool = PSHOT_COOLDOWN;
}

static void killInvader(uint8_t r, uint8_t c)
{
    int16_t x = g.formX + c * COL_DX, y = g.formY + r * ROW_DY;
    g.alive[r] &= (uint8_t)~(1u << c);
    g.aliveCount--;
    addScore(kRowPoints[r]);
    addFx(FX_BOOM, x, y, 6, 0);
    burst(x + INV_W / 2, y + INV_H / 2, 8, HUE_FIRE);
    if (g.aliveCount == 0) {
        g.state = ST_WAVE;
        g.stateTimer = 2 * FPS;
        memset(g.eshot, 0, sizeof(g.eshot));
        g.ufoOn = 0;
    }
}

static void updatePShots(void)
{
    uint8_t i, j, r, c;
    int16_t yy;

    for (i = 0; i < MAX_PSHOTS; i++) {
        Shot *s = &g.pshot[i];
        if (!s->on) continue;
        s->y -= PSHOT_SPEED;
        if (s->y < HUD_H) { s->on = 0; continue; }

        /* invaders (quick reject against the formation box first) */
        if (g.aliveCount &&
            overlap(s->x, s->y, 1, PSHOT_H, g.formX, g.formY, FORM_W, (FORM_ROWS - 1) * ROW_DY + INV_H)) {
            for (r = 0; r < FORM_ROWS && s->on; r++)
                for (c = 0; c < FORM_COLS && s->on; c++)
                    if ((g.alive[r] & (1u << c)) &&
                        overlap(s->x, s->y, 1, PSHOT_H,
                                g.formX + c * COL_DX, g.formY + r * ROW_DY, INV_W, INV_H)) {
                        s->on = 0;
                        killInvader(r, c);
                    }
            if (!s->on) continue;
        }

        /* UFO */
        if (g.ufoOn && overlap(s->x, s->y, 1, PSHOT_H, g.ufoX, UFO_Y, UFO_W, UFO_H)) {
            uint16_t pts = kUfoPoints[rnd() & 3];
            s->on = 0;
            g.ufoOn = 0;
            g.ufoTimer = (uint16_t)(FPS * 15 + rnd() % (FPS * 10));
            addScore(pts);
            addFx(FX_SCORE, g.ufoX + (pts >= 100 ? 0 : 3), UFO_Y - 1, FPS, pts);
            burst(g.ufoX + UFO_W / 2, UFO_Y + 3, 16, HUE_FIRE);
            if (!g.capOn && !g.doubleShot) {            /* drop a power-up */
                g.capOn = 1;
                g.capX  = g.ufoX + (UFO_W - CAP_W) / 2;
                g.capY  = UFO_Y + UFO_H;
            }
            continue;
        }

        /* enemy bullets: shots cancel each other */
        for (j = 0; j < MAX_ESHOTS; j++) {
            Shot *e = &g.eshot[j];
            if (e->on && overlap(s->x, s->y, 1, PSHOT_H, e->x, e->y, ESHOT_W, ESHOT_H)) {
                e->on = 0; s->on = 0;
                addFx(FX_SPARK, e->x, e->y + 1, 4, 0);
                addScore(5);
                break;
            }
        }
        if (!s->on) continue;

        /* bunkers: check from the leading (top) end */
        for (yy = s->y; yy < s->y + PSHOT_H; yy++) {
            if (bunkerAt(s->x, yy) >= 0) {
                bunkerErode(s->x, yy);
                s->on = 0;
                break;
            }
        }
    }
}

static void updateEShots(void)
{
    uint8_t i;
    int16_t yy, xx, speed = (g.wave >= 3) ? 3 : 2;

    for (i = 0; i < MAX_ESHOTS; i++) {
        Shot *e = &g.eshot[i];
        if (!e->on) continue;
        e->y += speed;

        if (e->y + ESHOT_H - 1 >= GROUND_Y) {
            e->on = 0;
            addFx(FX_SPARK, e->x, GROUND_Y - 3, 4, 0);
            continue;
        }
        /* bunkers: check from the leading (bottom) end */
        for (yy = e->y + ESHOT_H - 1; yy >= e->y && e->on; yy--)
            for (xx = e->x; xx < e->x + ESHOT_W; xx++)
                if (bunkerAt(xx, yy) >= 0) {
                    bunkerErode(xx, yy);
                    e->on = 0;
                    break;
                }
        if (!e->on) continue;

        if (g.state == ST_PLAY &&
            overlap(e->x, e->y, ESHOT_W, ESHOT_H, g.px, PLAYER_Y, PLAYER_W, PLAYER_H)) {
            killPlayer();
            return;
        }
    }
}

static void updateUfo(void)
{
    if (!g.ufoOn) {
        if (g.ufoTimer) { g.ufoTimer--; return; }
        if (g.aliveCount < 6) { g.ufoTimer = FPS * 5; return; }
        g.ufoOn  = 1;
        g.ufoDir = (rnd() & 1) ? 1 : -1;
        g.ufoX   = (g.ufoDir > 0) ? -UFO_W : SCR_W;
        return;
    }
    g.ufoX += g.ufoDir;
    if (g.ufoX < -UFO_W || g.ufoX > SCR_W) {
        g.ufoOn = 0;
        g.ufoTimer = (uint16_t)(FPS * 15 + rnd() % (FPS * 10));
    }
}

static void updateCapsule(void)
{
    if (!g.capOn) return;
    g.capY++;
    if (overlap(g.capX, g.capY, CAP_W, CAP_H, g.px, PLAYER_Y, PLAYER_W, PLAYER_H)) {
        g.capOn = 0;
        g.doubleShot = DOUBLE_SHOT_FRAMES;
        addFx(FX_SPARK, g.px + 3, PLAYER_Y - 4, 6, 0);
    } else if (g.capY + CAP_H > GROUND_Y) {
        g.capOn = 0;
    }
}

static void updateFx(void)
{
    uint8_t i;
    for (i = 0; i < MAX_FX; i++)
        if (g.fx[i].kind != FX_NONE && --g.fx[i].ttl == 0)
            g.fx[i].kind = FX_NONE;
}

/* particles: move, a little gravity, fade out */
static void updateParts(void)
{
    uint8_t i;
    for (i = 0; i < MAX_PARTS; i++) {
        Part *p = &g.part[i];
        if (!p->ttl) continue;
        p->x += p->vx;
        p->y += p->vy;
        if (p->vy < 40) p->vy += 1;
        p->ttl--;
        if (p->x < 0 || p->x >= SCR_W * 16 || p->y < 0 || p->y >= GROUND_Y * 16) p->ttl = 0;
    }
}

/* starfield: three layers scrolling down at different speeds */
static void initStars(void)
{
    uint8_t i;
    for (i = 0; i < STARS; i++) {
        g.star[i].x = (uint8_t)(rnd() & 127);
        g.star[i].y = (uint16_t)((rnd() & 127) << 8);
    }
}

static void updateStars(void)                   /* layer = index / (STARS / 3) */
{
    uint8_t i, layer;
    Star *st = g.star;
    for (layer = 0; layer < 3; layer++)
        for (i = 0; i < STARS / 3; i++, st++) {
            st->y += kStarSpeed[layer];
            if (st->y >= (128u << 8)) {
                st->y -= (128u << 8);
                st->x = (uint8_t)(rnd() & 127);
            }
        }
}

/* ------------------------------------------------------------- rendering */
static void drawStars(void)
{
    uint8_t i, layer;
    const Star *st = g.star;
    for (layer = 0; layer < 3; layer++)
        for (i = 0; i < STARS / 3; i++, st++)
            FbPixel(st->x, st->y >> 8, kStarColor[layer]);
}

static void drawParts(void)
{
    static const uint8_t kFire[4] = { C_PLUM, C_RED, C_ORANGE, C_YELLOW };
    static const uint8_t kIce[4]  = { C_NAVY, C_LAVENDER, C_SKY, C_WHITE };
    uint8_t i;
    for (i = 0; i < MAX_PARTS; i++) {
        Part *p = &g.part[i];
        uint8_t age;
        if (!p->ttl) continue;
        age = p->ttl > 12 ? 3 : p->ttl > 7 ? 2 : p->ttl > 3 ? 1 : 0;
        FbPixel(p->x >> 4, p->y >> 4, p->hue == HUE_ICE ? kIce[age] : kFire[age]);
    }
}

/* bunker b as a 16x8 sprite: light green top, darker below */
static void drawBunker(uint8_t b)
{
    uint8_t r, i, *d = s_bunkerSpr + 2;
    s_bunkerSpr[0] = BUNKER_W;
    s_bunkerSpr[1] = BUNKER_H;
    for (r = 0; r < BUNKER_H; r++) {
        uint16_t m = g.bunker[b][r];
        uint8_t col = r < 3 ? C_GREEN : C_DKGREEN;
        for (i = 0; i < BUNKER_W / 2; i++, m <<= 2)
            *d++ = (uint8_t)(((m & 0x8000u) ? col << 4 : 0) | ((m & 0x4000u) ? col : 0));
    }
    FbBlit(s_bunkerSpr, kBunkerX[b], BUNKER_Y);
}

static void renderHud(void)
{
    char buf[12], *p;
    uint16_t hi = (g.score > s_hiScore) ? g.score : s_hiScore;
    p = putS(buf, "SC "); putU(p, g.score, 5);
    text(buf, 1, 1, C_YELLOW);
    p = putS(buf, "HI "); putU(p, hi, 5);
    text(buf, SCR_W - 1 - 48, 1, C_PEACH);
    FbFillRect(0, HUD_H - 1, TFT4_WH(SCR_W, 1), C_NAVY);
}

static void renderField(void)
{
    uint8_t i, r;
    int16_t x, y;
    char buf[8];

    FbClear(C_BLACK);
    drawStars();
    renderHud();

    if (g.ufoOn) FbBlit(SprUfo, g.ufoX, UFO_Y);

    for (r = 0, y = g.formY; r < FORM_ROWS; r++, y += ROW_DY) {
        const uint8_t *spr = kInvader[r][g.anim];
        uint8_t bits = g.alive[r];
        for (x = g.formX; bits; x += COL_DX, bits >>= 1)
            if (bits & 1)
                FbBlit(spr, x, y);
    }

    for (i = 0; i < BUNKERS; i++)
        drawBunker(i);

    if (g.state == ST_DYING) {
        if (g.stateTimer > FPS / 2)
            FbBlit(((g.stateTimer >> 2) & 1) ? SprPBoomA : SprPBoomB, g.px, PLAYER_Y);
    } else if (g.state != ST_OVER) {
        FbBlit(SprPlayer, g.px, PLAYER_Y);
    }

    for (i = 0; i < MAX_PSHOTS; i++)
        if (g.pshot[i].on) FbBlit(SprPShot, g.pshot[i].x, g.pshot[i].y);
    for (i = 0; i < MAX_ESHOTS; i++)
        if (g.eshot[i].on)
            FbBlit(((g.frame >> 1) & 1) ? SprEShotA : SprEShotB, g.eshot[i].x, g.eshot[i].y);

    if (g.capOn && ((g.frame >> 2) & 1) == 0) FbBlit(SprCapsule, g.capX, g.capY);

    for (i = 0; i < MAX_FX; i++) {
        Fx *f = &g.fx[i];
        if (f->kind == FX_BOOM)  FbBlit(SprBoom, f->x, f->y);
        if (f->kind == FX_SPARK) FbBlit(SprSpark, f->x, f->y);
        if (f->kind == FX_SCORE) {
            putU(buf, f->val, f->val >= 100 ? 3 : 2);
            text(buf, f->x, f->y, (g.frame & 2) ? C_YELLOW : C_WHITE);
        }
    }
    drawParts();

    /* bottom strip: ground, lives, double-shot meter, wave */
    FbFillRect(0, GROUND_Y, TFT4_WH(SCR_W, 1), C_GREEN);
    for (i = 0, x = 2; i < g.lives && i < MAX_LIVES; i++, x += 7)
        FbBlit(SprMiniShip, x, GROUND_Y + 4);
    if (g.doubleShot) {
        int16_t w = (int16_t)((uint32_t)g.doubleShot * 40u / DOUBLE_SHOT_FRAMES);
        FbFillRect(44, GROUND_Y + 4, TFT4_WH(42, 4), C_DKGREY);    /* frame */
        FbFillRect(45, GROUND_Y + 5, TFT4_WH(40, 2), C_BLACK);     /* hollow */
        FbFillRect(45, GROUND_Y + 5, TFT4_WH(w, 2), w > 10 ? C_YELLOW : C_RED);
    }
    buf[0] = 'W'; putU(buf + 1, g.wave, 2);
    text(buf, SCR_W - 19, GROUND_Y + 1, C_LTGREY);
}

static void renderBanner(int16_t y, int16_t h)
{
    FbFillRect(12, y, TFT4_WH(SCR_W - 24, h), C_SKY);
    FbFillRect(14, y + 2, TFT4_WH(SCR_W - 28, h - 4), C_NAVY);
}

static void renderTitle(void)
{
    static const char * const kPts[4] = { "= 30", "= 20", "= 10", "= ???" };
    static const uint8_t kHot[7]  = { C_YELLOW, C_YELLOW, C_ORANGE, C_ORANGE, C_RED, C_RED, C_PINK };
    static const uint8_t kCool[7] = { C_WHITE, C_SKY, C_SKY, C_LAVENDER, C_LAVENDER, C_PINK, C_PINK };
    const uint8_t *spr[4];
    char buf[12], *p;
    uint8_t i, a = (uint8_t)((g.stateTimer >> 3) & 1);

    spr[0] = a ? SprSquidB : SprSquidA;
    spr[1] = a ? SprCrabB  : SprCrabA;
    spr[2] = a ? SprOctoB  : SprOctoA;
    spr[3] = SprUfo;

    FbClear(C_BLACK);
    drawStars();
    bigText("TFT4", SCR_W / 2, 4, 2, kCool);
    bigText("INVADERS", SCR_W / 2, 22, 2, kHot);

    for (i = 0; i < 4; i++) {
        int16_t y = 44 + i * 11;
        FbBlit(spr[i], i == 3 ? 30 : 34, y);
        text(kPts[i], 54, y - 1, C_WHITE);
    }
    p = putS(buf, "HI "); putU(p, s_hiScore, 5);
    textC(buf, SCR_W / 2, 94, C_PEACH);
    if (a) textC("PRESS S1 OR S2", SCR_W / 2, 108, C_GREEN);
    textC("HOLD BOTH: PAUSE", SCR_W / 2, 120, C_DKGREY);
}

static void renderOverlay(void)
{
    char buf[16], *p;

    if (g.state == ST_WAVE) {
        renderBanner(52, 22);
        p = putS(buf, "WAVE "); putU(p, (uint16_t)(g.wave + 1), 2);
        textC(buf, SCR_W / 2, 63, C_WHITE);
    } else if (g.state == ST_PAUSE) {
        renderBanner(52, 22);
        textC("PAUSED", SCR_W / 2, 63, C_WHITE);
    } else if (g.state == ST_OVER) {
        renderBanner(38, 56);
        textC("GAME OVER", SCR_W / 2, 48, C_RED);
        p = putS(buf, "SCORE "); putU(p, g.score, 5);
        textC(buf, SCR_W / 2, 60, C_YELLOW);
        if (g.newHi) {
            if ((g.stateTimer >> 3) & 1) textC("NEW HI-SCORE!", SCR_W / 2, 72, C_PINK);
        } else {
            p = putS(buf, "HI "); putU(p, s_hiScore, 5);
            textC(buf, SCR_W / 2, 72, C_PEACH);
        }
        if (g.stateTimer > 3 * FPS / 2 && ((g.stateTimer >> 3) & 1))
            textC("PRESS BUTTON", SCR_W / 2, 84, C_WHITE);
    }
}

/* ------------------------------------------------------------ public API */
static void startGame(void)
{
    g.score = 0;
    g.lives = START_LIVES;
    g.wave  = 1;
    g.extraGiven = 0;
    g.px = (SCR_W - PLAYER_W) / 2;
    g.pCool = FPS / 2;
    g.doubleShot = 0;
    g.bothHeld = 0;
    memset(g.fx, 0, sizeof(g.fx));
    memset(g.part, 0, sizeof(g.part));
    resetWave();
    g.state = ST_PLAY;
}

void game_init(void)
{
    memset(&g, 0, sizeof(g));
    g.rng = 0xACE1u;
    g.state = ST_TITLE;
    initStars();
}

uint8_t game_frame(uint8_t btn)
{
    uint8_t pressed = (uint8_t)(btn & ~g.prevButtons);
    g.prevButtons = btn;
    g.frame++;
    updateStars();

    switch (g.state) {
    case ST_TITLE:
        g.stateTimer++;
        g.rng ^= g.frame;                        /* seed from human timing */
        if (g.rng == 0) g.rng = 0xACE1u;
        if (pressed && g.stateTimer > FPS / 2) { startGame(); renderField(); break; }
        renderTitle();
        break;

    case ST_PLAY:
        if (btn == (BTN_LEFT | BTN_RIGHT)) {
            if (++g.bothHeld >= FPS) { g.state = ST_PAUSE; g.pauseArmed = 0; }
        } else {
            g.bothHeld = 0;
        }
        movePlayer(btn);
        playerFire();
        if (g.doubleShot) g.doubleShot--;
        updatePShots();
        if (g.state == ST_PLAY) updateFormation();
        if (g.state == ST_PLAY) enemyFire();
        updateEShots();
        updateUfo();
        updateCapsule();
        updateFx();
        updateParts();
        renderField();
        renderOverlay();
        break;

    case ST_DYING:
        updatePShots();
        updateFx();
        updateParts();
        if (--g.stateTimer == 0) {
            if (g.lives == 0) {
                gameOver();
            } else {
                g.state = ST_PLAY;
                g.px = (SCR_W - PLAYER_W) / 2;
                g.pCool = FPS / 2;
                g.eCool = FPS;
            }
        }
        renderField();
        renderOverlay();
        break;

    case ST_WAVE:
        movePlayer(btn);
        updatePShots();
        updateFx();
        updateParts();
        if (--g.stateTimer == 0) {
            if (g.wave < 99) g.wave++;
            resetWave();
            g.state = ST_PLAY;
        }
        renderField();
        renderOverlay();
        break;

    case ST_PAUSE:
        if (btn == 0) g.pauseArmed = 1;
        else if (g.pauseArmed && pressed) { g.state = ST_PLAY; g.bothHeld = 0; }
        renderField();
        renderOverlay();
        break;

    case ST_OVER:
    default:
        if (g.stateTimer < 0xFFFF) g.stateTimer++;
        updateFx();
        updateParts();
        if (pressed && g.stateTimer > 3 * FPS / 2) {
            g.state = ST_TITLE;
            g.stateTimer = 0;
            renderTitle();
            break;
        }
        renderField();
        renderOverlay();
        break;
    }

    /* player hit: the background flashes red for one frame. Changing palette
     * entry 0 recolors every black pixel at once; the whole screen has to be
     * sent for that (LcdPresentFull), then once more with black restored. */
    if (g.flash) {
        PaletteSet(C_BLACK, g.flash == 2 ? TFT4_RGB565(0x5A0818) : 0x0000);
        g.flash--;
        return GAME_PRESENT_FULL;
    }
    return 0;
}

#ifdef GAME_SIM
void game_debug(GameDebug *d)
{
    uint8_t i;
    d->state = g.state; d->px = g.px; d->score = g.score;
    d->lives = g.lives; d->wave = g.wave; d->aliveCount = g.aliveCount;
    d->formX = g.formX; d->formY = g.formY;
    for (i = 0; i < 4; i++) d->alive[i] = g.alive[i];
    for (i = 0; i < 6; i++) { d->eshot[i].x = g.eshot[i].x; d->eshot[i].y = g.eshot[i].y; d->eshot[i].on = g.eshot[i].on; }
}
#endif
