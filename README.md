# TFT4 Invaders

FR6989 Invaders rebuilt on the tft4 driver, to show what the driver can do. It runs on the MSP-EXP430FR6989 LaunchPad with the Educational BoosterPack MKII. The game is written in C and calls the assembly driver through `tft4.h`.

What's new compared with the 1-bit FR6989 Invaders:

- **16 colors** for all sprites, with transparency. The invaders have eyes, the UFO has lit windows, and the bunkers are shaded.
- **A 3-layer starfield** that scrolls behind everything at three speeds. That is about 36 pixels changing all over the screen in every frame.
- **Explosion particles** (`FbPixel`): fire-colored ones when an invader or the UFO dies, and ice-colored ones when the player is hit.
- **A palette flash** when the player is hit. The black background turns deep red for one frame. That takes one `PaletteSet` and one `LcdPresentFull`, instead of redrawing anything.
- **Scaled title text**, drawn from the driver's own 6x8 font (`Font6x8`), with a color per row and a drop shadow.
- **The segment LCD shows how long a frame takes** to draw and send, averaged over 8 frames.

The gameplay is the same as FR6989 Invaders.

Tested on the board (TI compiler, 16 MHz): it builds, links and plays.

## Controls

| Input | Does |
|---|---|
| S1 or joystick left | Move left |
| S2 or joystick right | Move right |
| Hold both for 1 s | Pause; press either to resume |
| Fire | Automatic |

The title screen waits for a button. Shooting the UFO drops a capsule, and catching it gives you double shots for 12 s. Every 1500 points you get an extra life. The high score is kept in FRAM, so it survives power-off.

## How it draws

The game uses **full redraw** mode. Every frame it:

1. clears Back (`FbClear`),
2. draws the stars, HUD, invaders, bunkers, shots, effects and particles,
3. calls `LcdPresent`.

The driver then compares every row with what is on the glass and sends only the pixels that changed. The game doesn't have to track what moved, and nothing flickers, because the panel never shows a half-drawn frame.

In the emulator a frame takes about 9–10 ms at 16 MHz: about 5.5 ms of drawing and about 4 ms of present, of which about 1.8 ms is comparing all 128 rows. That leaves plenty of room at 25 frames/s. On the board the segment LCD shows the real number.

## Files

| File | What |
|---|---|
| `main.c` | Platform: clocks (`ClockInit`), input (buttons + joystick ADC), 25 Hz timer, segment LCD, the frame loop |
| `game.c`, `game.h` | The game: logic (from FR6989 Invaders) and all the drawing |
| `sprites.txt` | Sprite art, one character per pixel (palette index; `.` is transparent) |
| `sprites.c`, `sprites.h` | **Generated** by `python3 ../tft4/tools/sprite2asm.py sprites.txt -o sprites.c` |
| `tft4.asm`, `font6x8.asm`, `tft4.h` | The tft4 driver, copied from the tft4 repo. Update with `sh ../tft4/tools/sync_driver.sh ../tft4-invaders`. |
| `tft4_config.inc` | This game's driver settings: 16 MHz clock and SPI. `sync_driver.sh` leaves it alone. |
| `system_pre_init.c` | Stops the watchdog before the C start-up code runs |
| `test/` | Emulator build and autopilot playtest (see below) |

## Getting it running

1. Clone this repo next to the tft4 repo:
   ```
   MSP430/
     tft4/           driver, benchmarks, tools
     tft4-invaders/  this game
   ```
   The driver files are already here, so the game builds on its own. The tft4 repo is only needed to update the driver, regenerate sprites or run the emulator test.
2. In CCS: **File → Import Projects**, pick this folder, then build and flash.

## Project settings (CCS)

The project is a copy of the FR6989_Invaders C project settings, with two changes:

- **Code model small, data model small** (`--code_model=small --data_model=small`). The driver returns with `RET`, which only works with the small model's `CALL`.
- **No GrLib or DriverLib.** The game only uses the driver and the chip's registers.

Memory in the emulator build:

| | Size |
|---|---|
| Frame buffers | ~25 KB of FRAM |
| Code and constants | ~13 KB of FRAM |
| RAM | ~1.35 KB, plus the 512 B stack |

## Emulator test

```
sh test/build_emu.sh ../tft4 <TI's msp430 include_gcc folder> /tmp/gb
python3 test/test_game.py /tmp/gb/game.elf ../tft4/tools/test /tmp/out 700
```

The test builds the game with clang and the driver with llvm-mc. An autopilot then plays it: it starts the game and sweeps left and right. Every 50 frames the test checks that the glass matches Back. It saves screenshots and prints the frame times.

## License

MIT (`LICENSE`), except the 6x8 font data in `font6x8.asm`. It comes from TI's grlib and keeps TI's BSD 3-clause license; see `THIRD_PARTY_NOTICES.md`.
