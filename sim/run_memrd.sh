#!/bin/sh
# Memory-subsystem gate (target/mister/mm_mem.sv behind behavioural SDRAM and Avalon DDR3): the image through the
# loader (or BACKDOOR=1: straight into the chips), then every region read back through the machine's ports.
#   sim/run_memrd.sh <image.rom> [reads per port, default 20000]
# Environment: BACKDOOR=1, SEED=n, OBJ=<build dir> (default obj_memrd)
set -e
cd "$(dirname "$0")"
ROM="$1"; [ -f "$ROM" ] || { echo "usage: $0 <image.rom> [reads]" >&2; exit 2; }
case "$ROM" in /*) ;; *) ROM="$PWD/$ROM" ;; esac
OBJ=${OBJ:-obj_memrd}
verilator --cc --exe --build -j ${JOBS:-8} -O2 -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY \
    -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-LATCH -Wno-UNSIGNED -Wno-CMPCONST \
    --top-module tb_memrd_top --prefix Vtb_memrd_top -Mdir $OBJ \
    ../target/mister/mm_mem.sv ../target/mister/rom_cache.sv ../target/mister/mem_test.sv ../target/mister/sdram_ctrl.sv ../target/mister/ddr_arb.sv \
    sdram_model.sv ddr_model.sv tb_memrd_top.sv tb_memrd.cpp > $OBJ.log 2>&1 || { grep -E "%Error|error:" $OBJ.log | head -20; tail -5 $OBJ.log; exit 1; }
case "$OBJ" in /*) EXE="$OBJ/Vtb_memrd_top" ;; *) EXE="./$OBJ/Vtb_memrd_top" ;; esac
"$EXE" "$ROM" ${2:-20000}
