#!/bin/bash
# Resilience watchdog: keeps the integrate driver and boardwatch alive until the
# 20-group release is programmed. Run detached; every action is timestamped.
cd "$(dirname "$0")" || exit 1
LOG=../evidence/keep_running.log
DRV=../evidence/integrate_console_run2.log
AUTO=../evidence/integrate_console_auto.log
LOCK=../evidence/.driver_lock

alive() {
  for p in /proc/[0-9]*/cmdline; do
    c=$(tr '\0' ' ' <"$p" 2>/dev/null)
    case "$c" in *"$1"*) return 0 ;; esac
  done
  return 1
}

note() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >>"$LOG"; }

for _ in $(seq 1 360); do
  sleep 120

  if [ -d "$LOCK" ] && [ $(( $(date +%s) - $(stat -c %Y "$LOCK") )) -lt 600 ]; then
    :
  else
    rm -rf "$LOCK"
    if ! alive integrate.py && ! grep -qa "INTEGRATION PASS" "$DRV" 2>/dev/null; then
      ph=$(grep -a '^=== ' "$DRV" 2>/dev/null | tail -1 | sed 's/^=== \([a-z]*\).*/\1/')
      case "$ph" in wait|generate|isolated|deal|generateall|selftest|coresim|harness|groupbuild) ;; *) ph=wait ;; esac
      mkdir -p "$LOCK"
      note "driver dead: relaunching --from $ph"
      nohup python -u integrate.py --from "$ph" --deadline 21600 --stable 240 --workers 3 >>"$AUTO" 2>&1 &
    fi
  fi

  if ! alive boardwatch.py; then
    # Board stage is only done when the newest board summary covers every group
    # the regenerated expectation lists -- the proven 50-core release leaves old
    # board_* dirs on disk, so mere existence proves nothing.
    covered=$(python - <<'PY' 2>/dev/null || echo 0
import json, glob, os
try:
    want = {r['group'] for r in json.load(open('../board/expected.json', encoding='utf-8'))}
    dirs = sorted(glob.glob('../evidence/board_*'), key=os.path.getmtime)
    got = set()
    if dirs:
        s = json.load(open(os.path.join(dirs[-1], 'summary.json'), encoding='utf-8'))
        for g in s.get('groups', []):
            if g.get('status') == 'PASS':
                got.add(g.get('group'))
    print(1 if want and want <= got else 0)
except Exception:
    print(0)
PY
)
    if [ "$covered" = "1" ]; then
      note "boardwatch dead but every expected group is already PASS; not restarting"
    else
      note "boardwatch dead: relaunching --wait 21600"
      nohup python -u boardwatch.py --wait 21600 >>../evidence/boardwatch_console_auto.log 2>&1 &
    fi
  fi
done
note "watchdog window exhausted"
