#!/usr/bin/env python3
# Taken unchanged from plasticbugs/analogue-pocket-gaiapolis (tools/gen_k054539_tables.py, GPL-3.0): the K054539 / K054321 tables of rtl/data.
# The tables here are byte-identical to what it writes; run it with an output directory to check:  python tools/gen_k054539_tables.py /tmp/x
"""Generate the K054539's volume and pan tables as Q2.14 fixed point, and
the K054321's master volume curve as Q4.12.

  k539_vol.hex  256 entries  voltab[i] = 10^(-36 * i / 64 / 20) / 4
  k539_pan.hex   15 entries  pantab[i] = sqrt(i / 14)
  k321_vol.hex   65 entries  2^((v - 40) / 10), v = 0..64 (k054321.cpp propagate_volume)
  k539_timer.hex 256 entries 7200 / (38 + i): the timer period in samples for register 0x227

From k054539.cpp device_start. Q2.14 keeps the 1.80 VOL_CAP representable;
Q4.12 keeps the K054321's 5.28 maximum.
"""
import sys, os, math
out = sys.argv[1] if len(sys.argv) > 1 else 'rtl/data'
os.makedirs(out, exist_ok=True)
with open(os.path.join(out, 'k539_vol.hex'), 'w') as f:
    for i in range(256):
        v = math.pow(10.0, (-36.0 * i / 64.0) / 20.0) / 4.0
        f.write('%04x\n' % int(round(v * 16384)))
with open(os.path.join(out, 'k539_pan.hex'), 'w') as f:
    for i in range(15):
        f.write('%04x\n' % int(round(math.sqrt(i) / math.sqrt(14.0) * 16384)))
    f.write('0000\n')          # pad to 16
with open(os.path.join(out, 'k321_vol.hex'), 'w') as f:
    for v in range(128):
        g = math.pow(2.0, (min(v, 64) - 40) / 10.0)
        f.write('%04x\n' % int(round(g * 4096)))
with open(os.path.join(out, 'k539_timer.hex'), 'w') as f:
    for i in range(256):
        f.write('%04x\n' % (7200 // (38 + i)))
print('wrote k539_vol.hex (256), k539_pan.hex (16), k321_vol.hex (128) and k539_timer.hex (256)')
