#!/usr/bin/env python3
"""Writes the three Monster Maulers MRAs (mra/*.mra) from a MAME mmaulers.zip.

The image layout is the one target/mister/mm_mem.sv loads (docs/mister-memory.md):
the regions in the order below, 0x1640000 bytes. The default EEPROM is a
separate download (index 2): the HPS then also saves and restores it
(<nvram index="2">), so the game's settings and records persist.

    python tools/make_mra.py "/path/to/MAME 0.289 ROMs (merged)/mmaulers.zip"
"""
import sys, zipfile, os

SETS = [
    # setname, title, region, program ROM names, nvram file inside the zip
    ("mmaulers",  "Monster Maulers (World ver EAA)", "World", ("170eaa07.24m", "170eaa09.19l"), "mmaulers.nv"),
    ("mmaulersu", "Monster Maulers (USA ver UAA)",   "USA",   ("170uaa07.24m", "170uaa09.19l"), "mmaulersu/mmaulersu.nv"),
    ("dadandrn",  "Kyukyoku Sentai Dadandarn (Japan ver JAA)", "Japan", ("170jaa07.24m", "170jaa09.19l"), "dadandrn/dadandrn.nv"),
]
CRC = {   # the files of the merged set, by base name (MAME 0.289 mystwarr.cpp)
    "170a02.34j": "b040cebf", "170a03.36m": "7fb412b2",
    "170a04.33n": "64b9a73b", "170a05.30n": "f2c101d0", "170a06.27n": "b032e59b",
    "170a08.21m": "03c59ba2", "170a10.17l": "8a340909", "170a13.9c": "2ebf4d1c",
    "170a14.2g": "83317cda", "170a15.2m": "d4113ae9",
    "170a16.2t": "41fee912", "170a17.2x": "96957c91", "170a24.5r": "562ad4bd",
    "170a18.36u": "e1e3c8d2", "170a19.34u": "be835141", "170a20.36y": "ccb4d88c", "170a21.34y": "bcb68136",
    "170a22.32y": "21628106", "170a23.29y": "6b5390e4",
    "170eaa07.24m": "5458bd93", "170eaa09.19l": "99c95c7b",
    "170uaa07.24m": "50164e3b", "170uaa09.19l": "f9f161d5",
    "170jaa07.24m": "6a55e828", "170jaa09.19l": "9e821cd8",
}

def hexdump(data):
    lines = []
    for i in range(0, len(data), 16):
        lines.append(" ".join("%02X" % b for b in data[i:i + 16]))
    return "\n".join(lines)

def mra(setname, title, region, prog, nvdata):
    p0, p1 = prog
    return f"""<misterromdescription>
    <rotation>horizontal</rotation>
    <name>{title}</name>
    <setname>{setname}</setname>
    <mameversion>0289</mameversion>
    <year>1993</year>
    <manufacturer>Konami</manufacturer>
    <players>2</players>
    <joystick>8</joystick>
    <rbf>monstermaulers</rbf>
    <region>{region}</region>
    <platform>Konami pre-GX</platform>

    <!--
      Flat image for the Monster Maulers core (target/mister/mm_mem.sv):

        0x0000000  0x200000  68000 program (1.5 MB, zero padded to the 2 MB the map decodes)
        0x0200000  0x040000  Z80 sound program, 16 x 16 KB banks
        0x0240000  0x400000  K056832 tile ROM, 5bpp: per 8-pixel row an 8-byte group
                             (4 chunky bytes, the fifth plane byte, 3 zero)
        0x0640000  0x180000  ROZ characters (gfx3), 8bpp 16x16
        0x07C0000  0x080000  ROZ tile map (gfx4): 256 KB of attributes, then 256 KB of tile low bytes
        0x0840000  0x400000  K054539 PCM
        0x0C40000  0x800000  K055673 sprite ROM, 64-bit words: a 16-pixel row of the four low planes
        0x1440000  0x200000  K055673 fifth plane, a 16-bit word per row (left 8 pixels, right 8)
        0x1640000            end

      Expects the MAME 0.289 merged romset (mmaulers.zip holding the parent and the
      two clones) or the split sets: parts are found by name, whatever folder holds them.
    -->
    <rom index="0" zip="{setname}.zip|mmaulers.zip" md5="None">

        <!-- 68000 program, 16-bit big-endian words: the even byte is the first ROM -->
        <interleave output="16">
            <part name="{p0}" crc="{CRC[p0]}" map="01"/>
            <part name="{p1}" crc="{CRC[p1]}" map="10"/>
        </interleave>
        <interleave output="16">
            <part name="170a08.21m" crc="{CRC['170a08.21m']}" map="01"/>
            <part name="170a10.17l" crc="{CRC['170a10.17l']}" map="10"/>
        </interleave>
        <part repeat="0x80000">00</part>

        <!-- Z80 sound program -->
        <part name="170a13.9c" crc="{CRC['170a13.9c']}"/>

        <!--
          K056832 tile ROM. MAME's ROM_LOADTILE_WORD is ROM_GROUPWORD|ROM_SKIP(3)|ROM_REVERSE
          and ROM_LOADTILE_BYTE is ROM_GROUPBYTE|ROM_SKIP(4): 5-byte groups, one per 8-pixel
          row, 4 packed-chunky bytes (the low 4 bits of the pixel) and the 5th plane's byte,
          which holds bit 4 of each of the row's 8 pixels (pixel 0 in bit 7). Padded to 8 bytes.
        -->
        <interleave output="64">
            <part name="170a16.2t" crc="{CRC['170a16.2t']}" map="00000012"/>
            <part name="170a17.2x" crc="{CRC['170a17.2x']}" map="00001200"/>
            <part name="170a24.5r" crc="{CRC['170a24.5r']}" map="00010000"/>
        </interleave>

        <!-- ROZ character ROM (gfx3), 8bpp 16x16, one byte a pixel -->
        <part name="170a04.33n" crc="{CRC['170a04.33n']}"/>
        <part name="170a05.30n" crc="{CRC['170a05.30n']}"/>
        <part name="170a06.27n" crc="{CRC['170a06.27n']}"/>

        <!-- ROZ tilemap ROM (gfx4): per tile, an attribute byte (flip, tile bits 12:8) and the tile's low byte -->
        <part name="170a02.34j" crc="{CRC['170a02.34j']}"/>
        <part name="170a03.36m" crc="{CRC['170a03.36m']}"/>

        <!-- K054539 PCM samples, shared by both chips -->
        <part name="170a14.2g" crc="{CRC['170a14.2g']}"/>
        <part name="170a15.2m" crc="{CRC['170a15.2m']}"/>

        <!--
          K055673 sprite ROM, 64-bit words (ROM_LOAD64_WORD, 8-byte stride): one 64-bit word
          is the four low planes of one 16-pixel row (left 8 pixels in bytes 0-3, right 8 in
          bytes 4-7, one byte a plane).
        -->
        <interleave output="64">
            <part name="170a19.34u" crc="{CRC['170a19.34u']}" map="00000021"/>
            <part name="170a21.34y" crc="{CRC['170a21.34y']}" map="00002100"/>
            <part name="170a18.36u" crc="{CRC['170a18.36u']}" map="00210000"/>
            <part name="170a20.36y" crc="{CRC['170a20.36y']}" map="21000000"/>
        </interleave>
        <!-- the fifth plane (ROM_LOAD16_BYTE at 0x800000): per row, the left and the right 8 pixels' byte -->
        <interleave output="16">
            <part name="170a23.29y" crc="{CRC['170a23.29y']}" map="01"/>
            <part name="170a22.32y" crc="{CRC['170a22.32y']}" map="10"/>
        </interleave>
    </rom>

    <!-- the board's factory EEPROM: without it the game boots upside down with an error -->
    <rom index="2">
        <part>
{hexdump(nvdata)}
        </part>
    </rom>
    <nvram index="2" size="128"/>

    <buttons names="Button 1,Button 2,Button 3,Start,Coin" default="A,B,R,Start,Select" count="3"/>
</misterromdescription>
"""

def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    z = zipfile.ZipFile(sys.argv[1])
    names = {os.path.basename(i.filename): i for i in z.infolist()}
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mra")
    os.makedirs(out, exist_ok=True)
    for base, want in CRC.items():
        if base in names and ("%08x" % names[base].CRC) != want:
            raise SystemExit("%s: crc %08x, expected %s" % (base, names[base].CRC, want))
    for setname, title, region, prog, nv in SETS:
        info = z.getinfo(nv)
        data = z.read(nv)
        assert len(data) == 128, (nv, len(data))
        for n in prog:
            assert ("%08x" % names[n].CRC) == CRC[n], (n, "%08x" % names[n].CRC, CRC[n])
        path = os.path.join(out, title + ".mra")
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(mra(setname, title, region, prog, data))
        print("wrote", os.path.normpath(path), "(nvram crc %08x)" % info.CRC)

if __name__ == "__main__":
    sys.exit(main())
