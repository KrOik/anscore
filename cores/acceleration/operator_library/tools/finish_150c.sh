#!/bin/bash
# Resume the 150-core release from the last unmeasured core. Steps 1-2 of
# finish_150.sh (regenerate netio, verify 10/10) already PASSED at 19:13Z, so
# this chain starts at bloom4_update's isolated synthesis, which build.py's old
# 1200s per-command cap kept killing mid-ABC9.
cd "$(dirname "$0")" || exit 1
export PATH="/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/bin:/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/lib:$PATH"
LOG=../evidence/finish_150.log
DRV=../evidence/integrate_console_run2.log
say() { echo "$(date -u +%FT%TZ) $*" >>"$LOG"; }

# Never run two syntheses of the same core at once: contention looks like a
# timeout and would corrupt the measured-size evidence. Match the exact
# invocation ("-u build.py"), because monitoring shells quote those names and
# would otherwise look like a live tool.
for p in /proc/[0-9]*/cmdline; do
  c=$(tr '\0' ' ' <"$p" 2>/dev/null || true)
  case "$c" in *"-u build.py"*|*"-u integrate.py"*) say "ABORT stale tool still running: $(echo "$c" | cut -c1-100)"; exit 1 ;; esac
done

STAMP=ic_bloom_$(date -u +%H%M)
say "step 3 (retry, 3600s cap) isolated synthesis bloom4_update stamp=$STAMP"
python -u build.py --isolated --isolated-core bloom4_update --no-groups \
    --stamp "$STAMP" >>"$LOG" 2>&1 || { say "ABORT bloom isolated"; exit 1; }
say "bloom4_update measured"

say "step 4 deal dry run"
python -u deal.py >>"$LOG" 2>&1
grep -aq "refusing to deal" "$LOG" && { say "ABORT deal still refuses"; exit 1; }
python -u deal.py --write >>"$LOG" 2>&1 || { say "ABORT deal write"; exit 1; }
say "deal written"

nohup python -u integrate.py --from deal --deadline 21600 --workers 3 >>"$DRV" 2>&1 &
say "integrate --from deal launched"

for _ in $(seq 1 340); do
  sleep 120
  alive() {
    for q in /proc/[0-9]*/cmdline; do
      c=$(tr '\0' ' ' <"$q" 2>/dev/null || true)
      case "$c" in *"$1"*) return 0 ;; esac
    done
    return 1
  }
  alive "-u integrate.py" || {
    # Once the driver has printed its terminal verdict, relaunching it would
    # re-synthesize all twenty groups for nothing; keep only the board stage.
    if grep -aq 'INTEGRATION PASS' "$DRV"; then
      say 'integration already PASS, not relaunching'
    else
      nohup python -u integrate.py --from deal --deadline 21600 --workers 3 >>"$DRV" 2>&1 &
      say "integrate relaunched"
    fi
  }
  alive "-u boardwatch.py" || {
    nohup python -u boardwatch.py --wait 21600 >>../evidence/boardwatch_console_finish.log 2>&1 &
    say "boardwatch relaunched"
  }
done
say "watchdog window exhausted"
