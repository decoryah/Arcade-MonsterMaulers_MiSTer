#!/bin/sh
# Chip-level K054539 gate: builds tb_k539 and replays a MAME register log (tools/lua/k539_log.lua)
#   sim/run_k539.sh <image.rom> <writes.txt> <first sample> <last sample> <out.bin> [clocks per sample]
# Environment: SRC=<k054539.sv to build, default ../rtl/k054539.sv>, OBJ=<build dir, default obj_k539>
set -e
cd "$(dirname "$0")"
OBJ=${OBJ:-obj_k539}
SRC=${SRC:-../rtl/k054539.sv}
verilator --cc --exe --build -j ${JOBS:-8} -O2 -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
    -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-LATCH -Wno-UNSIGNED \
    --top-module tb_k539_top --prefix Vtb_k539_top -Mdir $OBJ \
    "$SRC" tb_k539_top.sv tb_k539.cpp > $OBJ.log 2>&1 || { grep -E "%Error|error:" $OBJ.log | head -20; tail -5 $OBJ.log; exit 1; }
case "$OBJ" in /*) EXE="$OBJ/Vtb_k539_top" ;; *) EXE="./$OBJ/Vtb_k539_top" ;; esac
"$EXE" "$1" "$2" "$3" "$4" "$5" ${6:-600} ${7:-48000}
