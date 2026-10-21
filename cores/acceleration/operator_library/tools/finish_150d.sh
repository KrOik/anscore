#!/bin/bash
# Drive the 150-core release from the word-decoded bloom4_update measurement to
# the board stage. Steps 1-2 of the earlier chain (netio regeneration, family
# verify 10/10 with mutations) already passed for this RTL, so this starts at
# the one measurement that was still missing.
#
# Every grep below reads a *fresh* per-step log: the previous chain grepped a
# cumulative log, which would have matched an ABORT line left by an earlier
# attempt and aborted a healthy run.
cd "$(dirname "$0")" || exit 1
export PATH="/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/bin:/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/lib:$PATH"
LOG=../evidence/finish_150d.log
DRV=../evidence/integrate_console_run5.log
BW=../evidence/boardwatch_console_word.log
say() { echo "$(date -u +%FT%TZ) $*" >>"$LOG"; }

# Never run two syntheses of the same core at once. Only a process whose argv[0]
# is python counts: monitoring shells quote these names in their own command
# strings, and three earlier chains were stopped by that self-match.
stale_tool() {
  for p in /proc/[0-9]*/cmdline; do
    first=$(tr '\0' '\n' <"$p" 2>/dev/null | head -1)
    case "$first" in *python.exe|*python3|*python) ;; *) continue ;; esac
    rest=$(tr '\0' ' ' <"$p")
    case "$rest" in
      *"-u build.py"*|*"-u integrate.py"*) echo "$rest" | cut -c1-90; return 0 ;;
    esac
  done
  return 1
}
if H=$(stale_tool); then say "ABORT stale tool still running: $H"; exit 1; fi

STAMP=ic_word_$(date -u +%H%M)
ISO=../evidence/iso_word.log
say "step 1 isolated synthesis bloom4_update (word decode) stamp=$STAMP"
python -u build.py --isolated --isolated-core bloom4_update --no-groups \
    --stamp "$STAMP" >"$ISO" 2>&1 || { say "ABORT bloom isolated word"; exit 1; }
say "bloom4_update measured"

DRY=../evidence/deal_dry_word.log
say "step 2 deal dry run"
python -u deal.py >"$DRY" 2>&1
grep -aq "refusing to deal" "$DRY" && { say "ABORT deal still refuses"; exit 1; }
say "deal dry run accepted"
python -u deal.py --write >>"$DRY" 2>&1 || { say "ABORT deal write"; exit 1; }
say "deal written"

nohup python -u integrate.py --from deal --deadline 21600 --workers 3 >>"$DRV" 2>&1 &
say "integrate --from deal launched"

alive() {
  # $1 is a tool argument substring; only python processes count, so this shell's
  # own quoted copy of the name cannot look like a live tool.
  for q in /proc/[0-9]*/cmdline; do
    first=$(tr '\0' '\n' <"$q" 2>/dev/null | head -1)
    case "$first" in *python.exe|*python3|*python) ;; *) continue ;; esac
    c=$(tr '\0' ' ' <"$q")
    case "$c" in *"$1"*) return 0 ;; esac
  done
  return 1
}
already_pass() { grep -aq 'INTEGRATION PASS' "$DRV"; }

# 200 x 120 s = 6 h 40 m of supervision: enough for generateall, selftest,
# coresim, harness and seven three-group shards, then the board stage.
tick=0
for _ in $(seq 1 200); do
  sleep 120
  tick=$((tick+1))
  if already_pass; then
    # Integration is done; keep only the board stage armed. The dock currently
    # has a hands-on power/reset fault, so re-arming here is what turns a human
    # re-plug into a finished 20-group sweep without anyone watching.
    # Throttled: a board attempt against a dead dock can leave a stuck
    # openFPGALoader behind, and that detaches ftdi_sio and deletes the console
    # node -- so retry every 10 minutes, not every 2.
    if [ $((tick % 5)) -eq 0 ]; then
      alive "-u boardwatch.py" || {
        nohup python -u boardwatch.py --wait 21600 >>"$BW" 2>&1 &
        say "boardwatch re-armed after integration PASS"
      }
    fi
    continue
  fi
  alive "-u integrate.py" || {
    nohup python -u integrate.py --from deal --deadline 21600 --workers 3 >>"$DRV" 2>&1 &
    say "integrate relaunched"
  }
  # boardwatch exits at once when the newest integrate dir says FAIL, so it has
  # to be re-armed while the real run is still in flight.
  if [ $((tick % 5)) -eq 0 ]; then
    alive "-u boardwatch.py" || {
      nohup python -u boardwatch.py --wait 21600 >>"$BW" 2>&1 &
      say "boardwatch relaunched"
    }
  fi
done
say "chain window closed"
