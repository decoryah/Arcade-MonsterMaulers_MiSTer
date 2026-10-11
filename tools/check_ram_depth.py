#!/usr/bin/env python3
"""Check the RAMs Quartus actually built against the depths the RTL declares.

    check_ram_depth.py <MonsterMaulers.fit.rpt> [--list]

A simulator evaluates an array exactly as declared; Quartus 17 does not always. A two-dimensional
unpacked array such as `logic [11:0] lbuf [2][288]` (576 words) was built 512 words deep, so bank 1's
pixels 224..287 landed on bank 0's pixels 0..63 -- invisible in every bench, and on the board each text
line's first eight characters reappeared at the right edge on alternate lines. Run this on every fit
report; it exits 1 if a listed memory is shallower than its minimum, or is missing.
"""
import re
import sys

# (instance name fragment, minimum words, minimum width)
EXPECT = [
    ("k056832_tilemap:u_tm|altsyncram:lbuf0_rtl", 576, 12),
    ("k056832_tilemap:u_tm|altsyncram:lbuf1_rtl", 576, 12),
    ("k056832_tilemap:u_tm|altsyncram:lbuf2_rtl", 576, 12),
    ("k056832_tilemap:u_tm|altsyncram:lbuf3_rtl", 576, 12),
    ("k053247_draw:u_dr|altsyncram:solid_rtl", 2048, 17),      # the ring: {slot[1:0], x[8:0]}
    ("k053247_draw:u_dr|altsyncram:shade_rtl", 2048, 11),
    ("k053247_draw:u_dr|altsyncram:szbuf_rtl", 288, 9),
    ("spr_rowcache:u_rowcache|altsyncram:dmem_rtl", 512, 80),
    ("spr_rowcache:u_rowcache|altsyncram:tmem_rtl", 512, 17),
    ("k053936_roz:u_roz|altsyncram:lbuf_rtl", 3072, 11),
    ("k053936_roz:u_roz|altsyncram:tmem_rtl", 8192, 16),
    ("vram_bram:u_vram|altsyncram:ram_lo_rtl", 65536, 8),
    ("vram_bram:u_vram|altsyncram:ram_hi_rtl", 65536, 8),
    ("mm_main:u_main|altsyncram:wram_rtl", 32768, 16),
    ("mm_main:u_main|altsyncram:sshadow_rtl", 32768, 16),
    ("mm_main:u_main|altsyncram:pal0_rtl", 2048, 16),
    ("mm_main:u_main|altsyncram:pal1_rtl", 2048, 16),
    ("mm_sound:u_snd|altsyncram:ram_rtl", 8192, 8),
    ("k054539:u_k1|altsyncram:ram_lo_rtl", 16384, 8),
    ("k054539:u_k1|altsyncram:ram_hi_rtl", 16384, 8),
    ("k054539:u_k2|altsyncram:ram_lo_rtl", 16384, 8),
    ("k054539:u_k2|altsyncram:ram_hi_rtl", 16384, 8),
    ("rom_cache:u_pcache|altsyncram:dmem_rtl", 8192, 16),
    ("rom_cache:u_scache|altsyncram:dmem_rtl", 2048, 16),
]


def main():
    path = sys.argv[1]
    ram = []
    for line in open(path, errors="replace"):
        if "|ALTSYNCRAM" not in line or not line.startswith(";"):
            continue
        f = [c.strip() for c in line.split(";")]
        # ; name ; type ; mode ; clocks ; words ; width ; words ; width ; ...
        try:
            ram.append((f[1], int(f[5]), int(f[6])))
        except (IndexError, ValueError):
            continue
    if "--list" in sys.argv:
        for n, w, b in ram:
            print("%6d x %-3d %s" % (w, b, n))
    bad = 0
    for frag, wmin, bmin in EXPECT:
        hits = [(n, w, b) for n, w, b in ram if frag in n]
        if not hits:
            print("MISSING  %-52s (expected >= %d x %d)" % (frag, wmin, bmin))
            bad += 1
            continue
        for n, w, b in hits:
            # a wide RAM may be split into several blocks side by side; only depth matters here
            ok = w >= wmin
            if not ok:
                bad += 1
            print("%s  %-52s %6d x %-3d (>= %d)" % ("ok     " if ok else "TOO SHALLOW", frag, w, b, wmin))
    print("%d problem(s)" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
