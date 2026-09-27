;******************************************************************************
; Safwan Kamal
; SEPTEMBER 2026
; tft4 - 16-color (4 bpp) delta-rendering driver for the ST7735 128x128 TFT
;        on the Educational BoosterPack MKII (MSP-EXP430FR6989 LaunchPad)
;******************************************************************************
;
; How it works
;   Three 4 bpp frame buffers (8 KB each) live in FRAM:
;     Back   the picture the game draws into; it keeps its contents between
;            frames, so only what moves has to be drawn again
;     Front  exactly what is on the glass
;     Bg     a saved background (FbSaveBg) that FbRestore copies back from
;   Every drawing call records which part of each row it touched (DirtyLo /
;   DirtyHi). LcdPresent only compares those parts of Back with Front, sends
;   the runs that really changed and copies them into Front. So the cost of a
;   frame follows what changed, like drawing straight to the panel, but with
;   transparency, overlapping sprites and no erase-then-draw flicker.
;   Pixels are palette indices (0-15); Palette (in RAM) maps them to RGB565.
;   Sending: each Back byte (2 pixels) is expanded through PairTab (4 bytes of
;   panel data per Back byte) into a RAM line buffer, and DMA channel 0 feeds
;   that buffer to the SPI while the CPU fills the next one.
;
; Wiring (same pins as Pong_Assembly)
;   P1.4 UCB0CLK -> LCD SCK   (BP pin 7)
;   P1.6 UCB0SIMO-> LCD SDA   (BP pin 15)
;   P2.5         -> LCD CS    (BP pin 13)   held low: only device on the bus
;   P2.3         -> LCD D/C   (BP pin 31)   low = command, high = data
;   P9.4         -> LCD RESET (BP pin 17)
;
; Requirements
;   MCLK = SMCLK = CLOCK_MHZ (call ClockInit, or set the clocks yourself),
;   GPIO unlocked (LOCKLPM5 cleared) before LcdInit.
;
;------------------------------------------------------------------------------
; Calling convention (TI C ABI, so C code can call these too)
;------------------------------------------------------------------------------
; Arguments in R12, R13, R14, R15. Return value in R12.
; R11-R15 may be changed by any routine. R4-R10 are always preserved, so the
; game can keep its state in R4-R10 like Pong does.
;
;   ClockInit                               MCLK = SMCLK = CLOCK_MHZ from the
;                                           DCO (+ FRAM wait state at 16 MHz)
;   LcdInit                                 set up SPI + panel, clear to black
;   LcdPresent          -> R12 = windows    send what changed in touched rows
;   LcdPresentFull                          send the whole Back buffer
;   LcdWait                                 wait until the last byte is out
;                                           (presents return while DMA is
;                                           still sending the final chunk)
;   FbClear      R12 = color                fill Back
;   FbFillRect   R12 = x, R13 = y,          filled rectangle, clipped
;                R14 = w + (h << 8), R15 = color
;   FbPixel      R12 = x, R13 = y,          one pixel, clipped (much cheaper
;                R14 = color                than a 1x1 FbFillRect)
;   FbText       R12 = string, R13 = x,     6x8 text (grlib's fixed font),
;                R14 = y, R15 = color +     string ends with a 0 byte;
;                (background << 8)          background 16+ = transparent;
;                            -> R12 = x after the text
;   FbBlit       R12 = sprite, R13 = x, R14 = y
;                                           draw a 4 bpp sprite, index 0 is
;                                           transparent, clipped, any x/y
;   FbSaveBg                                copy Back -> Bg (after drawing the
;                                           static background)
;   FbRestore    R12 = x, R13 = y,          copy that rectangle from Bg into
;                R14 = w + (h << 8)         Back (erase a sprite), clipped
;   FbRestoreSpr R12 = sprite, R13 = x,     FbRestore of the sprite's size:
;                R14 = y                    erase a sprite drawn at x, y
;   FbSync                                  copy Front -> Back (throw away
;                                           drawing that was not presented)
;   PaletteLoad  R12 = 16 RGB565 words      replace the whole palette
;   PaletteSet   R12 = index, R13 = RGB565  change one palette entry (~0.35 ms,
;                                           rebuilds PairTab; call
;                                           LcdPresentFull to repaint)
;
; Two ways to draw a frame:
;   Retained (fast): FbRestore each sprite's old rectangle, FbBlit the sprites
;                    at their new places, LcdPresent.
;   Full redraw:     FbClear, draw everything, LcdPresent. Simple, but every
;                    row is touched, so every row is compared (~4 ms).
;
; Resources: eUSCI_B0 (SPI) and DMA channel 0 (trigger UCB0TXIFG0).
; Needs font6x8.asm (the FbText font) in the project.
;
; Sprite format (tools/sprite2asm.py writes these):
;   .byte  width, height
;   .byte  rows, 2 pixels per byte, left pixel in the high nibble,
;          each row padded to a whole byte
;------------------------------------------------------------------------------

	.cdecls C,LIST,"msp430.h"       ; Include device header file

	.def    ClockInit, LcdInit, LcdPresent, LcdPresentFull, LcdWait
	.def    FbClear, FbFillRect, FbPixel, FbText, FbBlit, FbSync, FbSaveBg, FbRestore
	.def    FbRestoreSpr, PaletteSet, PaletteLoad, DefaultPalette
	.def    Palette, FbBack, FbFront, Tft4ClockMHz
	.ref    Font6x8

;------------------------------------------------------------------------------
;           Settings
;------------------------------------------------------------------------------
LCD_W           .set    128
LCD_H           .set    128
FB_BPL          .set    64              ; bytes per frame buffer row (2 px/byte)
FB_SIZE         .set    8192
	.include "tft4_config.inc"      ; CLOCK_MHZ, SPI_DIV, orientation, tuning
LOOPS_PER_MS    .set    CLOCK_MHZ*1000/3    ; 3 cycles per delay loop

; ST7735 commands
CM_SLPOUT       .set    0x11
CM_NORON        .set    0x13
CM_DISPON       .set    0x29
CM_CASET        .set    0x2A
CM_RASET        .set    0x2B
CM_RAMWR        .set    0x2C

;------------------------------------------------------------------------------
;           Macros
;------------------------------------------------------------------------------
CS_LOW	.macro
	bic.b   #BIT5, &P2OUT
	.endm

DC_CMD	.macro
	bic.b   #BIT3, &P2OUT
	.endm

DC_DATA	.macro
	bis.b   #BIT3, &P2OUT
	.endm

RST_HIGH	.macro
	bis.b   #BIT4, &P9OUT
	.endm

RST_LOW	.macro
	bic.b   #BIT4, &P9OUT
	.endm

; Send one data byte (low byte of src). Waits only for room in TXBUF, so bytes
; go out back to back while the previous one is still shifting.
SPI_TX	.macro  src
spiTx?	bit.w   #UCTXIFG, &UCB0IFG
	jz      spiTx?
	mov.b   src, &UCB0TXBUF
	.endm

; Plot palette index R11 (0 = transparent, skipped) at x = R9 in the Back row
; that starts at R7. Uses R13. Anything outside 0..127 is clipped.
PLOT_NIB	.macro
	tst.w   R11
	jz      pnSkip?
	cmp.w   #LCD_W, R9
	jhs     pnSkip?                 ; unsigned: also catches x < 0
	mov.w   R9, R13
	rra.w   R13
	add.w   R7, R13                 ; R13 = byte holding this pixel
	bit.w   #1, R9
	jnz     pnOdd?
	rla.w   R11                     ; even x: high nibble
	rla.w   R11
	rla.w   R11
	rla.w   R11
	and.b   #0x0F, 0(R13)
	bis.b   R11, 0(R13)
	jmp     pnSkip?
pnOdd?	and.b   #0xF0, 0(R13)           ; odd x: low nibble
	bis.b   R11, 0(R13)
pnSkip?
	.endm

;------------------------------------------------------------------------------
;           Constants
;------------------------------------------------------------------------------
	.sect   ".const"

; Panel init: command, count (+0x80 = wait 120 ms afterwards), parameters.
; 0xFF ends the list. Power/gamma values are the ones Pong_Assembly uses.
InitSeq	.byte   CM_SLPOUT, 0x80
	.byte   0xB1, 3, 0x02, 0x35, 0x36
	.byte   0xB2, 3, 0x02, 0x35, 0x36
	.byte   0xB3, 6, 0x02, 0x35, 0x36, 0x02, 0x35, 0x36
	.byte   0xB4, 1, 0x07
	.byte   0xC0, 2, 0x02, 0x02
	.byte   0xC1, 1, 0xC5
	.byte   0xC2, 2, 0x0D, 0x00
	.byte   0xC3, 2, 0x8D, 0x1A
	.byte   0xC4, 2, 0x8D, 0xEE
	.byte   0xC5, 2, 0x51, 0x4D
	.byte   0xE0, 16, 0x0A, 0x1C, 0x0C, 0x14, 0x33, 0x2B, 0x24, 0x28
	.byte             0x27, 0x25, 0x2C, 0x39, 0x00, 0x05, 0x03, 0x0D
	.byte   0xE1, 16, 0x0A, 0x1C, 0x0C, 0x14, 0x33, 0x2B, 0x24, 0x28
	.byte             0x27, 0x25, 0x2C, 0x39, 0x00, 0x05, 0x03, 0x0D
	.byte   0x3A, 1, 0x05                   ; COLMOD: 16 bit/pixel
	.byte   0x36, 1, LCD_MADCTL             ; MADCTL: orientation + BGR
	.byte   CM_NORON, 0
	.byte   CM_DISPON, 0x80
	.byte   0xFF
	.align  2

; MaskTab[b]: which nibbles of sprite byte b are drawn (index 0 = transparent)
MaskTab
	.byte   0x00, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F
	.byte   0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
	.byte   0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
	.byte   0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
	.byte   0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
	.byte   0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
	.byte   0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
	.byte   0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
	.byte   0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
	.byte   0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
	.byte   0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
	.byte   0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
	.byte   0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
	.byte   0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
	.byte   0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
	.byte   0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF

; SwapTab[b]: b with its two nibbles swapped (sprites at odd x)
SwapTab
	.byte   0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0
	.byte   0x01, 0x11, 0x21, 0x31, 0x41, 0x51, 0x61, 0x71, 0x81, 0x91, 0xA1, 0xB1, 0xC1, 0xD1, 0xE1, 0xF1
	.byte   0x02, 0x12, 0x22, 0x32, 0x42, 0x52, 0x62, 0x72, 0x82, 0x92, 0xA2, 0xB2, 0xC2, 0xD2, 0xE2, 0xF2
	.byte   0x03, 0x13, 0x23, 0x33, 0x43, 0x53, 0x63, 0x73, 0x83, 0x93, 0xA3, 0xB3, 0xC3, 0xD3, 0xE3, 0xF3
	.byte   0x04, 0x14, 0x24, 0x34, 0x44, 0x54, 0x64, 0x74, 0x84, 0x94, 0xA4, 0xB4, 0xC4, 0xD4, 0xE4, 0xF4
	.byte   0x05, 0x15, 0x25, 0x35, 0x45, 0x55, 0x65, 0x75, 0x85, 0x95, 0xA5, 0xB5, 0xC5, 0xD5, 0xE5, 0xF5
	.byte   0x06, 0x16, 0x26, 0x36, 0x46, 0x56, 0x66, 0x76, 0x86, 0x96, 0xA6, 0xB6, 0xC6, 0xD6, 0xE6, 0xF6
	.byte   0x07, 0x17, 0x27, 0x37, 0x47, 0x57, 0x67, 0x77, 0x87, 0x97, 0xA7, 0xB7, 0xC7, 0xD7, 0xE7, 0xF7
	.byte   0x08, 0x18, 0x28, 0x38, 0x48, 0x58, 0x68, 0x78, 0x88, 0x98, 0xA8, 0xB8, 0xC8, 0xD8, 0xE8, 0xF8
	.byte   0x09, 0x19, 0x29, 0x39, 0x49, 0x59, 0x69, 0x79, 0x89, 0x99, 0xA9, 0xB9, 0xC9, 0xD9, 0xE9, 0xF9
	.byte   0x0A, 0x1A, 0x2A, 0x3A, 0x4A, 0x5A, 0x6A, 0x7A, 0x8A, 0x9A, 0xAA, 0xBA, 0xCA, 0xDA, 0xEA, 0xFA
	.byte   0x0B, 0x1B, 0x2B, 0x3B, 0x4B, 0x5B, 0x6B, 0x7B, 0x8B, 0x9B, 0xAB, 0xBB, 0xCB, 0xDB, 0xEB, 0xFB
	.byte   0x0C, 0x1C, 0x2C, 0x3C, 0x4C, 0x5C, 0x6C, 0x7C, 0x8C, 0x9C, 0xAC, 0xBC, 0xCC, 0xDC, 0xEC, 0xFC
	.byte   0x0D, 0x1D, 0x2D, 0x3D, 0x4D, 0x5D, 0x6D, 0x7D, 0x8D, 0x9D, 0xAD, 0xBD, 0xCD, 0xDD, 0xED, 0xFD
	.byte   0x0E, 0x1E, 0x2E, 0x3E, 0x4E, 0x5E, 0x6E, 0x7E, 0x8E, 0x9E, 0xAE, 0xBE, 0xCE, 0xDE, 0xEE, 0xFE
	.byte   0x0F, 0x1F, 0x2F, 0x3F, 0x4F, 0x5F, 0x6F, 0x7F, 0x8F, 0x9F, 0xAF, 0xBF, 0xCF, 0xDF, 0xEF, 0xFF

; CLOCK_MHZ for programs that set up their own timers at run time (C)
Tft4ClockMHz	.word   CLOCK_MHZ

; Default 16-color palette, RGB565
DefaultPalette
	.word	0x0000			;  0 Black     #000000
	.word	0x194A			;  1 Navy      #1D2B53
	.word	0x792A			;  2 Plum      #7E2553
	.word	0x042A			;  3 DkGreen   #008751
	.word	0xAA86			;  4 Brown     #AB5236
	.word	0x5AA9			;  5 DkGrey    #5F574F
	.word	0xC618			;  6 LtGrey    #C2C3C7
	.word	0xFF9D			;  7 White     #FFF1E8
	.word	0xF809			;  8 Red       #FF004D
	.word	0xFD00			;  9 Orange    #FFA300
	.word	0xFF64			; 10 Yellow    #FFEC27
	.word	0x0726			; 11 Green     #00E436
	.word	0x2D7F			; 12 Sky       #29ADFF
	.word	0x83B3			; 13 Lavender  #83769C
	.word	0xFBB5			; 14 Pink      #FF77A8
	.word	0xFE75			; 15 Peach     #FFCCAA

;------------------------------------------------------------------------------
;           Variables
;------------------------------------------------------------------------------
	.bss    Palette, 32, 2             ; RAM copy: fast lookup, changeable
	.bss    WinXs, 2, 2                ; open panel window: first byte offset
	.bss    WinXe, 2, 2                ;                    last byte offset
	.bss    WinNextY, 2, 2             ; row the open window continues at
	.bss    WinCount, 2, 2             ; windows opened this present
	.bss    BlitX, 2, 2
	.bss    BlitRowBytes, 2, 2
	.bss    LineNext, 2, 2          ; line buffer the CPU fills next
	.bss    LineBufA, CHUNK*4, 2    ; two DMA line buffers (panel bytes)
	.bss    LineBufB, CHUNK*4, 2
	.bss    DirtyLo, LCD_H, 2       ; per row: first touched byte (0xFF = clean)
	.bss    DirtyHi, LCD_H, 2       ;          last touched byte
	.bss    AnyDirty, 2, 2          ; nonzero: some row was touched
	.bss    TextVal, 16, 2          ; FbText: pixel values and masks per
	.bss    TextMsk, 16, 2          ;         2-pixel pattern (see FbText)

; Frame buffers: 3 x 8 KB, too big for RAM, so they go in FRAM. They are
; back to back: Front = Back + FB_SIZE, Bg = Back + 2 * FB_SIZE.
	.sect   ".TI.persistent"
	.align  2
FbBack	.space  FB_SIZE
FbFront	.space  FB_SIZE
FbBg	.space  FB_SIZE
; PairTab: for every Back byte value (2 pixels) the 4 panel bytes to send,
; stored so a word write puts the RGB565 high byte first. Built from Palette.
PairTab	.space  1024

;------------------------------------------------------------------------------
;           Public routines
;------------------------------------------------------------------------------
	.text

;------------------------------------------------------------------------------
; ClockInit - MCLK = SMCLK = DCO at CLOCK_MHZ, ACLK unchanged. Above 8 MHz the
; FRAM needs a wait state (its cache hides most of it). The dividers are set
; to /4 while the DCO changes, as TI's examples do.
;------------------------------------------------------------------------------
ClockInit:
	.if CLOCK_MHZ > 8
	mov.w   #FRCTLPW+NWAITS_1, &FRCTL0
	.endif
	mov.b   #CSKEY_H, &CSCTL0_H     ; unlock CS registers
	mov.w   #DIVA__4+DIVS__4+DIVM__4, &CSCTL3
	.if CLOCK_MHZ > 8
	mov.w   #DCORSEL+DCOFSEL_4, &CSCTL1 ; 16 MHz
	.else
	mov.w   #DCOFSEL_6, &CSCTL1     ; 8 MHz
	.endif
	mov.w   #SELS__DCOCLK+SELM__DCOCLK, &CSCTL2
	mov.w   #20, R15                ; let the DCO settle (~60 cycles)
ckWait	dec.w   R15
	jnz     ckWait
	mov.w   #DIVA__1+DIVS__1+DIVM__1, &CSCTL3
	clr.b   &CSCTL0_H               ; lock CS registers
	ret

;------------------------------------------------------------------------------
; LcdInit - pins, SPI, panel reset + init, palette, both buffers black
;------------------------------------------------------------------------------
LcdInit:
	; Pins: P1.4/P1.6 to eUSCI_B0, D/C + CS + RESET as outputs
	bis.b   #BIT4+BIT6, &P1SEL0
	bic.b   #BIT4+BIT6, &P1SEL1
	bis.b   #BIT3+BIT5, &P2OUT      ; D/C = data, CS high for now
	bis.b   #BIT3+BIT5, &P2DIR
	bic.b   #BIT3+BIT5, &P2SEL0
	bic.b   #BIT3+BIT5, &P2SEL1
	RST_HIGH
	bis.b   #BIT4, &P9DIR
	bic.b   #BIT4, &P9SEL0
	bic.b   #BIT4, &P9SEL1

	; eUSCI_B0: 3-wire SPI master, SPI mode 0, MSB first, SMCLK
	mov.w   #UCSWRST, &UCB0CTLW0
	bis.w   #UCSSEL__SMCLK+UCSYNC+UCMST+UCMSB+UCCKPH, &UCB0CTLW0
	mov.w   #SPI_DIV, &UCB0BRW
	bic.w   #UCSWRST, &UCB0CTLW0
	CS_LOW

	; Hardware reset
	RST_LOW
	mov.w   #10, R15
	call    #DelayMs_sr
	RST_HIGH
	mov.w   #120, R15
	call    #DelayMs_sr

	mov.w   #InitSeq, R12
	call    #LcdRunSeq_sr

	mov.w   #DefaultPalette, R12    ; palette: the default, into RAM
	call    #PaletteLoad

	; DMA channel 0: triggered by UCB0TXIFG0, writes bytes into UCB0TXBUF
	bic.w   #0x001F, &DMACTL0
	bis.w   #DMA0TSEL__UCB0TXIFG0, &DMACTL0
	bis.w   #DMARMWDIS, &DMACTL4    ; no DMA inside read-modify-write instructions
	clr.w   &DMA0CTL
	mov.w   #UCB0TXBUF, &DMA0DA
	mov.w   #LineBufA, &LineNext

	; All buffers black, then paint the glass once
	clr.w   R12
	call    #FbClear
	call    #FbSaveBg
	call    #LcdPresentFull         ; also makes Front = Back, rows clean
	ret

;------------------------------------------------------------------------------
; PaletteLoad - R12 = 16 RGB565 words (for example DefaultPalette)
; Replaces the whole palette at once (one PairTab rebuild, ~0.35 ms at 16 MHz).
;------------------------------------------------------------------------------
PaletteLoad:
	mov.w   #Palette, R13
	mov.w   #16, R14
palCopy	mov.w   @R12+, 0(R13)
	incd.w  R13
	dec.w   R14
	jnz     palCopy
	br      #BuildPairTab_sr        ; (returns from there)

;------------------------------------------------------------------------------
; PaletteSet - R12 = index (0-15), R13 = RGB565
;------------------------------------------------------------------------------
PaletteSet:
	and.w   #0x0F, R12
	rla.w   R12
	mov.w   R13, Palette(R12)
	call    #BuildPairTab_sr
	ret

;------------------------------------------------------------------------------
; LcdWait - wait until DMA and SPI are both idle (every byte is out)
;------------------------------------------------------------------------------
LcdWait:
waitDma	bit.w   #DMAEN, &DMA0CTL
	jnz     waitDma
waitBus	bit.w   #UCBUSY, &UCB0STATW
	jnz     waitBus
	ret

;------------------------------------------------------------------------------
; FbClear - R12 = color index. Fills the whole Back buffer (~2.7 ms).
;------------------------------------------------------------------------------
FbClear:
	and.w   #0x0F, R12
	mov.w   R12, R13
	rla.w   R13
	rla.w   R13
	rla.w   R13
	rla.w   R13
	bis.w   R12, R13                ; R13 = color in both nibbles
	mov.w   R13, R14
	swpb    R14
	bis.w   R13, R14                ; R14 = color in all 4 nibbles
	mov.w   #FbBack, R13
	mov.w   #FB_SIZE/8, R15
clrLoop	mov.w   R14, 0(R13)
	mov.w   R14, 2(R13)
	mov.w   R14, 4(R13)
	mov.w   R14, 6(R13)
	add.w   #8, R13
	dec.w   R15
	jnz     clrLoop
	clr.w   R12                     ; every row touched, all 64 bytes
	mov.w   #FB_BPL-1, R13
	clr.w   R14
	mov.w   #LCD_H, R15
	call    #MarkRect_sr
	ret

;------------------------------------------------------------------------------
; FbSync - copy Front into Back (drop drawing that was not presented)
;------------------------------------------------------------------------------
FbSync:
	mov.w   #FbFront, R12
	mov.w   #FbBack, R13
	jmp     FbCopy_sr

;------------------------------------------------------------------------------
; FbSaveBg - copy Back into Bg. Draw the static scene, call this once, then
; erase sprites with FbRestore.
;------------------------------------------------------------------------------
FbSaveBg:
	mov.w   #FbBack, R12
	mov.w   #FbBg, R13
	jmp     FbCopy_sr

; FbCopy_sr - copy one 8 KB buffer: R12 = from, R13 = to. Uses R12-R14.
FbCopy_sr:
	mov.w   #FB_SIZE/8, R14
copyLoop	mov.w   @R12+, 0(R13)
	mov.w   @R12+, 2(R13)
	mov.w   @R12+, 4(R13)
	mov.w   @R12+, 6(R13)
	add.w   #8, R13
	dec.w   R14
	jnz     copyLoop
	ret

;------------------------------------------------------------------------------
; FbRestoreSpr - R12 = sprite, R13 = x, R14 = y
; Erase a sprite: FbRestore of the rectangle it covers at x, y.
;------------------------------------------------------------------------------
FbRestoreSpr:
	mov.b   1(R12), R15             ; h
	swpb    R15
	mov.b   @R12, R12               ; w
	bis.w   R12, R15                ; w + (h << 8)
	mov.w   R13, R12                ; x
	mov.w   R14, R13                ; y
	mov.w   R15, R14
	jmp     FbRestore

;------------------------------------------------------------------------------
; FbRestore - R12 = x, R13 = y (signed), R14 = w + (h << 8)
; Copies that rectangle from Bg back into Back and marks it touched.
;
; R4 = Back row, R5 = byte pointer, R6 = x end (exclusive), R7 = bytes,
; R11 = words / scratch, R15 = pixels left in the row
;------------------------------------------------------------------------------
FbRestore:
	push.w  R4
	push.w  R5
	push.w  R6
	push.w  R7
	call    #ClipRect_sr            ; -> R12 x0, R13 y0, R6 x end, R14 y end
	jc      restDone                ; nothing on screen
	call    #MarkClipped_sr

	mov.w   R13, R4                 ; R4 = Back + y * 64
	rla.w   R4
	rla.w   R4
	rla.w   R4
	rla.w   R4
	rla.w   R4
	rla.w   R4
	add.w   #FbBack, R4
	sub.w   R13, R14                ; rows

restRow	mov.w   R12, R5
	rra.w   R5
	add.w   R4, R5                  ; byte of the first pixel
	mov.w   R6, R15
	sub.w   R12, R15                ; R15 = pixels in this row
	bit.w   #1, R12
	jz      restEven
	mov.b   FB_SIZE*2(R5), R11      ; odd start: low nibble from Bg
	and.w   #0x0F, R11
	and.b   #0xF0, 0(R5)
	bis.b   R11, 0(R5)
	inc.w   R5
	dec.w   R15
restEven	mov.w   R15, R7
	rra.w   R7                      ; R7 = whole bytes
	jz      restTail
	bit.w   #1, R5
	jz      restWords
	mov.b   FB_SIZE*2(R5), 0(R5)    ; odd address: one byte, then words
	inc.w   R5
	dec.w   R7
restWords	mov.w   R7, R11
	rra.w   R11                     ; R11 = words
	rra.w   R11                     ; R11 = word pairs, carry = one more word
	jnc     restPairs
	mov.w   FB_SIZE*2(R5), 0(R5)
	incd.w  R5
restPairs	tst.w   R11
	jz      restByte
restPLoop	mov.w   FB_SIZE*2(R5), 0(R5)    ; 8 pixels per pass
	mov.w   FB_SIZE*2+2(R5), 2(R5)
	add.w   #4, R5
	dec.w   R11
	jnz     restPLoop
restByte	bit.w   #1, R7
	jz      restTail
	mov.b   FB_SIZE*2(R5), 0(R5)
	inc.w   R5
restTail	bit.w   #1, R15
	jz      restNext
	mov.b   FB_SIZE*2(R5), R11      ; one pixel left: high nibble
	and.w   #0xF0, R11
	and.b   #0x0F, 0(R5)
	bis.b   R11, 0(R5)
restNext	add.w   #FB_BPL, R4
	dec.w   R14
	jnz     restRow

restDone	pop.w   R7
	pop.w   R6
	pop.w   R5
	pop.w   R4
	ret

;------------------------------------------------------------------------------
; FbFillRect - R12 = x, R13 = y (signed, may be off screen),
;              R14 = w + (h << 8), R15 = color index
;
; R4 = Back row, R5 = byte pointer, R6 = x end (exclusive), R7 = bytes,
; R8 = color (low nibble), R9 = color (high nibble), R10 = all 4 nibbles,
; R11 = words left, R15 = pixels left in the row
;------------------------------------------------------------------------------
FbFillRect:
	push.w  R4
	push.w  R5
	push.w  R6
	push.w  R7
	push.w  R8
	push.w  R9
	push.w  R10

	and.w   #0x0F, R15
	mov.w   R15, R8
	mov.w   R15, R9
	rla.w   R9
	rla.w   R9
	rla.w   R9
	rla.w   R9
	mov.w   R8, R10
	bis.w   R9, R10
	mov.w   R10, R15
	swpb    R15
	bis.w   R15, R10                ; R10 = color in all 4 nibbles

	call    #ClipRect_sr            ; -> R12 x0, R13 y0, R6 x end, R14 y end
	jc      fillDone                ; nothing on screen
	call    #MarkClipped_sr

	mov.w   R13, R4                 ; R4 = Back + y * 64
	rla.w   R4
	rla.w   R4
	rla.w   R4
	rla.w   R4
	rla.w   R4
	rla.w   R4
	add.w   #FbBack, R4
	sub.w   R13, R14                ; R14 = rows to fill

fillRow	mov.w   R12, R5
	rra.w   R5
	add.w   R4, R5                  ; R5 = byte of the first pixel
	mov.w   R6, R15
	sub.w   R12, R15                ; R15 = pixels in this row
	bit.w   #1, R12
	jz      fillEven
	and.b   #0xF0, 0(R5)            ; odd start: low nibble only
	bis.b   R8, 0(R5)
	inc.w   R5
	dec.w   R15
fillEven	mov.w   R15, R7
	rra.w   R7                      ; R7 = whole bytes (2 pixels each)
	jz      fillTail
	bit.w   #1, R5
	jz      fillWords
	mov.b   R10, 0(R5)              ; odd address: one byte, then words
	inc.w   R5
	dec.w   R7
fillWords	mov.w   R7, R11
	rra.w   R11                     ; R11 = words (4 pixels each)
	rra.w   R11                     ; R11 = word pairs, carry = one more word
	jnc     fillPairs
	mov.w   R10, 0(R5)
	incd.w  R5
fillPairs	tst.w   R11
	jz      fillByte
fillPLoop	mov.w   R10, 0(R5)              ; 8 pixels per pass
	mov.w   R10, 2(R5)
	add.w   #4, R5
	dec.w   R11
	jnz     fillPLoop
fillByte	bit.w   #1, R7
	jz      fillTail
	mov.b   R10, 0(R5)              ; one byte left
	inc.w   R5
fillTail	bit.w   #1, R15
	jz      fillNext
	and.b   #0x0F, 0(R5)            ; one pixel left: high nibble
	bis.b   R9, 0(R5)
fillNext	add.w   #FB_BPL, R4
	dec.w   R14
	jnz     fillRow

fillDone	pop.w   R10
	pop.w   R9
	pop.w   R8
	pop.w   R7
	pop.w   R6
	pop.w   R5
	pop.w   R4
	ret

;------------------------------------------------------------------------------
; FbPixel - R12 = x, R13 = y, R14 = color index. Clipped (unsigned compare,
; so negative x/y are off screen too). Uses R11-R15.
;------------------------------------------------------------------------------
FbPixel:
	cmp.w   #LCD_W, R12
	jhs     pixDone
	cmp.w   #LCD_H, R13
	jhs     pixDone
	and.w   #0x0F, R14
	mov.w   R13, R15                ; R15 = Back + y * 64 + x / 2
	swpb    R15                     ; y * 256
	rra.w   R15
	rra.w   R15                     ; y * 64
	mov.w   R12, R11
	rra.w   R11                     ; R11 = byte in the row
	add.w   R11, R15
	add.w   #FbBack, R15
	bit.w   #1, R12
	jnz     pixOdd
	rla.w   R14                     ; even x: high nibble
	rla.w   R14
	rla.w   R14
	rla.w   R14
	and.b   #0x0F, 0(R15)
	jmp     pixSet
pixOdd	and.b   #0xF0, 0(R15)           ; odd x: low nibble
pixSet	bis.b   R14, 0(R15)
	cmp.b   R11, DirtyLo(R13)       ; mark the byte touched
	jlo     pixHi
	mov.b   R11, DirtyLo(R13)
pixHi	cmp.b   R11, DirtyHi(R13)
	jhs     pixFlag
	mov.b   R11, DirtyHi(R13)
pixFlag	mov.w   #1, &AnyDirty
pixDone	ret

;------------------------------------------------------------------------------
; FbBlit - R12 = sprite, R13 = x, R14 = y (signed, may be off screen)
;
; Sprites fully on screen horizontally go a byte (2 pixels) at a time through
; MaskTab; only sprites cut by the left/right edge go pixel by pixel.
; R4 = width, R5 = rows left, R7 = Back row, R8 = sprite byte pointer,
; R9 = x of the current pixel, R10 = pixels left in the row,
; R11 = palette index, R12 = sprite row, R14 = y, R15 = sprite byte
;------------------------------------------------------------------------------
FbBlit:
	push.w  R4
	push.w  R5
	push.w  R6
	push.w  R7
	push.w  R8
	push.w  R9
	push.w  R10

	mov.w   R13, &BlitX
	mov.b   @R12+, R4               ; width
	mov.b   @R12+, R5               ; height
	mov.w   R4, R15
	inc.w   R15
	rra.w   R15
	mov.w   R15, &BlitRowBytes      ; (width + 1) / 2
	tst.w   R4
	jz      blitDone
	tst.w   R5
	jz      blitDone

	push.w  R12                     ; mark the sprite's rectangle touched
	push.w  R13
	push.w  R14
	push.w  R6
	mov.w   R13, R12                ; x
	mov.w   R14, R13                ; y
	mov.w   R5, R14
	swpb    R14
	bis.w   R4, R14                 ; w + (h << 8)
	call    #ClipRect_sr
	jc      blitNoMark
	call    #MarkClipped_sr
blitNoMark	pop.w   R6
	pop.w   R14
	pop.w   R13
	pop.w   R12

	; Whole sprite row on screen (x >= 0, x + 2 * row bytes <= 128)? Then
	; draw a byte (2 pixels) at a time. Otherwise the pixel-by-pixel path.
	cmp.w   #0, R13
	jl      blitRow
	mov.w   &BlitRowBytes, R15
	rla.w   R15
	add.w   R13, R15
	cmp.w   #LCD_W+1, R15
	jge     blitRow
	bit.w   #1, R13
	jnz     blitOdd

; Even x: every sprite byte lands on one Back byte.
; R7 = Back byte, R8 = sprite byte pointer, R10 = bytes left, R11 = mask
blitEven	cmp.w   #LCD_H, R14
	jhs     beNext                  ; unsigned: row above or below the screen
	mov.w   R14, R7                 ; R7 = Back + y * 64 + x / 2
	swpb    R7
	rra.w   R7
	rra.w   R7
	mov.w   &BlitX, R15
	rra.w   R15
	add.w   R15, R7
	add.w   #FbBack, R7
	mov.w   R12, R8
	mov.w   &BlitRowBytes, R10
beByte	mov.b   @R8+, R15               ; two pixels
	tst.w   R15
	jz      beSkip                  ; both transparent
	mov.b   MaskTab(R15), R11
	bic.b   R11, 0(R7)
	bis.b   R15, 0(R7)
beSkip	inc.w   R7
	dec.w   R10
	jnz     beByte
beNext	add.w   &BlitRowBytes, R12
	inc.w   R14
	dec.w   R5
	jnz     blitEven
	jmp     blitDone

; Odd x: sprite byte j gives the low nibble of Back byte k and the high
; nibble of Back byte k+1. The high half is carried to the next byte.
; R4/R9 = carried mask/value, R13/R11 = value/mask of this Back byte
blitOdd	cmp.w   #LCD_H, R14
	jhs     boNext
	mov.w   R14, R7                 ; R7 = Back + y * 64 + (x - 1) / 2
	swpb    R7
	rra.w   R7
	rra.w   R7
	mov.w   &BlitX, R15
	rra.w   R15
	add.w   R15, R7
	add.w   #FbBack, R7
	mov.w   R12, R8
	mov.w   &BlitRowBytes, R10
	clr.w   R4
	clr.w   R9
boByte	mov.b   @R8+, R15
	mov.b   SwapTab(R15), R15       ; right pixel high, left pixel low
	mov.b   MaskTab(R15), R11
	mov.w   R15, R13
	and.w   #0x0F, R13
	bis.w   R9, R13                 ; carried high nibble + left pixel
	mov.w   R11, R6
	and.w   #0x0F, R11
	bis.w   R4, R11
	and.w   #0xF0, R6
	mov.w   R6, R4                  ; carry the right pixel's mask...
	and.w   #0xF0, R15
	mov.w   R15, R9                 ; ...and value
	bic.b   R11, 0(R7)
	bis.b   R13, 0(R7)
	inc.w   R7
	dec.w   R10
	jnz     boByte
	bic.b   R4, 0(R7)               ; the last right pixel
	bis.b   R9, 0(R7)
boNext	add.w   &BlitRowBytes, R12
	inc.w   R14
	dec.w   R5
	jnz     blitOdd
	jmp     blitDone

; Partly off screen left or right: pixel by pixel with clipping.
blitRow	cmp.w   #LCD_H, R14
	jhs     blitNextRow             ; unsigned: row above or below the screen
	mov.w   R14, R7                 ; R7 = Back + y * 64
	rla.w   R7
	rla.w   R7
	rla.w   R7
	rla.w   R7
	rla.w   R7
	rla.w   R7
	add.w   #FbBack, R7
	mov.w   R12, R8
	mov.w   &BlitX, R9
	mov.w   R4, R10

blitPair	mov.b   @R8+, R15               ; two pixels
	mov.w   R15, R11
	rra.w   R11                     ; left pixel = high nibble
	rra.w   R11
	rra.w   R11
	rra.w   R11
	PLOT_NIB
	inc.w   R9
	dec.w   R10
	jz      blitNextRow
	mov.w   R15, R11
	and.w   #0x0F, R11              ; right pixel = low nibble
	PLOT_NIB
	inc.w   R9
	dec.w   R10
	jnz     blitPair

blitNextRow	add.w   &BlitRowBytes, R12
	inc.w   R14
	dec.w   R5
	jnz     blitRow

blitDone	pop.w   R10
	pop.w   R9
	pop.w   R8
	pop.w   R7
	pop.w   R6
	pop.w   R5
	pop.w   R4
	ret

;------------------------------------------------------------------------------
; FbText - R12 = string (ends with a 0 byte), R13 = x, R14 = y,
;          R15 = color + (background << 8); background 16 or more = none
; Characters are 6x8 (grlib's fixed font, 32..126; others print as '?').
; A character that isn't completely on the screen is skipped.
; Returns R12 = x after the text.
;
; Each row of a character is 6 bits. Every Back byte (2 pixels) is looked up
; in TextVal/TextMsk, built once per call from the colors: index bits 3-2 say
; which of the 2 pixels belong to the character (they don't all at odd x),
; bits 1-0 which are ink.
; R4 = string, R5 = x, R6 = y, R7 = Back byte, R8 = glyph row, R9 = rows left,
; R10 = table index, R11 = row bits
;------------------------------------------------------------------------------
FbText:
	push.w  R4
	push.w  R5
	push.w  R6
	push.w  R7
	push.w  R8
	push.w  R9
	push.w  R10
	mov.w   R12, R4
	mov.w   R13, R5
	mov.w   R14, R6
	mov.w   R15, R8
	and.w   #0x0F, R8               ; R8 = ink color
	mov.w   R15, R9
	swpb    R9
	and.w   #0xFF, R9               ; R9 = background (16+ = none)

	clr.w   R10                     ; build the 16-entry tables
txTab	clr.w   R11                     ; value
	clr.w   R12                     ; mask
	bit.w   #8, R10                 ; left pixel part of the character?
	jz      txLeftDone
	bit.w   #2, R10                 ; ink?
	jz      txLeftBg
	mov.w   R8, R11
	mov.w   #0x0F, R12
	jmp     txLeftDone
txLeftBg	cmp.w   #16, R9
	jhs     txLeftDone
	mov.w   R9, R11
	mov.w   #0x0F, R12
txLeftDone	rla.w   R11                     ; left pixel = high nibble
	rla.w   R11
	rla.w   R11
	rla.w   R11
	rla.w   R12
	rla.w   R12
	rla.w   R12
	rla.w   R12
	bit.w   #4, R10                 ; right pixel part of the character?
	jz      txRightDone
	bit.w   #1, R10
	jz      txRightBg
	bis.w   R8, R11
	bis.w   #0x0F, R12
	jmp     txRightDone
txRightBg	cmp.w   #16, R9
	jhs     txRightDone
	bis.w   R9, R11
	bis.w   #0x0F, R12
txRightDone	mov.b   R11, TextVal(R10)
	mov.b   R12, TextMsk(R10)
	inc.w   R10
	cmp.w   #16, R10
	jlo     txTab

txChar	mov.b   @R4+, R12
	tst.w   R12
	jz      txDone
	sub.w   #32, R12
	cmp.w   #95, R12
	jlo     txInFont
	mov.w   #31, R12            ; not in the font: '?'
txInFont	cmp.w   #LCD_W-5, R5            ; unsigned: x < 0 is off screen too
	jhs     txNext
	cmp.w   #LCD_H-7, R6
	jhs     txNext
	rla.w   R12                     ; 8 bytes per character
	rla.w   R12
	rla.w   R12
	add.w   #Font6x8, R12
	mov.w   R12, R8
	mov.w   R5, R12                 ; mark bytes x/2 .. (x+5)/2, 8 rows
	rra.w   R12
	mov.w   R5, R13
	add.w   #5, R13
	rra.w   R13
	mov.w   R6, R14
	mov.w   #8, R15
	call    #MarkRect_sr
	mov.w   R6, R7                  ; R7 = Back + y * 64 + x / 2
	swpb    R7
	rra.w   R7
	rra.w   R7
	mov.w   R5, R15
	rra.w   R15
	add.w   R15, R7
	add.w   #FbBack, R7
	mov.w   #8, R9
	bit.w   #1, R5
	jnz     txOdd
txEven	mov.b   @R8+, R11               ; row: bit 5 = left pixel
	; right pair first: pixels 4-5, then 2-3, then 0-1
	mov.w   R11, R15
	and.w   #3, R15
	mov.b   TextMsk+12(R15), R13
	bic.b   R13, 2(R7)
	mov.b   TextVal+12(R15), R13
	bis.b   R13, 2(R7)
	rra.w   R11
	rra.w   R11
	mov.w   R11, R15
	and.w   #3, R15
	mov.b   TextMsk+12(R15), R13
	bic.b   R13, 1(R7)
	mov.b   TextVal+12(R15), R13
	bis.b   R13, 1(R7)
	rra.w   R11
	rra.w   R11
	mov.w   R11, R15
	mov.b   TextMsk+12(R15), R13
	bic.b   R13, 0(R7)
	mov.b   TextVal+12(R15), R13
	bis.b   R13, 0(R7)
	add.w   #FB_BPL, R7
	dec.w   R9
	jnz     txEven
	jmp     txNext
txOdd	mov.b   @R8+, R11
	rla.w   R11                     ; 7 pixels from x-1: pad, 0-5, pad
	; bytes 3 (pixel 5 + pad), 2, 1, 0 (pad + pixel 0)
	mov.w   R11, R15
	and.w   #3, R15
	mov.b   TextMsk+8(R15), R13
	bic.b   R13, 3(R7)
	mov.b   TextVal+8(R15), R13
	bis.b   R13, 3(R7)
	rra.w   R11
	rra.w   R11
	mov.w   R11, R15
	and.w   #3, R15
	mov.b   TextMsk+12(R15), R13
	bic.b   R13, 2(R7)
	mov.b   TextVal+12(R15), R13
	bis.b   R13, 2(R7)
	rra.w   R11
	rra.w   R11
	mov.w   R11, R15
	and.w   #3, R15
	mov.b   TextMsk+12(R15), R13
	bic.b   R13, 1(R7)
	mov.b   TextVal+12(R15), R13
	bis.b   R13, 1(R7)
	rra.w   R11
	rra.w   R11
	mov.w   R11, R15
	mov.b   TextMsk+4(R15), R13
	bic.b   R13, 0(R7)
	mov.b   TextVal+4(R15), R13
	bis.b   R13, 0(R7)
	add.w   #FB_BPL, R7
	dec.w   R9
	jnz     txOdd
txNext	add.w   #6, R5
	jmp     txChar

txDone	mov.w   R5, R12
	pop.w   R10
	pop.w   R9
	pop.w   R8
	pop.w   R7
	pop.w   R6
	pop.w   R5
	pop.w   R4
	ret

;------------------------------------------------------------------------------
; LcdPresent - send what changed between Back and Front.
; Returns R12 = number of panel windows opened (0 = nothing changed).
;
; Only rows a drawing call touched are looked at, and only between their
; DirtyLo and DirtyHi bytes. Each row part is scanned one word (4 pixels) at a
; time. A run starts at the first
; changed word and grows while changes keep appearing within MERGE_GAP words;
; short unchanged gaps are resent because a new window costs ~11 bytes.
; Every run that is sent is also copied into Front.
; Runs always open a window from their row down to the bottom of the screen,
; so if the next row changes over the same columns the pixels just continue
; streaming without any commands (a full-screen change becomes one window).
;
; R4 = Back row start, R5 = y, R6 = gap counter, R7 = Back scan pointer,
; R10 = Front scan pointer, R12/R13 = run start/end (byte offset in the row),
; R14 = words left in the row, R15 = scratch. EmitRun_sr uses R8-R11, R15.
;------------------------------------------------------------------------------
LcdPresent:
	push.w  R4
	push.w  R5
	push.w  R6
	push.w  R7
	push.w  R8
	push.w  R9
	push.w  R10

	mov.w   #0xFFFF, &WinNextY      ; no window open yet
	clr.w   &WinCount
	tst.w   &AnyDirty
	jz      presDone                ; nothing drawn since the last present
	clr.w   &AnyDirty
	clr.w   R5

presRow	cmp.b   #0xFF, DirtyLo(R5)
	jeq     presNextRow             ; row not touched since the last present
	mov.b   DirtyLo(R5), R12
	mov.b   DirtyHi(R5), R14
	mov.b   #0xFF, DirtyLo(R5)      ; clean again
	clr.b   DirtyHi(R5)
	bic.w   #1, R12                 ; whole words: first byte even,
	bis.w   #1, R14                 ;              last byte odd
	sub.w   R12, R14
	inc.w   R14
	rra.w   R14                     ; R14 = words to look at
	mov.w   R5, R4                  ; R4 = Back + y * 64
	rla.w   R4
	rla.w   R4
	rla.w   R4
	rla.w   R4
	rla.w   R4
	rla.w   R4
	add.w   #FbBack, R4
	mov.w   R4, R7
	add.w   R12, R7                 ; R7 = Back scan pointer
	mov.w   R7, R10
	add.w   #FB_SIZE, R10           ; R10 = same place in Front

; Look for the first changed word, 4 words per pass while there are 4 left
findStart	cmp.w   #4, R14
	jlo     findOne
	mov.w   @R10+, R15
	cmp.w   @R7+, R15
	jne     hit1
	mov.w   @R10+, R15
	cmp.w   @R7+, R15
	jne     hit2
	mov.w   @R10+, R15
	cmp.w   @R7+, R15
	jne     hit3
	mov.w   @R10+, R15
	cmp.w   @R7+, R15
	jne     hit4
	sub.w   #4, R14
	jnz     findStart
	jmp     presNextRow
findOne	tst.w   R14
	jz      presNextRow
	mov.w   @R10+, R15
	cmp.w   @R7+, R15
	jne     hit1
	dec.w   R14
	jmp     findOne
hit4	dec.w   R14                     ; words used up in this pass
hit3	dec.w   R14
hit2	dec.w   R14
hit1	dec.w   R14

runStart	mov.w   R7, R12
	sub.w   R4, R12
	decd.w  R12                     ; R12 = byte offset of the changed word
	mov.w   R12, R13

gapReset	mov.w   #MERGE_GAP, R6
runGrow	tst.w   R14
	jz      runLastInRow
	dec.w   R14
	mov.w   @R10+, R15
	cmp.w   @R7+, R15
	jne     runHit
	dec.w   R6
	jnz     runGrow
	call    #EmitRun_sr             ; gap too long: send this run
	tst.w   R14
	jnz     findStart               ; keep looking in the same row
	jmp     presNextRow
runHit	mov.w   R7, R13
	sub.w   R4, R13
	decd.w  R13                     ; R13 = byte offset of the last change
	jmp     gapReset
runLastInRow	call    #EmitRun_sr

presNextRow	inc.w   R5
	cmp.w   #LCD_H, R5
	jlo     presRow

presDone	mov.w   &WinCount, R12
	pop.w   R10
	pop.w   R9
	pop.w   R8
	pop.w   R7
	pop.w   R6
	pop.w   R5
	pop.w   R4
	ret

;------------------------------------------------------------------------------
; LcdPresentFull - send the whole Back buffer as one window. Front becomes a
; copy of Back and every row is clean again. Returns R12 = 1.
;------------------------------------------------------------------------------
LcdPresentFull:
	push.w  R8
	push.w  R9
	push.w  R10
	mov.w   #0xFFFF, &WinNextY
	clr.w   R12                     ; bytes 0..63 of every row
	mov.w   #FB_BPL-1, R13
	clr.w   R14                     ; from row 0
	call    #OpenWindow_sr
	mov.w   #FbBack, R8
	mov.w   #FB_SIZE, R9
	call    #Stream_sr                ; (also makes Front = Back)
	clr.w   R12                     ; all rows clean
dirtyClr	mov.b   #0xFF, DirtyLo(R12)
	clr.b   DirtyHi(R12)
	inc.w   R12
	cmp.w   #LCD_H, R12
	jlo     dirtyClr
	clr.w   &AnyDirty
	mov.w   #1, R12                 ; one window
	pop.w   R10
	pop.w   R9
	pop.w   R8
	ret

;------------------------------------------------------------------------------
;           Internal subroutines
;------------------------------------------------------------------------------

; EmitRun_sr - send the run R12..R13 (byte offsets of the first and last
; changed word) of Back row R4, row y = R5. Continues the open window when it
; lines up, otherwise opens a new one. Keeps R4-R7, R10, R14.
EmitRun_sr:
	push.w  R10
	push.w  R14
	inc.w   R13                     ; R13 = last byte of the last word
	cmp.w   &WinNextY, R5
	jne     emitTrim
	cmp.w   &WinXs, R12
	jne     emitTrim
	cmp.w   &WinXe, R13
	jeq     emitStream              ; same columns, next row: just keep going
emitTrim	mov.w   R4, R15                 ; a new window is needed: drop an
	add.w   R12, R15                ; unchanged first or last byte (the
	cmp.b   FB_SIZE(R15), 0(R15)    ; scan works in words), 4 panel bytes
	jne     emitTrimEnd             ; less each
	inc.w   R12
emitTrimEnd	mov.w   R4, R15
	add.w   R13, R15
	cmp.b   FB_SIZE(R15), 0(R15)
	jne     emitCheck
	dec.w   R13
emitCheck	cmp.w   &WinNextY, R5           ; the trimmed run may fit the window
	jne     emitOpen
	cmp.w   &WinXs, R12
	jne     emitOpen
	cmp.w   &WinXe, R13
	jeq     emitStream
emitOpen	mov.w   R5, R14
	call    #OpenWindow_sr
	inc.w   &WinCount
emitStream	mov.w   R5, R15
	inc.w   R15
	mov.w   R15, &WinNextY
	mov.w   R4, R8
	add.w   R12, R8                 ; first byte
	mov.w   R13, R9
	sub.w   R12, R9
	inc.w   R9                      ; byte count
	call    #Stream_sr
	pop.w   R14
	pop.w   R10
	ret

; OpenWindow_sr - R12/R13 = first/last byte offset in the row (2 px each),
; R14 = first row. Window runs to the bottom of the screen. Uses R15.
OpenWindow_sr:
	mov.w   R12, &WinXs
	mov.w   R13, &WinXe
	mov.w   #CM_CASET, R15
	call    #LcdCmd_sr
	mov.w   R12, R15
	rla.w   R15                     ; x = byte offset * 2
	add.w   #LCD_X_OFF, R15
	call    #LcdWord_sr
	mov.w   R13, R15
	rla.w   R15
	add.w   #LCD_X_OFF+1, R15       ; last pixel of the last byte
	call    #LcdWord_sr
	mov.w   #CM_RASET, R15
	call    #LcdCmd_sr
	mov.w   R14, R15
	add.w   #LCD_Y_OFF, R15
	call    #LcdWord_sr
	mov.w   #LCD_H-1+LCD_Y_OFF, R15
	call    #LcdWord_sr
	mov.w   #CM_RAMWR, R15
	call    #LcdCmd_sr
	ret

; Stream_sr - R8 = first Back byte, R9 = byte count (> 0).
; Expands CHUNK Back bytes at a time through PairTab into a line buffer, then
; hands it to DMA channel 0 and fills the other buffer while that one is sent.
; Returns once the last chunk is started (LcdCmd_sr / LcdWait wait for it).
; Every byte sent is also copied into Front, which then matches the glass.
; Uses R8-R13, R15.
Stream_sr:
strChunk	mov.w   #CHUNK, R12
	cmp.w   R12, R9
	jhs     strSize                 ; at least a full chunk left
	mov.w   R9, R12                 ; last, shorter chunk
strSize	sub.w   R12, R9
	mov.w   &LineNext, R13
	mov.w   R13, R15                ; R15 = start of this buffer
strExpand	mov.b   @R8+, R10               ; two pixels
	mov.b   R10, FB_SIZE-1(R8)      ; Front = Back (R8 already moved on)
	rla.w   R10
	rla.w   R10                     ; 4 bytes per PairTab entry
	mov.w   PairTab(R10), 0(R13)
	mov.w   PairTab+2(R10), 2(R13)
	add.w   #4, R13
	dec.w   R12
	jnz     strExpand

	; Wait for the previous chunk: DMA finished and the bus idle, so the
	; only TXIFG edge from now on is the one our first byte makes.
strWaitDma	bit.w   #DMAEN, &DMA0CTL
	jnz     strWaitDma
strWaitBus	bit.w   #UCBUSY, &UCB0STATW
	jnz     strWaitBus

	sub.w   R15, R13                ; bytes in this buffer
	dec.w   R13
	mov.w   R13, &DMA0SZ            ; DMA sends all but the first byte
	mov.w   R15, R13
	inc.w   R13
	mov.w   R13, &DMA0SA
	mov.w   #DMADT_0+DMASRCINCR_3+DMADSTINCR_0+DMASRCBYTE+DMADSTBYTE+DMAEN, &DMA0CTL
	mov.b   @R15, &UCB0TXBUF        ; first byte by hand: when it moves to
					; the shift register, TXIFG rises and
					; the DMA takes over

	cmp.w   #LineBufA, R15          ; fill the other buffer next
	jeq     strUseB
	mov.w   #LineBufA, &LineNext
	jmp     strMore
strUseB	mov.w   #LineBufB, &LineNext
strMore	tst.w   R9
	jnz     strChunk
	ret

; BuildPairTab_sr - PairTab[b] = Palette[b >> 4], Palette[b & 15], each with
; the high byte first in memory. Uses R12-R15.
BuildPairTab_sr:
	mov.w   #PairTab, R12
	clr.w   R13                     ; left pixel index * 2
ptLeft	clr.w   R14                     ; right pixel index * 2
ptRight	mov.w   Palette(R13), R15
	swpb    R15
	mov.w   R15, 0(R12)
	mov.w   Palette(R14), R15
	swpb    R15
	mov.w   R15, 2(R12)
	add.w   #4, R12
	incd.w  R14
	cmp.w   #32, R14
	jlo     ptRight
	incd.w  R13
	cmp.w   #32, R13
	jlo     ptLeft
	ret

; ClipRect_sr - R12 = x, R13 = y (signed), R14 = w + (h << 8).
; Returns R12 = x0, R13 = y0, R6 = x end, R14 = y end (ends exclusive), all
; inside the screen, and carry set if nothing is left. Uses R6, R12-R14.
ClipRect_sr:
	mov.w   R14, R6
	and.w   #0x00FF, R6             ; w
	swpb    R14
	and.w   #0x00FF, R14            ; h
	add.w   R12, R6                 ; x end
	add.w   R13, R14                ; y end
	cmp.w   #0, R12                 ; signed compares
	jge     clipX0
	clr.w   R12
clipX0	cmp.w   #0, R13
	jge     clipY0
	clr.w   R13
clipY0	cmp.w   #LCD_W+1, R6
	jl      clipX1
	mov.w   #LCD_W, R6
clipX1	cmp.w   #LCD_H+1, R14
	jl      clipY1
	mov.w   #LCD_H, R14
clipY1	cmp.w   R6, R12
	jge     clipEmpty
	cmp.w   R14, R13
	jge     clipEmpty
	clrc
	ret
clipEmpty	setc
	ret

; MarkClipped_sr - mark the ClipRect_sr result as touched. Keeps R6, R12-R14.
MarkClipped_sr:
	push.w  R12
	push.w  R13
	push.w  R14
	mov.w   R14, R15
	sub.w   R13, R15                ; rows
	mov.w   R13, R14                ; first row
	mov.w   R6, R13
	dec.w   R13
	rra.w   R13                     ; last byte
	rra.w   R12                     ; first byte
	call    #MarkRect_sr
	pop.w   R14
	pop.w   R13
	pop.w   R12
	ret

; MarkRect_sr - R12 = first byte, R13 = last byte, R14 = first row,
; R15 = rows. Widens DirtyLo/DirtyHi of those rows. Uses R14, R15.
MarkRect_sr:
	mov.w   #1, &AnyDirty
markLoop	cmp.b   R12, DirtyLo(R14)
	jlo     markHi                  ; already starts further left
	mov.b   R12, DirtyLo(R14)
markHi	cmp.b   R13, DirtyHi(R14)
	jhs     markNext                ; already ends further right
	mov.b   R13, DirtyHi(R14)
markNext	inc.w   R14
	dec.w   R15
	jnz     markLoop
	ret

; LcdCmd_sr - R15 = command byte. Waits for DMA and the bus to go idle before
; and after, because D/C must not change while a byte is still shifting out.
LcdCmd_sr:
cmdWaitDma	bit.w   #DMAEN, &DMA0CTL
	jnz     cmdWaitDma
cmdWait1	bit.w   #UCBUSY, &UCB0STATW
	jnz     cmdWait1
	DC_CMD
	mov.b   R15, &UCB0TXBUF
cmdWait2	bit.w   #UCBUSY, &UCB0STATW
	jnz     cmdWait2
	DC_DATA
	ret

; LcdWord_sr - R15 = 16-bit parameter, sent high byte first
LcdWord_sr:
	swpb    R15
	SPI_TX  R15
	swpb    R15
	SPI_TX  R15
	ret

; LcdRunSeq_sr - R12 = command table (see InitSeq). Uses R13-R15.
LcdRunSeq_sr:
seqNext	mov.b   @R12+, R15
	cmp.w   #0xFF, R15
	jeq     seqDone
	call    #LcdCmd_sr
	mov.b   @R12+, R13              ; count + delay flag
	mov.w   R13, R14
	and.w   #0x7F, R14
	jz      seqDelay
seqParam	mov.b   @R12+, R15
	SPI_TX  R15
	dec.w   R14
	jnz     seqParam
seqDelay	bit.w   #0x80, R13
	jz      seqNext
	mov.w   #120, R15
	call    #DelayMs_sr
	jmp     seqNext
seqDone	ret

; DelayMs_sr - R15 = milliseconds (at CLOCK_MHZ). Uses R14.
DelayMs_sr:
dlyOuter	mov.w   #LOOPS_PER_MS, R14
dlyInner	dec.w   R14
	jnz     dlyInner
	dec.w   R15
	jnz     dlyOuter
	ret

	.end
