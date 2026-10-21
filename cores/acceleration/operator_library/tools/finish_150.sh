#!/bin/bash
# Finish the 150-core release: prove the bloom latch-free rewrite is inert, get
# the last two measured sizes, deal every pending core, then hand the rest of the
# chain (generateall -> selftest -> coresim -> harness -> groupbuild) to
# integrate.py and keep the board stage armed.
#
# Fail-closed: each gate below must actually pass before the next one starts, and
# nothing here weakens a gate -- it only sequences the existing tools.
cd "$(dirname "$0")" || exit 1
export PATH="/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/bin:/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/lib:$PATH"
LOG=../evidence/finish_150.log
DRV=../evidence/integrate_console_run2.log
say() { echo "$(date -u +%FT%TZ) $*" >>"$LOG"; }

say "step 1 regenerate netio rtl"
python -u generate.py --family netio >>"$LOG" 2>&1 || { say "ABORT generate"; exit 1; }

say "step 2 verify netio (model vs rtl, 320 vectors/core)"
python -u verify.py --family netio >>"$LOG" 2>&1
grep -aq "10/10 cores" "$LOG" || { say "ABORT verify netio not 10/10"; exit 1; }
say "verify netio 10/10 PASS"

say "step 3 isolated synthesis bloom4_update"
python -u build.py --isolated --isolated-core bloom4_update --no-groups \
    --stamp ic_bloom_1915 >>"$LOG" 2>&1 || { say "ABORT bloom isolated"; exit 1; }

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
    for p in /proc/[0-9]*/cmdline; do
      c=$(tr '\0' ' ' <"$p" 2>/dev/null || true)
      case "$c" in *"$1"*) return 0 ;; esac
    done
    return 1
  }
  alive integrate.py || {
    nohup python -u integrate.py --from deal --deadline 21600 --workers 3 >>"$DRV" 2>&1 &
    say "integrate relaunched"
  }
  alive boardwatch.py || {
    nohup python -u boardwatch.py --wait 21600 >>../evidence/boardwatch_console_finish.log 2>&1 &
    say "boardwatch relaunched"
  }
done
say "watchdog window exhausted"
