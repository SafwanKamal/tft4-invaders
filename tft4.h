/*******************************************************************************
 * tft4.h - C interface to the tft4 driver (tft4.asm + tft4_config.inc + font6x8.asm)
 * 16-color, 4 bits per pixel, delta-rendering driver for the ST7735 128x128
 * TFT on the Educational BoosterPack MKII with the MSP-EXP430FR6989.
 *
 * The routines follow TI's MSP430 C calling convention (arguments in
 * R12-R15, result in R12, R4-R10 preserved), so C calls them directly.
 *
 * Project settings for C (TI compiler):
 *   --code_model=small --data_model=small
 *   The driver returns with RET, which only matches the small code model's
 *   CALL. With the large code model (CALLA) it would crash.
 *   The three 8 KB frame buffers live in FRAM (.TI.persistent), below 64 KB.
 *   To keep your own variables in FRAM, use
 *     #pragma DATA_SECTION(myVar, ".TI.persistent")
 *   and not #pragma PERSISTENT: PERSISTENT makes a NOINIT section, which the
 *   linker refuses to mix with the driver's part of .TI.persistent (#10367).
 *
 * Coordinates are signed and everything is clipped to the 128x128 screen.
 * Colors are palette indices 0..15 (see DefaultPalette in tft4.asm).
 ******************************************************************************/
#ifndef TFT4_H_
#define TFT4_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TFT4_WIDTH          128
#define TFT4_HEIGHT         128

/* w + (h << 8) for FbFillRect / FbRestore */
#define TFT4_WH(w, h)       ((uint16_t)(((w) & 0xFF) | (((h) & 0xFF) << 8)))
/* FbText colors: ink + (background << 8); background 16 or more = none */
#define TFT4_TEXT(ink, bg)  ((uint16_t)(((ink) & 0x0F) | ((uint16_t)(bg) << 8)))
#define TFT4_CLEAR          0xFF
/* 24-bit RGB -> RGB565 for PaletteSet */
#define TFT4_RGB565(rgb)    ((uint16_t)((((rgb) >> 8) & 0xF800) | (((rgb) >> 5) & 0x07E0) | (((rgb) >> 3) & 0x001F)))

/* A sprite is: width, height, then the rows, 2 pixels per byte, left pixel
 * in the high nibble, each row padded to a whole byte. Index 0 is
 * transparent. tools/sprite2asm.py writes them (--c for C arrays). */
typedef uint8_t Tft4Sprite;

extern uint16_t Palette[16];            /* current palette, RGB565 (read only) */
extern const uint16_t DefaultPalette[16];   /* the palette LcdInit loads */
extern const uint8_t Font6x8[95 * 8];   /* characters 32..126, one byte per row */
extern const uint16_t Tft4ClockMHz;     /* CLOCK_MHZ from tft4_config.inc */

void     ClockInit(void);               /* MCLK = SMCLK = CLOCK_MHZ (16 MHz) */
void     LcdInit(void);                 /* SPI, panel, palette, black screen */

uint16_t LcdPresent(void);              /* send what changed -> windows opened */
uint16_t LcdPresentFull(void);          /* send everything (after PaletteSet) */
void     LcdWait(void);                 /* wait until the last byte is out */

void     FbClear(uint16_t color);
void     FbFillRect(int16_t x, int16_t y, uint16_t wh, uint16_t color);
void     FbPixel(int16_t x, int16_t y, uint16_t color);
int16_t  FbText(const char *s, int16_t x, int16_t y, uint16_t colors);  /* -> x after */
void     FbBlit(const Tft4Sprite *sprite, int16_t x, int16_t y);
void     FbSaveBg(void);                /* Back -> Bg (after drawing the scenery) */
void     FbRestore(int16_t x, int16_t y, uint16_t wh);   /* Bg -> Back */
void     FbRestoreSpr(const Tft4Sprite *sprite, int16_t x, int16_t y);  /* erase a sprite */
void     FbSync(void);                  /* Front -> Back */
void     PaletteSet(uint16_t index, uint16_t rgb565);
void     PaletteLoad(const uint16_t *rgb565x16);   /* all 16 at once */

#ifdef __cplusplus
}
#endif

#endif /* TFT4_H_ */
