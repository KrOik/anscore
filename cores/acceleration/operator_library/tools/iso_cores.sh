#!/bin/bash
# Measure the netio cores still lacking an isolated-synthesis size. Sequential
# on purpose: oversubscription is what made whole-family runs hit the 1200 s
# per-command synthesis timeout before.
cd "$(dirname "$0")" || exit 1
export PATH="/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/bin:/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/lib:$PATH"
LOG=../evidence/iso_cores.log
for c in countmin_update hll_reg_update bitmap_scan radix_tree_step pacing_wf2q; do
  echo "$(date -u +%FT%TZ) start $c" >>"$LOG"
  python -u build.py --isolated --isolated-core "$c" --no-groups --stamp "ic_${c}_1853" \
      >>"$LOG" 2>&1
  echo "$(date -u +%FT%TZ) done $c rc=$?" >>"$LOG"
done
echo "$(date -u +%FT%TZ) all measured" >>"$LOG"
