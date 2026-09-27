/* system_pre_init.c - runs before the C start-up code initializes variables:
 * stop the watchdog so it can't reset the board during start-up. */
#include <msp430.h>
#include <stdint.h>

int _system_pre_init(void)
{
    WDTCTL = WDTPW | WDTHOLD;
    return 1;                   /* 1 = do initialize the variables */
}
