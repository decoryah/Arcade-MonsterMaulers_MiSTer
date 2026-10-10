#!/usr/bin/env python3
"""Compares MAME's region slices (tools/lua/dump_regions.lua) with tools/mm_rom.py's rebuild.
    python tools/check_regions.py mmaulers.zip regions.txt [setname]"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mm_rom
reg = mm_rom.regions(sys.argv[1], sys.argv[3] if len(sys.argv) > 3 else "mmaulers")
names = {":maincpu": "maincpu", ":soundcpu": "soundcpu", ":k056832": "k056832", ":k055673": "k055673",
         ":gfx3": "gfx3", ":gfx4": "gfx4", ":k054539": "k054539"}
bad = n = 0
tag = None
for line in open(sys.argv[2]):
    line = line.strip()
    if line.startswith("SLICE"):
        _, tag, off = line.split(); off = int(off); continue
    if line.startswith("REGION") or line.startswith("MISSING"):
        tag = None; print(line); continue
    if tag and tag in names and line:
        data = bytes.fromhex(line)
        mine = reg[names[tag]][off:off + len(data)]
        n += 1
        if mine != data:
            bad += 1
            i = next(i for i in range(len(data)) if mine[i] != data[i])
            print("MISMATCH %s +0x%x: MAME %02x, rebuilt %02x" % (tag, off + i, data[i], mine[i]))
        else:
            print("  ok %-10s +0x%06x (%d bytes)" % (tag, off, len(data)))
        tag = None
print("%d slices, %d mismatches" % (n, bad))
sys.exit(1 if bad else 0)
