#!/usr/bin/env python3
"""Compare tb_k539's output with MAME's own wav of the same game.

    k539_cmp.py <chips.bin> <mame.wav> <first sample> [lag]

chips.bin holds int16 l1 r1 l2 r2 per sample from <first sample> (tb_k539). MAME's stream is the two chips'
sum with each chip's output 0 on the right speaker (mm_sound.sv); its level is also scaled by the K054321's
volume, which the bench leaves out, so one least-squares gain is fitted over the whole span. Prints, per
second: the correlation of the two, the residual's RMS as a share of MAME's RMS, and the share of the
residual's energy above 4 kHz (a wrongly decoded sample shows up there).
"""
import array
import math
import sys
import wave


def sat(v):
    return 32767 if v > 32767 else (-32768 if v < -32768 else v)


def main():
    first = int(sys.argv[3])
    lag = int(sys.argv[4]) if len(sys.argv) > 4 else 0   # MAME's stream trails the log by about 389 samples
    a = array.array("h")
    a.frombytes(open(sys.argv[1], "rb").read())
    n = len(a) // 4
    w = wave.open(sys.argv[2], "rb")
    w.setpos(first + lag)
    m = array.array("h")
    m.frombytes(w.readframes(n))
    ml = m[0::2]
    mr = m[1::2]
    n = min(n, len(ml))
    # RTL mix: L = r1 + r2, R = l1 + l2
    rl = [sat(a[4 * i + 1] + a[4 * i + 3]) for i in range(n)]
    rr = [sat(a[4 * i] + a[4 * i + 2]) for i in range(n)]
    num = sum(rl[i] * ml[i] + rr[i] * mr[i] for i in range(n))
    den = sum(rl[i] * rl[i] + rr[i] * rr[i] for i in range(n)) or 1
    g = num / den
    print("fitted gain %.4f over %d samples (%.1f s)" % (g, n, n / 48000.0))
    print(" sec  corr   resid/mame   resid>4k%   mame_rms")
    sec = 48000
    worst = []
    for s in range(0, n // sec):
        lo, hi = s * sec, (s + 1) * sec
        sxy = sxx = syy = ee = hf = 0.0
        pe = 0.0
        for i in range(lo, hi):
            x = rl[i] * g
            y = ml[i]
            e = x - y
            sxy += x * y; sxx += x * x; syy += y * y; ee += e * e
            d = e - pe
            hf += d * d
            pe = e
        corr = sxy / math.sqrt(sxx * syy + 1e-9)
        rs = math.sqrt(ee / sec)
        ms = math.sqrt(syy / sec)
        # energy of the first difference approximates the share above ~4 kHz
        hfs = 100.0 * hf / (4.0 * ee + 1e-9)
        print("%4d  %.3f  %8.3f   %8.1f   %8.0f" % (first // sec + s, corr, rs / (ms + 1e-9), min(hfs, 100.0), ms))
        worst.append((rs / (ms + 1e-9), first // sec + s))
    worst.sort(reverse=True)
    print("worst seconds:", ", ".join("%ds %.2f" % (t, r) for r, t in worst[:5]))


if __name__ == "__main__":
    main()
