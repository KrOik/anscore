#!/bin/bash
# Resumable driver for the 150-core release.
#
# Stage 1: synthesize in isolation the cores that still have no measured size
# (arith/cordic_rotate, the fft family, the netio family), because deal.py
# refuses to lay out groups until every pending core has one.
# Stage 2: hand everything after that to integrate.py --from deal, which runs
# deal -> generateall -> selftest -> coresim -> harness -> groupbuild, and keep
# boardwatch armed so the accepted bitstreams get programmed and compared.
#
# It only sequences the existing tools; every gate stays inside those tools.
cd "$(dirname "$0")" || exit 1
export PATH="/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/bin:/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/lib:$PATH"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOG=../evidence/resume_150.log
DRV=../evidence/integrate_console_run2.log

say() { echo "$(date -u +%FT%TZ) $*" >>"$LOG"; }

alive() {
  for p in /proc/[0-9]*/cmdline; do
    c=$(tr '\0' ' ' <"$p" 2>/dev/null || true)
    case "$c" in *"$1"*) return 0 ;; esac
  done
  return 1
}

say "resume start stamp=$STAMP"
for f in arith fft netio; do
  nohup python -u build.py --isolated --family "$f" --no-groups \
       --stamp "iso_${f}_${STAMP}" > "../evidence/resume_iso_${f}_${STAMP}.log" 2>&1 &
  say "isolated $f pid $!"
done

# Stage 1 is done when deal.py stops refusing, which is the same question the
# synthesis jobs answer but checked against the artifact deal actually reads.
while :; do
  sleep 120
  if ! alive "build.py --isolated"; then
    break
  fi
done
say "isolated jobs exited"
for f in arith fft netio; do
  n=$(python - <<PY 2>>"$LOG" || echo 0
import json,glob,os
ds=sorted(glob.glob('../evidence/build_iso_${f}_$STAMP/summary.json'))
if not ds: print(0)
else:
    s=json.load(open(ds[-1],encoding='utf-8'))
    syn=s.get('synthesis',{})
    print(len(syn) if hasattr(syn,'__len__') else 0)
PY
)
  say "iso summary $f entries=$n"
done
say "deal preflight:"
python deal.py >>"$LOG" 2>&1
say "deal rc=$?"

nohup python -u integrate.py --from deal --deadline 21600 --workers 3 >>"$DRV" 2>&1 &
say "integrate --from deal launched"

# Watchdog: keep the driver and the board stage alive until the release passes.
for _ in $(seq 1 380); do
  sleep 120
  if grep -qa "INTEGRATION PASS" "$DRV" 2>/dev/null; then
    say "integration passed; driver left running for the board stage"
  elif ! alive integrate.py; then
    nohup python -u integrate.py --from deal --deadline 21600 --workers 3 >>"$DRV" 2>&1 &
    say "integrate dead: relaunched --from deal"
  fi
  if ! alive boardwatch.py; then
    nohup python -u boardwatch.py --wait 21600 >>../evidence/boardwatch_console_resume.log 2>&1 &
    say "boardwatch dead: relaunched --wait 21600"
  fi
done
say "watchdog window exhausted"
