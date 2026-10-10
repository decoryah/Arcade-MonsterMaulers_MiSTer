#!/usr/bin/env python3
"""MAME's memory regions for Monster Maulers, rebuilt byte for byte from a romset, and
the check that an image built from an .mra (tools/mra_build.py) holds them in the
layout target/mister/mm_mem.sv expects.

The regions follow ROM_START( mmaulers ) in MAME 0.289 src/mame/konami/mystwarr.cpp:

    maincpu   0x400000   ROM_LOAD16_BYTE  07/09 at 0x000000, 08/10 at 0x100000
    soundcpu  0x040000
    k056832   0x600000   ROM_LOADTILE_WORD (GROUPWORD | SKIP(3) | REVERSE) x2, ROM_LOADTILE_BYTE (SKIP(4))
    k055673   0xa00000   ROM_LOAD64_WORD x4, ROM_LOAD16_BYTE x2 at 0x800000
    gfx3      0x180000   ROZ characters
    gfx4      0x080000   ROZ tile map
    k054539   0x400000   PCM

    python tools/mm_rom.py mmaulers.zip [image.rom]    # verifies the image if given
"""
import sys, zipfile, os, zlib, hashlib

SETS = {
    "mmaulers":  ("170eaa07.24m", "170eaa09.19l"),
    "mmaulersu": ("170uaa07.24m", "170uaa09.19l"),
    "dadandrn":  ("170jaa07.24m", "170jaa09.19l"),
}
CRC = {
    "170a02.34j": 0xb040cebf, "170a03.36m": 0x7fb412b2,
    "170a04.33n": 0x64b9a73b, "170a05.30n": 0xf2c101d0, "170a06.27n": 0xb032e59b,
    "170a08.21m": 0x03c59ba2, "170a10.17l": 0x8a340909, "170a13.9c": 0x2ebf4d1c,
    "170a14.2g": 0x83317cda, "170a15.2m": 0xd4113ae9,
    "170a16.2t": 0x41fee912, "170a17.2x": 0x96957c91, "170a24.5r": 0x562ad4bd,
    "170a18.36u": 0xe1e3c8d2, "170a19.34u": 0xbe835141, "170a20.36y": 0xccb4d88c, "170a21.34y": 0xbcb68136,
    "170a22.32y": 0x21628106, "170a23.29y": 0x6b5390e4,
    "170eaa07.24m": 0x5458bd93, "170eaa09.19l": 0x99c95c7b,
    "170uaa07.24m": 0x50164e3b, "170uaa09.19l": 0xf9f161d5,
    "170jaa07.24m": 0x6a55e828, "170jaa09.19l": 0x9e821cd8,
}

# image layout: name -> (offset, size)
IMG = {
    "prog":  (0x0000000, 0x200000),
    "snd":   (0x0200000, 0x040000),
    "tile":  (0x0240000, 0x400000),
    "chr":   (0x0640000, 0x180000),
    "map":   (0x07C0000, 0x080000),
    "pcm":   (0x0840000, 0x400000),
    "spr":   (0x0C40000, 0x800000),
    "spr5":  (0x1440000, 0x200000),
}
IMG_END = 0x1640000


def load_files(path):
    out = {}
    if os.path.isdir(path):
        for root, _, files in os.walk(path):
            for f in files:
                with open(os.path.join(root, f), "rb") as fh:
                    d = fh.read()
                out.setdefault(f.lower(), []).append(d)
    else:
        with zipfile.ZipFile(path) as z:
            for i in z.infolist():
                if not i.is_dir():
                    out.setdefault(os.path.basename(i.filename).lower(), []).append(z.read(i))
    return out


def rom(files, name):
    want = CRC[name]
    for d in files.get(name.lower(), []):
        if zlib.crc32(d) & 0xffffffff == want:
            return d
    raise SystemExit("%s: missing or wrong crc" % name)


def regions(path, setname="mmaulers"):
    files = load_files(path)
    p0, p1 = SETS[setname]
    r = {}
    # maincpu: ROM_LOAD16_BYTE(a, 0x000000) puts the file's bytes at even addresses, (b, 0x000001) at odd
    m = bytearray(0x400000)
    for name, base in ((p0, 0), (p1, 1), ("170a08.21m", 0x100000), ("170a10.17l", 0x100001)):
        d = rom(files, name)
        m[base:base + 2 * len(d):2] = d
    r["maincpu"] = bytes(m)
    r["soundcpu"] = rom(files, "170a13.9c")
    # k056832: 5-byte groups. ROM_LOADTILE_WORD: 16-bit groups, 3 bytes skipped, REVERSE swaps the pair
    t = bytearray(0x600000)
    for name, off in (("170a16.2t", 0), ("170a17.2x", 2)):
        d = rom(files, name)
        n = len(d) // 2
        t[off + 0: off + 5 * n: 5] = d[1::2]       # file byte 2n+1 first (reversed)
        t[off + 1: off + 1 + 5 * n: 5] = d[0::2]
    d = rom(files, "170a24.5r")
    t[4: 4 + 5 * len(d): 5] = d
    r["k056832"] = bytes(t)
    # k055673: ROM_LOAD64_WORD (8-byte stride, 16-bit groups, file order), plane 5 as ROM_LOAD16_BYTE
    s = bytearray(0xa00000)
    for name, off in (("170a19.34u", 0), ("170a21.34y", 2), ("170a18.36u", 4), ("170a20.36y", 6)):
        d = rom(files, name)
        n = len(d) // 2
        s[off + 0: off + 8 * n: 8] = d[0::2]
        s[off + 1: off + 1 + 8 * n: 8] = d[1::2]
    for name, off in (("170a23.29y", 0x800000), ("170a22.32y", 0x800001)):
        d = rom(files, name)
        s[off: off + 2 * len(d): 2] = d
    r["k055673"] = bytes(s)
    r["gfx3"] = rom(files, "170a04.33n") + rom(files, "170a05.30n") + rom(files, "170a06.27n")
    r["gfx4"] = rom(files, "170a02.34j") + rom(files, "170a03.36m")
    r["k054539"] = rom(files, "170a14.2g") + rom(files, "170a15.2m")
    return r


def image(reg):
    """The flat image the core loads, from MAME's regions."""
    img = bytearray(IMG_END)
    def put(name, data):
        off, size = IMG[name]
        assert len(data) <= size, name
        img[off:off + len(data)] = data
    put("prog", reg["maincpu"][:0x180000])
    put("snd", reg["soundcpu"])
    k = reg["k056832"]
    n = 0x80000                                   # 512K groups of 5 bytes
    t = bytearray(n * 8)
    for i in range(4):
        t[i::8] = k[i:5 * n:5]
    t[4::8] = k[4:5 * n:5]
    put("tile", t)
    put("chr", reg["gfx3"]); put("map", reg["gfx4"]); put("pcm", reg["k054539"])
    put("spr", reg["k055673"][:0x800000]); put("spr5", reg["k055673"][0x800000:])
    return bytes(img)


def verify(reg, img):
    exp = image(reg)
    if len(img) != len(exp):
        print("image is %d bytes, expected %d" % (len(img), len(exp)))
        return False
    ok = True
    for name, (off, size) in IMG.items():
        a, b = img[off:off + size], exp[off:off + size]
        if a == b:
            print("  %-5s ok" % name)
        else:
            i = next(i for i in range(size) if a[i] != b[i])
            print("  %-5s MISMATCH at +0x%x (image %02x, MAME %02x)" % (name, i, a[i], b[i]))
            ok = False
    return ok


def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    setname = os.environ.get("MMSET", "mmaulers")
    reg = regions(sys.argv[1], setname)
    for k, v in reg.items():
        print("%-9s %8d bytes  md5 %s" % (k, len(v), hashlib.md5(v).hexdigest()))
    if len(sys.argv) > 2:
        with open(sys.argv[2], "rb") as f:
            ok = verify(reg, f.read())
        print("IMAGE MATCHES MAME'S REGIONS" if ok else "IMAGE DOES NOT MATCH")
        return 0 if ok else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
