#!/usr/bin/env python3
"""Build the release zip in MiSTer's SD card structure from the repository:

  _Arcade/<title>.mra                              the three MRAs              (mra/*.mra)
  _Arcade/cores/monstermaulers_<YYYYMMDD>.rbf      the core                    (releases/monstermaulers_<YYYYMMDD>.rbf)

  python tools/package.py [YYYYMMDD]        (default: the newest RBF in releases/)

Writes dist/MonsterMaulers_MiSTer_<YYYYMMDD>.zip (dist/ is not in the repository: attach the zip to the GitHub release). Unzip it
over the root of the SD card. No ROMs are in it: the MAME 0.289 romset (mmaulers.zip) goes to /media/fat/games/mame/.
"""
import glob
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DIST = os.path.join(REPO, 'dist')


def main(argv):
    rbfs = sorted(glob.glob(os.path.join(REPO, 'releases', 'monstermaulers_*.rbf')))
    rbfs = [r for r in rbfs if re.search(r'monstermaulers_\d{8}\.rbf$', r)]
    if argv:
        rbfs = [r for r in rbfs if r.endswith('monstermaulers_%s.rbf' % argv[0])]
    if not rbfs:
        print('no releases/monstermaulers_YYYYMMDD.rbf')
        return 1
    rbf = rbfs[-1]
    date = re.search(r'monstermaulers_(\d{8})\.rbf$', rbf).group(1)
    mras = sorted(glob.glob(os.path.join(REPO, 'mra', '*.mra')), key=lambda p: os.path.basename(p).lower())
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, 'MonsterMaulers_MiSTer_%s.zip' % date)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for full in mras:
            z.write(full, '_Arcade/' + os.path.basename(full))
        z.write(rbf, '_Arcade/cores/' + os.path.basename(rbf))
    print('%s: %d MRAs + %s' % (out, len(mras), os.path.basename(rbf)))
    with zipfile.ZipFile(out) as z:
        for n in z.namelist():
            print('  ' + n)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
