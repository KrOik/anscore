#!/bin/bash
# Start the silicon stage without waiting for a human to remember the dock.
#
# The dock currently has a hands-on power/reset fault (openFPGALoader clocks the
# adapter but TDO reads stuck at 0), and programming attempts against a board
# that does not answer can leave an openFPGALoader stuck that detaches the USB
# serial driver. So nothing here touches the JTAG chain until a read-only probe
# has *passed*; the probe is what proves the FPGA answers again.
cd "$(dirname "$0")" || exit 1
export PATH="/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/bin:/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/lib:$PATH"
LOG=../evidence/boardready_console.log
say() { echo "$(date -u +%FT%TZ) $*" >>"$LOG"; }

alive_boardwatch() {
  for p in /proc/[0-9]*/cmdline; do
    first=$(tr '\0' '\n' <"$p" 2>/dev/null | head -1)
    case "$first" in *python.exe|*python3|*python) ;; *) continue ;; esac
    case "$(tr '\0' ' ' <"$p")" in *"-u boardwatch.py"*) return 0 ;; esac
  done
  return 1
}

say "boardready armed (probe-gated board stage)"
for tick in $(seq 1 144); do
  if timeout 150 python -u remote_board.py --probe >>"$LOG" 2>&1; then
    say "PROBE PASS: dock answers JTAG, launching boardwatch"
    if alive_boardwatch; then
      say "boardwatch already running, not launching a second one"
    else
      nohup python -u boardwatch.py --wait 43200 >>../evidence/boardwatch_console_ready.log 2>&1 &
      say "boardwatch launched pid $!"
    fi
    exit 0
  fi
  say "probe attempt $tick failed (board still unpowered or held in reset)"
  sleep 480
done
say "boardready window exhausted without a passing probe"
exit 1
