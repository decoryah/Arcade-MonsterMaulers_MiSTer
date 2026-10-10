#!/usr/bin/env python3
# Taken unchanged from plasticbugs/analogue-pocket-gaiapolis (tools/gen_sprite_tables.py, GPL-3.0): the sprite rasterizer's reciprocal ROMs of rtl/data.
# The tables here are byte-identical to what it writes; run it with an output directory to check:  python tools/gen_sprite_tables.py /tmp/x
"""Generate the two reciprocal ROMs the sprite rasterizer needs.

Both reproduce a C integer division exactly, which is what the reference
renderer (and MAME) does, so a table is the only way to stay bit-exact
without an iterative divider in the per-tile path.

  zoom.hex   z[r] = (0x400000 + (r >> 1)) // r for r in 1..1023, z[0] = 0x800000
             the K053247 zoom factor, from the 10-bit register value

  recip.hex  s[d] = 0x800000 // d for d in 1..2047, s[0] = 0
             the source step per destination pixel: (16 << 19) / dst_size

Usage: gen_sprite_tables.py [outdir]
"""
import sys, os

out = sys.argv[1] if len(sys.argv) > 1 else 'rtl/data'
os.makedirs(out, exist_ok=True)

with open(os.path.join(out, 'zoom.hex'), 'w') as f:
    for r in range(1024):
        v = 0x800000 if r == 0 else (0x400000 + (r >> 1)) // r
        f.write('%06x\n' % v)

with open(os.path.join(out, 'recip.hex'), 'w') as f:
    for d in range(2048):
        f.write('%06x\n' % (0 if d == 0 else 0x800000 // d))

print(f'wrote {out}/zoom.hex (1024) and {out}/recip.hex (2048)')
