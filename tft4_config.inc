;******************************************************************************
; tft4_config.inc - settings for tft4.asm
; tft4.asm includes this file; assembly programs can include it too, to get
; CLOCK_MHZ for their timers. Keep one copy per project and change it there
; (tools/sync_driver.sh never overwrites an existing one).
;******************************************************************************

; Clock: MCLK = SMCLK = CLOCK_MHZ. ClockInit sets it; the delays in LcdInit
; count on it. 16 or 8.
CLOCK_MHZ       .set    16

; SPI clock = SMCLK / SPI_DIV. 1 gives 16 MHz at CLOCK_MHZ 16, above the
; ST7735's rated ~15 MHz write clock. If the picture is garbled, set 2.
SPI_DIV         .set    1

; Panel orientation (MADCTL) and the matching GRAM offsets.
; 0xC8 = MY + MX + BGR: TI's "up" orientation, connector at the top.
LCD_MADCTL      .set    0xC8
LCD_X_OFF       .set    2
LCD_Y_OFF       .set    3

; Tuning (normally leave these alone)
MERGE_GAP       .set    3               ; unchanged words (4 px each) resent
                                        ; to avoid opening a new window
CHUNK           .set    32              ; Back bytes per DMA line buffer
                                        ; (4 SPI bytes each; 2 buffers in RAM)
