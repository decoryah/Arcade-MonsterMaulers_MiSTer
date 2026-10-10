#!/usr/bin/env python3
"""Package a finished Quartus build as a release: copy the RBF to releases/monstermaulers_<YYYYMMDD>.rbf together with the fitter's
and the timing analyser's summaries (releases/monstermaulers_<YYYYMMDD>.fit.summary / .sta.summary) and the RAM depth report of
tools/check_ram_depth.py (.ram_depths.txt), and print the numbers. MiSTer finds the core by the MRAs' <rbf> name (monstermaulers)
plus the date in the file name, so keep both.

  python tools/release.py [YYYYMMDD]        (default: today)

Older RBFs in releases/ are left alone (remove them by hand; the releases folder holds the tested build). Exit status 1 if any
slack is negative or the RAM depth report has a problem.
"""
import datetime
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
OUT = os.path.join(REPO, 'output_files')
REL = os.path.join(REPO, 'releases')


def kv(path):
    d = {}
    for line in open(path, errors='replace'):
        if ' : ' in line:
            k, v = line.split(' : ', 1)
            d[k.strip()] = v.strip()
    return d


def main(argv):
    date = argv[0] if argv else datetime.date.today().strftime('%Y%m%d')
    rbf = os.path.join(OUT, 'MonsterMaulers.rbf')
    if not os.path.exists(rbf):
        print('no RBF: the build has not finished')
        return 1
    os.makedirs(REL, exist_ok=True)
    stem = os.path.join(REL, 'monstermaulers_%s' % date)
    shutil.copyfile(rbf, stem + '.rbf')
    shutil.copyfile(os.path.join(OUT, 'MonsterMaulers.fit.summary'), stem + '.fit.summary')
    shutil.copyfile(os.path.join(OUT, 'MonsterMaulers.sta.summary'), stem + '.sta.summary')
    depth = subprocess.run([sys.executable, os.path.join(HERE, 'check_ram_depth.py'), os.path.join(OUT, 'MonsterMaulers.fit.rpt')],
                           stdout=subprocess.PIPE, universal_newlines=True)
    open(stem + '.ram_depths.txt', 'w').write(depth.stdout)
    fit = kv(stem + '.fit.summary')
    worst, cur = {}, None
    for line in open(stem + '.sta.summary', errors='replace'):
        m = re.match(r"Type\s*:\s*(\w[\w ]*?) '(.*)'", line)
        if m:
            cur = (m.group(1), m.group(2))
        m = re.match(r'Slack\s*:\s*(-?[\d.]+)', line)
        if m and cur:
            worst[cur] = float(m.group(1))
    neg = {k: v for k, v in worst.items() if v < 0}
    tight = sorted(worst.items(), key=lambda kv_: kv_[1])[:5]
    print('release %s: %s (%d bytes)' % (date, os.path.basename(stem + '.rbf'), os.path.getsize(stem + '.rbf')))
    print('Quartus %s, fitter %s' % (fit.get('Quartus Prime Version', '?'), fit.get('Fitter Status', '?')))
    print('Logic %s, RAM blocks %s, DSP %s, PLLs %s' % (fit.get('Logic utilization (in ALMs)', '?'), fit.get('Total RAM Blocks', '?'),
                                                         fit.get('Total DSP Blocks', '?'), fit.get('Total PLLs', '?')))
    print('Timing: %d slack entries, %d negative' % (len(worst), len(neg)))
    print('Tightest: ' + '; '.join('%s %s %.3f ns' % (t, c.split('|')[1] if '|' in c else c, s) for (t, c), s in tight))
    print('RAM depths: ' + (depth.stdout.strip().splitlines() or ['?'])[-1])
    return 1 if (neg or depth.returncode) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
