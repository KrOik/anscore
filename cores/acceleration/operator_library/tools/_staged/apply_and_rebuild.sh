#!/bin/bash
# Apply staged cone rewrites to the release in one fail-closed pass.
#
#   apply_and_rebuild.sh <family[,family...]> <group[,group...]> [wait_token]
#
# Waits for the live Fmax census (and, if given, a marker file) to finish before
# touching rtl/, because build evidence records source hashes and a regeneration
# racing a synthesis would make that evidence stale in a way nobody could read.
# Then: regenerate only the named families, re-run each family gate with mutation
# catch, and rebuild only the named groups under one stamp.
cd /d/sipeedTANG20K/cores/acceleration/operator_library/tools || exit 1
FAMS=${1:?families}
GRPS=${2:?groups}
TOKEN=${3:-}
LOG=../evidence/apply_and_rebuild.log
say(){ echo "[$(date -u +%H:%M:%SZ)] $*" | tee -a "$LOG"; }

if [ -d ../evidence/fmax_census_cens2 ] && [ ! -f ../evidence/fmax_census_cens2/census.json ]; then
  say "waiting for the census to release rtl/"
  for i in $(seq 1 140); do
    [ -f ../evidence/fmax_census_cens2/census.json ] && break
    sleep 30
  done
  [ -f ../evidence/fmax_census_cens2/census.json ] || { say "FAIL census still running"; exit 1; }
fi
if [ -n "$TOKEN" ] && [ ! -f "$TOKEN" ]; then
  say "waiting for marker $TOKEN"
  for i in $(seq 1 80); do [ -f "$TOKEN" ] && break; sleep 30; done
  [ -f "$TOKEN" ] || { say "FAIL marker never appeared"; exit 1; }
fi

IFS=, read -ra FA <<< "$FAMS"
for f in "${FA[@]}"; do
  say "generate family $f"
  python -u generate.py --family "$f" >>"$LOG" 2>&1 || { say "FAIL generate $f"; exit 1; }
  say "verify family $f with mutations"
  python -u verify.py --family "$f" --mutations >>"$LOG" 2>&1 || { say "FAIL verify $f"; exit 1; }
done
say "rebuild groups $GRPS"
python -u build.py --groups "$GRPS" --stamp fin_all >>"$LOG" 2>&1 && say "REBUILD PASS" \
  || say "REBUILD STILL BELOW GATE (see log)"
python - <<PY >>"$LOG" 2>&1
import json
for r in json.load(open('../evidence/build_fin_all/summary.json')).get('groups', []):
    print('FIN g%s route=%s fmax=%s lut=%s' % (r['group'], r['route'],
          r.get('max_frequency_mhz'), r['lut_class']))
PY
say "done"
