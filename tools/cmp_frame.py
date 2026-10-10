#!/usr/bin/env python3
"""Compare an RTL frame dump (tb_frame / the system bench: 32-bit little-endian
0x00RRGGBB, 288 x 224) with a MAME snapshot PNG.

    python tools/cmp_frame.py rtl.rgb mame.png [out_diff.png] [--w 288 --h 224]

Prints the number of differing pixels, their bounding box, the largest channel
error, and a histogram of what differs. Exits 1 on any difference.
"""
import sys, struct, zlib

def read_png(path):
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos = 8; idat = b""; w = h = bd = ct = None
    while pos < len(d):
        n, t = struct.unpack(">I4s", d[pos:pos + 8])
        body = d[pos + 8: pos + 8 + n]; pos += 12 + n
        if t == b"IHDR": w, h, bd, ct, _, _, il = struct.unpack(">IIBBBBB", body); assert il == 0 and bd == 8
        elif t == b"IDAT": idat += body
        elif t == b"IEND": break
    ch = {2: 3, 6: 4}[ct]
    raw = zlib.decompress(idat)
    stride = w * ch
    out = bytearray(); prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]; line = bytearray(raw[p + 1: p + 1 + stride]); p += 1 + stride
        for i in range(stride):
            a = line[i - ch] if i >= ch else 0
            b = prev[i]
            c = prev[i - ch] if i >= ch else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif f == 4:
                pa = abs(b - c); pb = abs(a - c); pc = abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        out += line; prev = line
    pix = []
    for i in range(w * h):
        o = i * ch
        pix.append((out[o] << 16) | (out[o + 1] << 8) | out[o + 2])
    return w, h, pix

def write_png(path, w, h, rgb):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            v = rgb[y * w + x]
            raw += bytes(((v >> 16) & 255, (v >> 8) & 255, v & 255))
    def chunk(t, b):
        c = struct.pack(">I", len(b)) + t + b
        return c + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    W, H = 288, 224
    if "--w" in sys.argv: W = int(sys.argv[sys.argv.index("--w") + 1]); args = [a for a in args if a != str(W)]
    rtl = open(args[0], "rb").read()
    n = len(rtl) // 4
    a = struct.unpack("<%dI" % n, rtl[:n * 4])
    mw, mh, b = read_png(args[1])
    if (mw, mh) != (W, H):
        # MAME's snapshot may be larger than the visible area: crop from the top left
        b = [b[y * mw + x] for y in range(min(mh, H)) for x in range(min(mw, W))]
    bad = 0; xs = []; ys = []; maxe = 0; hist = {}
    diff = [0] * (W * H)
    for i in range(W * H):
        if a[i] & 0xffffff != b[i]:
            bad += 1; x, y = i % W, i // W; xs.append(x); ys.append(y)
            e = max(abs(((a[i] >> s) & 255) - ((b[i] >> s) & 255)) for s in (0, 8, 16))
            maxe = max(maxe, e); hist[e] = hist.get(e, 0) + 1
            diff[i] = 0xff0000
        else:
            diff[i] = (b[i] >> 1) & 0x7f7f7f
    if len(args) > 2:
        write_png(args[2], W, H, diff)
    if bad == 0:
        print("IDENTICAL (%d pixels)" % (W * H)); return 0
    print("%d of %d pixels differ; bbox x %d..%d y %d..%d; max channel error %d" % (bad, W * H, min(xs), max(xs), min(ys), max(ys), maxe))
    small = sum(v for k, v in hist.items() if k <= 2)
    print("  errors <= 2: %d pixels; > 2: %d pixels" % (small, bad - small))
    return 1

if __name__ == "__main__":
    sys.exit(main())
