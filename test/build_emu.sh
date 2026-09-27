#!/bin/sh
# Build TFT4 Invaders for the MSP430 emulator: C with clang, the driver with
# llvm-mc (via the tft4 repo's ti2gnu.py). Not for the board - CCS builds that.
# usage: sh test/build_emu.sh <tft4 repo> <msp430 include dir (TI's include_gcc)> <out dir>
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(cd "$1" && pwd)/tools/test; INC=$2; OUT=$3; mkdir -p $OUT
cp "$T/fr6989_equ.inc" "$T/msp430fr6989_symbols.ld" $OUT/
for f in tft4 font6x8; do
  python3 "$T/ti2gnu.py" "$HERE/$f.asm" "$OUT/$f.s" fr6989_equ.inc
  (cd $OUT && llvm-mc-18 -triple=msp430 -filetype=obj $f.s -o $f.o)
done
CFL="--target=msp430 -Os -ffreestanding -ffunction-sections -fdata-sections -DGAME_SIM -I$HERE -I$INC -I$T/libcstub -D__MSP430FR6989__ -Wall -Wno-unknown-pragmas"
for f in game sprites; do clang $CFL -c $HERE/$f.c -o $OUT/$f.o; done
clang $CFL -x c -c $HERE/test/emu_rt.c.txt -o $OUT/emu_rt.o
(cd $OUT && ld.lld-18 -T $HERE/test/link_game.lds.txt game.o sprites.o emu_rt.o tft4.o font6x8.o -o game.elf 2>&1 | grep -v "entry symbol" || true)
echo "built $OUT/game.elf"
