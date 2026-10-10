#!/usr/bin/env python3
"""Apply the K054539's UPDATE_AT_KEYON write semantics (MAME's default, k054539.cpp) to a register-write log.

    k539_latch.py <in.txt> <out.txt>

While the chip is enabled (0x22f bit 0), a write to a channel's position registers (0x0c-0x0e of each 0x20 block)
is held in a latch and the register keeps its value; the key-on write (0x214) copies the latched bytes into the
registers of every channel it starts. The output log carries the same effect as plain writes: the position
writes are dropped and re-emitted, at the key-on's time, just before the key-on itself.
"""
import sys

regs = {1: [0] * 0x230, 2: [0] * 0x230}
latch = {1: [[0, 0, 0] for _ in range(8)], 2: [[0, 0, 0] for _ in range(8)]}
out = open(sys.argv[2], "w")
held = emitted = 0
for line in open(sys.argv[1]):
    t, chip, r, v = line.split()
    chip = int(chip); r = int(r); v = int(v)
    R = regs[chip]
    on = bool(R[0x22f] & 1)
    if on and r < 0x100 and 0 <= (r & 0x1f) - 0xc <= 2:
        latch[chip][r >> 5][(r & 0x1f) - 0xc] = v
        held += 1
        continue
    if on and r == 0x214:
        for ch in range(8):
            if v & (1 << ch):
                for i in range(3):
                    out.write("%s %d %d %d\n" % (t, chip, ch * 0x20 + 0xc + i, latch[chip][ch][i]))
                    R[ch * 0x20 + 0xc + i] = latch[chip][ch][i]
                    emitted += 1
    R[r] = v
    out.write(line)
out.close()
print("held %d position writes, re-emitted %d at key-on" % (held, emitted))
