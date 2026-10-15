#!/bin/bash
# Post-synthesis netlist simulation of cnn_engine against golden digest.
set -e
cd /d/sipeedTANG20K
export PATH="/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/bin:/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/lib:$PATH"
B=cores/acceleration/cnn_inference/build_oss
yosys -Q -T -p "read_json $B/top.json; write_verilog -norename $B/netlist.v"
iverilog -g2012 -o $B/netlist_sim.vvp \
    cores/acceleration/cnn_inference/sim/tb_cnn_engine.v \
    $B/netlist.v \
    tools/oss-cad-suite/oss-cad-suite/share/yosys/gowin/cells_sim.v \
    tools/oss-cad-suite/oss-cad-suite/share/yosys/gowin/cells_xtra_gw5a.v 2>&1 | grep -iv warning | head -8
vvp $B/netlist_sim.vvp 2>&1 | tail -4
