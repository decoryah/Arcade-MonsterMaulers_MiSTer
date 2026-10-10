#!/usr/bin/env python3
"""Turn a 288x224 uint32 RGB raster dump (the benches' .rgb) into a PNG: rgb2png.py in.rgb out.png [scale]"""
import sys, os, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio
VIS_W, VIS_H = 288, 224
d = open(sys.argv[1], 'rb').read(); buf = struct.unpack('<%dI' % (VIS_W * VIS_H), d[:VIS_W * VIS_H * 4])
k = int(sys.argv[3]) if len(sys.argv) > 3 else 1
w, h = VIS_W * k, VIS_H * k; out = bytearray(w * h * 3)
for y in range(h):
    for x in range(w):
        v = buf[(y // k) * VIS_W + (x // k)]; o = (y * w + x) * 3
        out[o] = (v >> 16) & 0xff; out[o + 1] = (v >> 8) & 0xff; out[o + 2] = v & 0xff
pngio.write(sys.argv[2], w, h, out)
print('wrote', sys.argv[2])
