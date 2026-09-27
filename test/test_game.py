#!/usr/bin/env python3
"""
test_game.py - play TFT4 Invaders in the MSP430 emulator with an autopilot.
Every frame: game_frame(buttons), then LcdPresent (or LcdPresentFull) and
LcdWait, like main.c. Checks that the glass always matches Back, prints frame
times, saves screenshots.

  python3 test/test_game.py <game.elf> <TFT4_Driver/tools/test> <out dir> [frames]
"""
import os, struct, sys
sys.path.insert(0, sys.argv[2])
from msp430emu import CPU
from PIL import Image

elf, outdir = sys.argv[1], sys.argv[3]
frames = int(sys.argv[4]) if len(sys.argv) > 4 else 600
os.makedirs(outdir, exist_ok=True)
cpu = CPU(elf)
cpu.r[1] = 0x2400
MHZ = 16000.0                     # cycles per ms at 16 MHz
SHOTS = {5: 'title', 60: 'play_start', 200: 'play', 330: 'play_later'}


def call(fn, *a):
    return cpu.call(fn, *a, check_abi=False, max_instr=10 ** 8)


def rgb(c):
    return ((c >> 11) << 3, ((c >> 5) & 63) << 2, (c & 31) << 3)


def save(name):
    g = cpu.lcd.gram
    img = Image.new('RGB', (128, 128))
    img.putdata([rgb(g[y + 3][x + 2]) for y in range(128) for x in range(128)])
    img.resize((384, 384), Image.NEAREST).save(os.path.join(outdir, name + '.png'))


def glass_ok():
    b = cpu.sym('FbBack')
    pal = [cpu.rw(cpu.sym('Palette') + 2 * i) for i in range(16)]
    g = cpu.lcd.gram
    return sum(1 for y in range(128) for x in range(128)
               if g[y + 3][x + 2] != pal[(cpu.mem[b + y * 64 + x // 2] >> (4 if x % 2 == 0 else 0)) & 15])


def debug():
    a = 0x2300                                   # scratch RAM for the struct
    call('game_debug', a)
    m = bytes(cpu.mem[a:a + 64])
    state = m[0]
    px, score = struct.unpack_from('<hH', m, 2)
    lives, wave, alive = m[6], m[7], m[8]
    return state, px, score, lives, wave, alive


call('LcdInit')
call('game_init')
times, full_frames, states = [], 0, set()
btn = 0
for f in range(frames):
    st, px, score, lives, wave, alive = debug()
    states.add(st)
    # autopilot: press to start / restart, then sweep left and right
    if st in (0, 5):
        btn = 1 if (f // 10) % 2 == 0 else 0
    else:
        target = 20 + (f * 3) % 88
        btn = 1 if px > target + 2 else (2 if px < target - 2 else 0)
    c0 = cpu.cycles
    flags = call('game_frame', btn)[0]
    if flags & 1:
        call('LcdPresentFull'); full_frames += 1
    else:
        call('LcdPresent')
    call('LcdWait')
    times.append((cpu.cycles - c0) / MHZ)
    if f % 50 == 0 or f in SHOTS:
        bad = glass_ok()
        assert bad == 0, f"frame {f}: {bad} pixels on the glass differ from Back"
    if f in SHOTS:
        save(SHOTS[f])
    if f % 100 == 0:
        print(f"frame {f:4d}: state {st} score {score:5d} lives {lives} wave {wave} alive {alive:2d}"
              f"  last frame {times[-1]:5.2f} ms", flush=True)
save('last')
play = times[40:]
print(f"frames {frames}: avg {sum(play) / len(play):.2f} ms, worst {max(play):.2f} ms (at 16 MHz, "
      f"drawing + sending), full presents {full_frames}, states seen {sorted(states)}")
err = cpu.lcd.errors + cpu.spi_log_errors
print('errors:', err[:5])
assert not err
