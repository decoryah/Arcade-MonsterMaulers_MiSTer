#!/usr/bin/env python3
"""Find the frame lag between a state dump of the core and MAME's dumps.

    cmp_lag.py rtl.state_N.txt mame_dir [mame_dir ...] [--span 12]

MAME's dumps are looked up as <dir>/state_<frame>.txt for the frames N-span .. N+span. For each candidate frame
the number of differing words in the registers, the line RAM, the sprite RAM and the palette is printed (and in
the 16 tile-RAM pages), so the lag shows as a minimum -- 0 for a frame-exact match."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cmp_state import load


def main():
    args = sys.argv[1:]
    span = 12
    if '--span' in args:
        i = args.index('--span')
        span = int(args[i + 1])
        del args[i:i + 2]
    if len(args) < 2:
        print(__doc__)
        return 2
    rtl = load(args[0])
    n = int(os.path.basename(args[0]).split('_')[-1].split('.')[0])
    dirs = args[1:]
    print('RTL state at frame %d' % n)
    print('%6s %6s %6s %6s %6s %7s' % ('mame', 'regs', 'rozli', 'sprram', 'palet', 'vram'))
    for f in range(n - span, n + span + 1):
        path = None
        for d in dirs:
            p = os.path.join(d, 'state_%d.txt' % f)
            if os.path.exists(p):
                path = p
                break
        if not path:
            continue
        m = load(path)

        def nd(keys):
            t = 0
            for k in keys:
                if k in rtl and k in m:
                    t += sum(1 for a, b in zip(rtl[k], m[k]) if a != b)
            return t
        regs = nd(['K56REGS', 'K56REGSB', 'K46REGS', 'K47REGS', 'K55REGS', 'K38REGS', 'ROZCLIP', 'ROZCT16'])
        vr = nd(['VRAM %d' % i for i in range(16)])
        print('%6d %6d %6d %6d %6d %7d%s' % (f, regs, nd(['ROZLI16']), nd(['SPRITERAM']), nd(['PALETTE']), vr,
                                         '   <-- exact' if regs + nd(['ROZLI16', 'SPRITERAM', 'PALETTE']) + vr == 0 else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
