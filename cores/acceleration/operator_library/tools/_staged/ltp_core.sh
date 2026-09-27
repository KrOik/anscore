#!/bin/bash
# Isolated per-core timing/size probe for staged rewrites.
#
#   tools/_staged/ltp_core.sh <top> <verilog-file...>
#
# Runs exactly the release flow's synthesis command shape (build.py /
# fmax_census.py use `synth_gowin -family gw5a -noalu`) on ONE isolated core,
# then reports `ltp -noff` logic levels and the LUT-class cell tally.
# Every artifact goes to /tmp only; nothing in this repository is written.
# Output is piped through `tr -d '\000'` because the yosys logs on this box
# carry NUL bytes that break grep.
set -u
TOP="$1"; shift
OUT=/tmp/ltp_$TOP
mkdir -p "$OUT"
export PATH="/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/bin:/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/lib:$PATH"
CELLS=D:/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/share/yosys/gowin/cells_xtra_gw5a.v
{
  echo "read_verilog -lib $CELLS"
  for f in "$@"; do echo "read_verilog $f"; done
  echo "hierarchy -top $TOP"
  echo "synth_gowin -family gw5a -noalu -top $TOP"
  echo "ltp -noff"
  echo "stat"
} > "$OUT/$TOP.ys"
yosys -s "$OUT/$TOP.ys" 2>&1 | tr -d '\000' > "$OUT/$TOP.log"
echo "== $TOP =="
grep -aE "Longest topological" "$OUT/$TOP.log"
grep -aE "^ +[0-9]+ +(LUT[0-9]|MUX[0-9]_LUT[0-9]|DFF[CE]?[PN]*[0-9_]*|IBUF|OBUF|GND|VCC)$" \
    "$OUT/$TOP.log" | tail -14
echo "log: $OUT/$TOP.log"
