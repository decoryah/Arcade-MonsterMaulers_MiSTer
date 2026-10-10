#!/usr/bin/env python3
"""Compare two state dumps (MAME's tools/lua/dump_state.lua and the system bench's DUMPSTATE).

    cmp_state.py rtl.state_400.txt mame.state_400.txt [section ...]

Per section: the number of words that differ and the first few (index: rtl / mame). Sections not in both files
are skipped; "CURPAGE" and "ROZCTRL" exist only on MAME's side."""
import sys


def load(path):
    d = {}
    for line in open(path):
        if line.startswith('#') or not line.strip():
            continue
        parts = line.split()
        key = parts[0]
        if key == 'VRAM':
            key = 'VRAM %s' % parts[1]
            parts = parts[1:]
        d[key] = [int(x, 16) for x in parts[1:]]
    return d


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    a, b = load(sys.argv[1]), load(sys.argv[2])
    only = sys.argv[3:]
    total = 0
    for key in a:
        if key not in b or key in ('FRAME',) or (only and key not in only and key.split()[0] not in only):
            continue
        x, y = a[key], b[key]
        n = min(len(x), len(y))
        diff = [i for i in range(n) if x[i] != y[i]]
        total += len(diff)
        if diff:
            show = ', '.join('%d: %04x/%04x' % (i, x[i], y[i]) for i in diff[:6])
            print('%-10s %5d of %d differ  (%s%s)' % (key, len(diff), n, show, ', ...' if len(diff) > 6 else ''))
        else:
            print('%-10s same (%d words)' % (key, n))
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main())
