"""Watch the parallel family authors, then run the deterministic part of the
150-core integration unattended.

Phases, in order, each a subprocess of the existing tools so no new semantics
are introduced here:

  generate    per-family `generate.py --family F` (per-core files only)
  isolated    per-family isolated synthesis, which is what `deal` measures
  deal        plan the new cores into board groups, then write group_order.json
  generateall global generate (asserts the full core count) and board artifacts
  selftest    independent-model selftest across every family
  coresim     per-core benches plus the flipped-response mutation gate
  harness     board and UART harness benches, sharded over groups
  groupbuild  synthesis, place-and-route and packing of every group

It stops at the first failure and records what it saw; it never edits a family
plug-in, never re-runs a failed phase, and never programs silicon, because
those three need a decision rather than a retry. Resume with --from after
fixing the cause. Read the evidence JSON before believing any of this.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
ORDER = TOOLS / 'group_order.json'
PHASES = ['wait', 'generate', 'isolated', 'deal', 'generateall', 'selftest',
          'coresim', 'harness', 'groupbuild']

SNAPSHOT = '''
import json, sys, time
sys.path.insert(0, {tools!r})
import catalog, author_status
from pathlib import Path
from generate_lib import ROOT
from groups import ROWS_PER_CORE
fams = {{}}
for family, names in author_status.EXPECTED.items():
    want = set(names.split())
    have = {{e['name'] for e in catalog.CORES if e['family'] == family}}
    mod = None
    try:
        mod = __import__('fam_' + family, fromlist=['x'])
    except Exception:
        pass
    checks = None
    if mod is not None and hasattr(mod, 'selftest'):
        try:
            value = mod.selftest()
            checks = value if isinstance(value, int) else 'NOT-INT'
        except Exception as exc:
            checks = 'RAISES ' + exc.__class__.__name__
    unready = []
    if mod is not None:
        # A plug-in can register every name and still hold a vectors() stub.
        # generate would abort on it hours from now, so say so at the gate.
        for name in sorted(want):
            try:
                produced = mod.vectors(name)
                if len(produced) < ROWS_PER_CORE:
                    unready.append(name + '(only ' + str(len(produced)) + ' rows)')
            except NotImplementedError:
                unready.append(name + '(no vectors)')
            except Exception as exc:
                unready.append(name + '(' + exc.__class__.__name__ + ')')
    path = ROOT / 'tools' / ('fam_' + family + '.py')
    fams[family] = dict(missing=sorted(want - have), extra=sorted(have - want),
                        loaded=('fam_' + family) in catalog.LOADED_FAMILIES,
                        ncores=len(have),
                        selftest=checks, vectors_gap=unready,
                        age=(time.time() - path.stat().st_mtime) if path.is_file() else None,
                        rtl=sum(1 for n in want if (ROOT / 'rtl' / ('acc_' + n + '.v')).is_file()))
print(json.dumps(dict(cores=len(catalog.CORES), families=fams)))
'''


def snapshot():
    code = SNAPSHOT.format(tools=str(TOOLS))
    proc = subprocess.run([sys.executable, '-c', code], cwd=TOOLS,
                          capture_output=True, text=True, timeout=300)
    line = [l for l in proc.stdout.splitlines() if l.startswith('{')]
    if not line:
        raise RuntimeError('snapshot failed: ' + (proc.stderr or proc.stdout)[-300:])
    return json.loads(line[-1])


def run(argv, timeout, log):
    proc = subprocess.run([sys.executable, *argv], cwd=TOOLS,
                          capture_output=True, text=True, timeout=timeout)
    text = proc.stdout + proc.stderr
    log.write_text(text, encoding='utf-8')
    tail = [line for line in text.splitlines() if line.strip()][-6:]
    return proc.returncode, tail


def parallel(jobs, timeout, evidence, workers):
    """jobs = [(name, argv)]. Returns names that failed, with output tails."""
    from concurrent.futures import as_completed
    failures = {}
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(run, argv, timeout, evidence/(name + '.log')): name
                   for name, argv in jobs}
        for future in as_completed(futures):
            name = futures[future]
            code, tail = future.result()
            if code:
                failures[name] = tail
                print(f'  FAIL {name}: ' + ' | '.join(tail)[:400], flush=True)
            else:
                print(f'  ok {name}', flush=True)
    return failures


def ready_row(row, stable):
    """A family is delivered when it loads, names exactly its assigned cores,
    exports a selftest that performs at least one independent check per core,
    can actually produce every board vector set, and has not been touched for
    `stable` seconds -- an author keeps editing after its first write."""
    return (row['loaded'] and not row['missing'] and not row['extra']
            and isinstance(row['selftest'], int)
            and row['selftest'] >= max(1, row.get('ncores', 1))
            and not row['vectors_gap']
            and row['age'] is not None and row['age'] >= stable)


def why_not(row, stable):
    if not row['loaded']:
        return 'not loaded'
    if row['missing']:
        return f'missing {len(row["missing"])}: ' + ','.join(row['missing'])
    if row['extra']:
        return 'extra ' + ','.join(row['extra'])
    if not isinstance(row['selftest'], int) or row['selftest'] <= 0:
        return f'selftest={row["selftest"]}'
    if row['selftest'] < max(1, row.get('ncores', 1)):
        return (f'selftest={row["selftest"]} checks for {row.get("ncores")} cores '
                '(needs one independent check per core)')
    if row['vectors_gap']:
        return f'vectors gap ({len(row["vectors_gap"])}): ' + ','.join(row['vectors_gap'])
    if row['age'] is None or row['age'] < stable:
        return f'age={int(row["age"] or 0)}s'
    return ''


def measure(family, evidence):
    """Generate one family's per-core artifacts, then synthesize it in isolation.

    Both write only inside that family's own files, so this is safe while other
    authors are still live, and it front-loads the sizes `deal` needs instead of
    measuring a hundred cores after everybody finishes.
    """
    code, tail = run(['generate.py', '--family', family], 1800,
                     evidence / ('gen_' + family + '.log'))
    if code:
        return False, ['generate: ' + line for line in tail]
    # The stamp must be unique per run: build.py refuses to reuse an evidence
    # directory, and an author may already have made `build_iso_<family>`. A
    # run-stamped name also sorts after the plain one, so deal.py's newest
    # metrics per core keep coming from this run. Reusing a directory this run
    # already produced is what makes a resumed watcher idempotent instead of
    # failing on FileExistsError forever.
    run_stamp = evidence.name.split('integrate_', 1)[1]
    stamp = 'iso_' + family + '_' + run_stamp
    plug_in = TOOLS / ('fam_' + family + '.py')
    # An interrupted attempt leaves its directory behind with no summary.json, and
    # build.py refuses to write into an existing one, so a retry would collide with
    # its own corpse forever. A timed-out synthesis is exactly that case.
    corpse = ROOT / 'evidence' / ('build_' + stamp)
    if corpse.is_dir() and not (corpse / 'summary.json').is_file():
        stamp += '_' + datetime.now(timezone.utc).strftime('%H%M%S')
    prior = sorted((ROOT / 'evidence').glob('build_iso_' + family + '*/summary.json'))
    if prior and plug_in.exists() and prior[-1].stat().st_mtime >= plug_in.stat().st_mtime:
        return True, ['reusing isolated synthesis from ' + prior[-1].parent.name]
    code, tail = run(['build.py', '--isolated', '--family', family, '--no-groups',
                      '--stamp', stamp], 3600,
                     evidence / ('iso_' + family + '.log'))
    return (code == 0), tail


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--from', dest='start', default='wait', choices=PHASES)
    ap.add_argument('--deadline', type=int, default=90 * 60,
                    help='seconds to wait for the authors to land')
    ap.add_argument('--stable', type=int, default=240,
                    help='seconds a family plug-in must be untouched before it counts '
                         'as delivered, because an author keeps editing after its first write')
    ap.add_argument('--workers', type=int, default=3)
    ap.add_argument('--cores', type=int, default=150,
                    help='expected catalog size; the global generate asserts it')
    args = ap.parse_args()
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    evidence = ROOT / 'evidence' / ('integrate_' + stamp)
    evidence.mkdir(parents=True, exist_ok=False)
    log = dict(start=args.start, deadline_s=args.deadline, stable_s=args.stable,
               phases=[], status='IN_PROGRESS')

    def checkpoint():
        (evidence / 'summary.json').write_text(json.dumps(log, indent=2) + '\n',
                                               encoding='utf-8')

    def phase(name, jobs, timeout):
        print(f'=== {name} ({len(jobs)} jobs) ===', flush=True)
        started = time.time()
        failures = parallel(jobs, timeout, evidence, args.workers) if jobs else {}
        row = dict(phase=name, jobs=len(jobs), status='PASS' if not failures else 'FAIL',
                   seconds=round(time.time() - started, 1), failed=list(failures),
                   tails=failures)
        log['phases'].append(row)
        checkpoint()
        if failures:
            raise RuntimeError(f'phase {name} failed: {list(failures)}')
        return row

    # The family list comes from the supervision script, not from a copy here.
    import author_status
    families = sorted(author_status.EXPECTED)
    measured, failed, attempts, tried_at = {}, {}, {}, {}

    try:
        if PHASES.index(args.start) <= PHASES.index('wait'):
            print('waiting for ' + ', '.join(families), flush=True)
            until = time.time() + args.deadline
            pool = ThreadPoolExecutor(max_workers=2)
            futures = {}
            while True:
                data = snapshot()
                for family in families:
                    # The retry budget belongs to the plug-in's content, not to
                    # the family: a failure recorded against an older revision
                    # says nothing about the file its author landed afterwards.
                    mtime = (TOOLS / ('fam_' + family + '.py')).stat().st_mtime
                    if tried_at.get(family) != mtime:
                        tried_at[family] = mtime
                        attempts[family] = 0
                    if family in futures or measured.get(family) or attempts.get(family, 0) >= 3:
                        continue
                    if ready_row(data['families'][family], args.stable):
                        print(f'delivered {family}, measuring now', flush=True)
                        # A measurement can fail for a reason that heals: the
                        # author is mid-write, or the box is so loaded that an
                        # isolated synthesis times out. Retrying a bounded
                        # number of times keeps a transient failure from
                        # silently excluding a family until the deadline.
                        attempts[family] = attempts.get(family, 0) + 1
                        futures[pool.submit(measure, family, evidence)] = family
                for future in list(futures):
                    if future.done():
                        family = futures.pop(future)
                        ok, tail = future.result()
                        if ok:
                            measured[family] = 'isolated synthesis recorded'
                            print(f'  measured {family}', flush=True)
                        else:
                            failed[family] = tail
                            print(f'  MEASURE FAIL {family}: '
                                  + ' | '.join(tail)[:300], flush=True)
                log['measured'] = sorted(measured)
                log['measuring'] = sorted(futures.values())
                log['measure_failed'] = {k: v for k, v in failed.items()}
                not_ready = [f'{family}:{why_not(data["families"][family], args.stable)}'
                             for family in families if family not in measured]
                checkpoint()
                print(f'{datetime.now(timezone.utc).strftime("%H:%M:%S")}Z cores='
                      f'{data["cores"]} measured={len(measured)} '
                      f'awaiting: {"; ".join(not_ready)[:200]}', flush=True)
                if not not_ready and not futures:
                    break
                if time.time() > until:
                    pool.shutdown(wait=False)
                    raise RuntimeError(
                        f'authors did not land within {args.deadline}s; '
                        f'measured {sorted(measured)}, still awaiting '
                        + '; '.join(not_ready))
                time.sleep(60)
            pool.shutdown(wait=True)
            log['ready'] = data
            checkpoint()
            # A family that failed an early attempt and then measured clean on a
            # later one has proven artifacts on disk; only a family that never
            # measured may abort the run, or a healed transient would throw away
            # every other family's work.
            stuck = {k: v for k, v in failed.items() if k not in measured}
            if stuck:
                raise RuntimeError('family measurement failed: '
                                   + '; '.join(f'{k}: {" | ".join(v)[:200]}'
                                               for k, v in stuck.items()))

        # Whatever the wait loop already measured is not measured twice; a family
        # whose plug-in changed afterwards is caught by the group budget assert,
        # which is fail-closed, rather than by re-synthesizing here.
        remaining = [f for f in families if f not in measured]
        if PHASES.index(args.start) <= PHASES.index('generate'):
            phase('generate', [('gen_' + f, ['generate.py', '--family', f])
                               for f in remaining], 1800)
        if PHASES.index(args.start) <= PHASES.index('isolated'):
            phase('isolated', [('iso_' + f, ['build.py', '--isolated', '--family', f,
                                             '--no-groups', '--stamp', 'iso_' + f])
                               for f in remaining], 3600)
        if PHASES.index(args.start) <= PHASES.index('deal'):
            code, tail = run(['deal.py'], 900, evidence / 'deal.log')
            if code:
                raise RuntimeError('deal dry run: ' + ' | '.join(tail)[:400])
            code, tail = run(['deal.py', '--write'], 900, evidence / 'deal_write.log')
            if code:
                raise RuntimeError('deal --write: ' + ' | '.join(tail)[:400])
            print('  ' + ' | '.join(tail)[-500:], flush=True)
            log['deal'] = tail
            checkpoint()
        groups = json.loads(ORDER.read_text(encoding='utf-8'))

        if PHASES.index(args.start) <= PHASES.index('generateall'):
            code, tail = run(['generate.py'], 3600, evidence / 'generate_all.log')
            if code:
                raise RuntimeError('global generate: ' + ' | '.join(tail)[:400])
            code, tail = run(['generate_board.py'], 3600, evidence / 'board.log')
            if code:
                raise RuntimeError('generate_board: ' + ' | '.join(tail)[:400])
            print('  ' + ' | '.join(tail)[-300:], flush=True)
            checkpoint()

        if PHASES.index(args.start) <= PHASES.index('selftest'):
            code, tail = run(['model_selftest.py'], 1800, evidence / 'selftest.log')
            if code:
                raise RuntimeError('model selftest: ' + ' | '.join(tail)[:400])
            print('  ' + tail[-1], flush=True)
            checkpoint()

        if PHASES.index(args.start) <= PHASES.index('coresim'):
            phase('coresim', [('sim_' + f, ['verify.py', '--family', f, '--mutations',
                                            '--tag', 'cs_' + f])
                              for f in families], 3600)

        if PHASES.index(args.start) <= PHASES.index('harness'):
            all_groups = list(range(len(groups)))
            shards = [all_groups[i:i + 5] for i in range(0, len(all_groups), 5)]
            phase('harness', [(f'hs_{shard[0]}', ['verify.py', '--groups',
                                                   ','.join(map(str, shard)),
                                                   '--board', '--uart',
                                                   '--tag', f'hs{shard[0]}'])
                              for shard in shards], 7200)

        if PHASES.index(args.start) <= PHASES.index('groupbuild'):
            all_groups = list(range(len(groups)))
            # Three groups per shard, not four: a shard runs its groups one after
            # another in a single yosys+nextpnr process, and one of the twenty
            # groups now holds a core whose ABC9 cone alone costs ~20 minutes.
            shards = [all_groups[i:i + 3] for i in range(0, len(all_groups), 3)]
            phase('groupbuild', [(f'gb_{shard[0]}', ['build.py', '--groups',
                                                     ','.join(map(str, shard)),
                                                     '--stamp', f'gb{shard[0]}'])
                                 for shard in shards], 21600)

        log['status'] = 'PASS'
        print('INTEGRATION PASS up to board programming; evidence=' + str(evidence),
              flush=True)
    except Exception as exc:
        log['status'] = 'FAIL'
        log['reason'] = str(exc)[:1000]
        print('FAILED: ' + str(exc)[:1000], flush=True)
        checkpoint()
        return 1
    checkpoint()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
