#!/bin/bash
# Waits for the live Fmax census to release rtl/, then banks the equivalence-proven
# shallower pkt_token_meter_color cone: regenerate the packet family only, run the
# family gate with mutations, rebuild group 3 alone. Fails closed on any gate error.
cd /d/sipeedTANG20K/cores/acceleration/operator_library/tools || exit 1
LOG=../evidence/apply_packet_fix.log
say(){ echo "[$(date -u +%H:%M:%SZ)] $*" | tee -a "$LOG"; }
say "waiting for census to finish"
for i in $(seq 1 120); do
  [ -f ../evidence/fmax_census_cens2/census.json ] && break
  sleep 30
done
[ -f ../evidence/fmax_census_cens2/census.json ] || { say "FAIL census never completed"; exit 1; }
say "census ready, regenerating family packet"
python -u generate.py --family packet >>"$LOG" 2>&1 || { say "FAIL generate"; exit 1; }
grep -c "raw32 = " ../rtl/acc_pkt_token_meter_color.v | xargs -I{} say "new cone present in rtl: {} line(s)"
say "running family packet gate with mutations"
python -u verify.py --family packet --mutations >>"$LOG" 2>&1 || { say "FAIL verify packet"; exit 1; }
say "rebuilding group 3"
python -u build.py --groups 3 --stamp fin_g3 >>"$LOG" 2>&1 && say "GROUP 3 BUILD PASS" || say "GROUP 3 BUILD STILL BELOW GATE"
python - <<'PY' >>"$LOG" 2>&1
import json,glob
for d in sorted(glob.glob('../evidence/build_fin_g3')):
    for r in json.load(open(d+'/summary.json')).get('groups',[]):
        print('FIN g%s route=%s fmax=%s lut=%s'%(r['group'],r['route'],
              r.get('max_frequency_mhz'),r['lut_class']))
PY
say "chain done"
