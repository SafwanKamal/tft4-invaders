/*******************************************************************************
 * Safwan Kamal
 * SEPTEMBER 2026
 * main.c - TFT4 Invaders on MSP-EXP430FR6989 + Educational BoosterPack MKII
 *
 * Shows the tft4 assembly driver used from C (tft4.h):
 *   the game draws every frame from scratch into the Back buffer and
 *   LcdPresent sends only what changed; a palette change is sent with
 *   LcdPresentFull.
 *
 *   MCLK = SMCLK = 16 MHz (ClockInit), SPI 16 MHz (see tft4_config.inc)
 *   Timer_A0: 25 Hz frame tick          Timer_A1: 2 us counter for timing
 *   Input: S1 = P1.1 (left), S2 = P1.2 (right), or the joystick X axis (A10)
 *   Segment LCD: time to draw + send one frame, in ms (e.g. "   4.2")
 *   LED1 (red, P1.0): on while a frame is drawn and sent
 ******************************************************************************/
#include <msp430.h>
#include <stdint.h>
#include "tft4.h"
#include "game.h"

#define JOY_LEFT_BELOW  1300        /* 12-bit ADC; centre is ~2048 */
#define JOY_RIGHT_ABOVE 2800
#define JOY_INVERT_X    0           /* set to 1 if left/right come out swapped */
#define SEG_EVERY       8           /* segment LCD update, in frames */

static volatile uint8_t s_frameReady;

/*------------------------------------------------------------------ input */
static void inputInit(void)
{
    P1DIR &= ~(BIT1 | BIT2);                    /* S1, S2 with pull-ups */
    P1REN |= BIT1 | BIT2;
    P1OUT |= BIT1 | BIT2;
    P9SEL0 |= BIT2; P9SEL1 |= BIT2;             /* P9.2 = A10, joystick X */
    ADC12CTL0 = ADC12SHT0_2 | ADC12ON;
    ADC12CTL1 = ADC12SHP;
    ADC12CTL2 = ADC12RES_2;                     /* 12 bit */
    ADC12MCTL0 = ADC12INCH_10;
}

static uint8_t readInput(void)
{
    uint8_t in = (uint8_t)~P1IN, btn = 0, jl, jr;
    uint16_t x;
    ADC12CTL0 |= ADC12ENC | ADC12SC;
    while (ADC12CTL1 & ADC12BUSY) { }
    x = ADC12MEM0;
    jl = x < JOY_LEFT_BELOW;
    jr = x > JOY_RIGHT_ABOVE;
    if (JOY_INVERT_X) { uint8_t t = jl; jl = jr; jr = t; }
    if ((in & BIT1) || jl) btn |= BTN_LEFT;
    if ((in & BIT2) || jr) btn |= BTN_RIGHT;
    return btn;
}

/*------------------------------------------------------------------ segment LCD */
static const uint16_t kSegDigit[11] = {
    0xFC00, 0x6000, 0xDB00, 0xF300, 0x6700, 0xB700, 0xBF00, 0xE000, 0xFF00, 0xF700, 0 };
static volatile unsigned char *const kSegLo[6] = { &LCDM9, &LCDM16, &LCDM20, &LCDM5, &LCDM7, &LCDM11 };
static volatile unsigned char *const kSegHi[6] = { &LCDM8, &LCDM15, &LCDM19, &LCDM4, &LCDM6, &LCDM10 };

static void segInit(void)                       /* as Pong_Assembly */
{
    LCDCPCTL0 = 0xFFC0;
    LCDCPCTL1 = 0xF03F;
    LCDCPCTL2 = 0x00F0;
    LCDCCTL0 |= LCDPRE__16 | LCD4MUX;
    LCDCMEMCTL |= LCDCLRM;
    LCDCCTL0 |= LCDON;
}

static void segShowTenths(uint16_t t)           /* "  12.3" */
{
    uint8_t pos;
    for (pos = 0; pos < 6; pos++) {
        uint8_t d = t % 10, ch = (pos >= 2 && t == 0) ? 10 : d;
        *kSegLo[pos] = (uint8_t)kSegDigit[ch];
        *kSegHi[pos] = (uint8_t)(kSegDigit[ch] >> 8);
        t /= 10;
    }
    LCDM16 |= 0x01;                             /* decimal point after position 1 */
}

/*------------------------------------------------------------------ timers */
static void timersInit(void)
{
    TA0CCR0  = 40000 - 1;                       /* 1 MHz / 40000 = 25 Hz */
    TA0CCTL0 = CCIE;
    TA0EX0   = Tft4ClockMHz / 8 - 1;            /* SMCLK / 8 / 2 = 1 MHz */
    TA0CTL   = TASSEL__SMCLK | ID__8 | MC__UP | TACLR;
    TA1EX0   = Tft4ClockMHz / 4 - 1;            /* SMCLK / 8 / 4 = 500 kHz */
    TA1CTL   = TASSEL__SMCLK | ID__8 | MC__CONTINUOUS | TACLR;
}

int main(void)
{
    uint16_t sum = 0;
    uint8_t n = 0;

    WDTCTL = WDTPW | WDTHOLD;
    ClockInit();                                /* 16 MHz, FRAM wait state */
    P1OUT &= ~BIT0; P1DIR |= BIT0;              /* LED1 */
    inputInit();
    PM5CTL0 &= ~LOCKLPM5;
    segInit();
    timersInit();
    LcdInit();
    game_init();
    __enable_interrupt();

    for (;;) {
        uint16_t t0;
        uint8_t flags;
        __disable_interrupt();
        while (!s_frameReady) {                 /* sleep until the 25 Hz tick */
            __bis_SR_register(LPM0_bits | GIE);
            __disable_interrupt();
        }
        s_frameReady = 0;
        __enable_interrupt();

        P1OUT |= BIT0;
        t0 = TA1R;
        flags = game_frame(readInput());
        if (flags & GAME_PRESENT_FULL) LcdPresentFull();
        else LcdPresent();
        LcdWait();                              /* before sleeping: SMCLK must run */
        sum += (uint16_t)(TA1R - t0);
        P1OUT &= ~BIT0;

        if (++n == SEG_EVERY) {                 /* average of 8 frames, 2 us ticks */
            segShowTenths((uint16_t)((sum / SEG_EVERY + 25) / 50));
            sum = 0;
            n = 0;
        }
    }
}

#ifndef __clang__                               /* (the emulator test builds with clang) */
#pragma vector = TIMER0_A0_VECTOR
__interrupt void timer0Isr(void)
{
    s_frameReady = 1;
    __bic_SR_register_on_exit(LPM0_bits);
}
#endif
