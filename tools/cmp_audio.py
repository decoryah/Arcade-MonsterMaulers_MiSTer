#!/usr/bin/env python3
"""Compare the core's audio with MAME's: two 16-bit stereo WAVs (48 kHz).

    cmp_audio.py rtl.wav mame.wav [seconds]

Prints each file's length, peak and RMS, then, in 0.5 s steps, the two RMS levels per channel and their ratio, and
the correlation of the two RMS envelopes (20 ms windows) at lag 0 and at the best lag within +-0.5 s.  Levels
within ~1 dB and a lag near 0 mean the sound chips and their mixing agree; a constant ratio is a gain error."""
import array
import math
import sys
import wave


def load(path):
    with wave.open(path, "rb") as w:
        assert w.getsampwidth() == 2 and w.getnchannels() == 2, "16-bit stereo WAV expected"
        rate = w.getframerate()
        a = array.array("h")
        a.frombytes(w.readframes(w.getnframes()))
    return rate, a[0::2], a[1::2]


def rms(x, i, n):
    s = 0
    for k in range(i, min(i + n, len(x))):
        s += x[k] * x[k]
    return math.sqrt(s / max(1, min(n, len(x) - i)))


def db(r):
    return 20 * math.log10(r) if r > 0 else -99.0


def env(l, r, win):
    return [(rms(l, i, win) + rms(r, i, win)) / 2 for i in range(0, len(l) - win + 1, win)]


def pearson(a, b):
    n = min(len(a), len(b))
    if n < 2:
        return 0.0
    a, b = a[:n], b[:n]
    ma, mb = sum(a) / n, sum(b) / n
    sa = math.sqrt(sum((x - ma) ** 2 for x in a))
    sb = math.sqrt(sum((x - mb) ** 2 for x in b))
    if sa == 0 or sb == 0:
        return 0.0
    return sum((x - ma) * (y - mb) for x, y in zip(a, b)) / (sa * sb)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    ra, la, ar = load(sys.argv[1])
    rb, lb, br = load(sys.argv[2])
    assert ra == rb, "sample rates differ: %d vs %d" % (ra, rb)
    limit = int(float(sys.argv[3]) * ra) if len(sys.argv) > 3 else min(len(la), len(lb))
    n = min(limit, len(la), len(lb))
    la, ar, lb, br = la[:n], ar[:n], lb[:n], br[:n]
    print("rtl : %.2f s, peak L %d R %d, rms L %.0f R %.0f" % (len(la) / ra, max(map(abs, la)), max(map(abs, ar)), rms(la, 0, n), rms(ar, 0, n)))
    print("mame: %.2f s, peak L %d R %d, rms L %.0f R %.0f" % (len(lb) / ra, max(map(abs, lb)), max(map(abs, br)), rms(lb, 0, n), rms(br, 0, n)))
    step = ra // 2
    print("\n   t(s)   rtl L    rtl R   mame L   mame R    L dB   R dB")
    for i in range(0, n - step + 1, step):
        a_l, a_r, b_l, b_r = rms(la, i, step), rms(ar, i, step), rms(lb, i, step), rms(br, i, step)
        if max(a_l, a_r, b_l, b_r) < 8:
            continue
        dl = db(a_l) - db(b_l) if a_l > 0 and b_l > 0 else float("nan")
        dr = db(a_r) - db(b_r) if a_r > 0 and b_r > 0 else float("nan")
        print("%7.1f %8.0f %8.0f %8.0f %8.0f %6.1f %6.1f" % (i / ra, a_l, a_r, b_l, b_r, dl, dr))
    win = ra // 50
    ea, eb = env(la, ar, win), env(lb, br, win)
    c0 = pearson(ea, eb)
    best, bl = c0, 0
    for lag in range(-25, 26):
        c = pearson(ea[max(0, lag):], eb[max(0, -lag):]) if lag else c0
        if c > best:
            best, bl = c, lag
    print("\nenvelope correlation: lag 0 %.3f; best %.3f at %+d windows (%+d ms)" % (c0, best, bl, bl * 20))
    return 0


if __name__ == "__main__":
    sys.exit(main())
