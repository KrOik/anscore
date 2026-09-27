"""Fail-closed simulation runner with source-bound evidence.

Every core is simulated against vectors produced only by the independent
Python model, then mutated to prove the bench actually detects a wrong
response bit. Board and UART benches are separate, whole-harness checks.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
from datetime import datetime, timezone

from catalog import CORES
from groups import plan

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
DEFAULT_MUTATION = ('result<=r;', "result<=r^32'd1;")


def environment():
    env = os.environ.copy()
    suite = REPO / 'tools/oss-cad-suite/oss-cad-suite'
    env['PATH'] = os.pathsep.join([str(suite/'bin'), str(suite/'lib'), env['PATH']])
    return env


def run(command, log, timeout=300):
    command = [str(v) for v in command]
    local_tool = REPO/'tools/oss-cad-suite/oss-cad-suite/bin'/(command[0]+'.exe')
    if local_tool.is_file():
        command[0] = str(local_tool)
    log.parent.mkdir(parents=True, exist_ok=True)
    p = subprocess.run(command, cwd=ROOT, env=environment(),
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    text = p.stdout.decode('utf-8', 'replace')
    log.write_text(text, encoding='utf-8')
    if p.returncode:
        raise RuntimeError(f'{command[0]} failed ({p.returncode}), see {log}')
    return text


def source_hashes():
    paths = sorted(p for folder in ['rtl', 'vectors', 'sim', 'board', 'ip', 'tools', 'tables', 'doc']
                   for p in (ROOT/folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts)
    return {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def core_sources(entry):
    files = [ROOT/f'rtl/acc_{entry["name"]}.v']
    files += [ROOT/extra for extra in entry.get('sim_extra', [])]
    return files


def simulate_core(entry, out):
    name = entry['name']
    vvp = out/(name+'.vvp')
    run(['iverilog', '-g2012', '-s', 'tb_'+name, '-o', vvp,
         *core_sources(entry), ROOT/f'sim/tb_{name}.sv'], out/(name+'_compile.log'))
    text = run(['vvp', vvp], out/(name+'.log'))
    if f'PASS {name} vectors=' not in text:
        raise RuntimeError('missing verdict: '+name)
    return text.splitlines()[0]


def mutate_core(entry, out):
    """A single flipped response bit must be caught by the unmodified bench."""
    name = entry['name']
    original = (ROOT/f'rtl/acc_{name}.v').read_text(encoding='utf-8')
    old, new = entry.get('mutation') or DEFAULT_MUTATION
    if old not in original:
        raise RuntimeError(f'{name}: mutation anchor {old!r} absent; set mutation= in the family file')
    changed = original.replace(old, new, 1)
    assert changed != original
    mutated = out/(name+'_mutated.v')
    mutated.write_text(changed, encoding='utf-8')
    vvp = out/(name+'_mutated.vvp')
    run(['iverilog', '-g2012', '-s', 'tb_'+name, '-o', vvp, mutated,
         *core_sources(entry)[1:], ROOT/f'sim/tb_{name}.sv'], out/(name+'_mutation_compile.log'))
    try:
        run(['vvp', vvp], out/(name+'_mutation.log'))
    except RuntimeError:
        text = (out/(name+'_mutation.log')).read_text(encoding='utf-8')
        if 'FATAL' not in text:
            raise RuntimeError(f'{name}: mutation failed for a non-test reason')
        return True
    raise RuntimeError(f'{name}: mutation escaped')


def simulate_board(row, out):
    group = row['group']
    vvp = out/f'board_{group}.vvp'
    sources = [ROOT/f'rtl/acc_{name}.v' for name in row['names']]
    extras = sorted({ROOT/extra for name in row['names']
                     for extra in next(e for e in CORES if e['name']==name).get('sim_extra', [])})
    run(['iverilog', '-g2012', '-s', f'tb_board_{group}', '-o', vvp,
         ROOT/f'board/acc_board_group_{group}.v', ROOT/f'sim/tb_board_{group}.sv',
         *sources, *extras], out/f'board_{group}_compile.log')
    text = run(['vvp', vvp], out/f'board_{group}.log', timeout=600)
    if f'PASS board group={group}' not in text:
        raise RuntimeError('missing board harness verdict for group '+str(group))
    return text.splitlines()[0]


def simulate_uart(row, out):
    group = row['group']
    vvp = out/f'uart_{group}.vvp'
    sources = [ROOT/f'rtl/acc_{name}.v' for name in row['names']]
    extras = sorted({ROOT/extra for name in row['names']
                     for extra in next(e for e in CORES if e['name']==name).get('sim_extra', [])})
    run(['iverilog', '-g2012', '-s', f'tb_uart_{group}', '-o', vvp,
         ROOT/f'sim/tb_uart_{group}.sv', ROOT/'board/acc_top.v',
         ROOT/'board/acc_uart_tx.v', ROOT/f'board/acc_board_group_{group}.v',
         *sources, *extras], out/f'uart_{group}_compile.log')
    text = run(['vvp', vvp], out/f'uart_{group}.log', timeout=900)
    if f'PASS UART group={group}' not in text:
        raise RuntimeError('missing UART verdict for group '+str(group))
    return text.splitlines()[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--family')
    ap.add_argument('--core')
    ap.add_argument('--groups', help='comma list of board groups whose harness benches run; '
                    'shards the whole-tree board/UART sims across processes')
    ap.add_argument('--board', action='store_true')
    ap.add_argument('--uart', action='store_true')
    ap.add_argument('--mutations', action='store_true')
    ap.add_argument('--tag', default='sim')
    args = ap.parse_args()
    wanted_groups = None if not args.groups else {int(v) for v in args.groups.split(',')}
    # A bare --groups selects the harness benches of those groups only, which is
    # how the whole-tree board and UART sims get sharded across processes.
    harness_only = bool(wanted_groups is not None and not args.family and not args.core)
    selected = [] if harness_only else [
        e for e in CORES if (not args.family or e['family'] == args.family)
        and (not args.core or e['name'] == args.core)]
    if not selected and not harness_only:
        ap.error('nothing selected')
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S')
    out = ROOT/'evidence'/(args.tag+'_'+stamp)
    out.mkdir(parents=True, exist_ok=False)
    results = []
    for entry in selected:
        verdict = simulate_core(entry, out)
        print(verdict, flush=True)
        row = dict(name=entry['name'], status='PASS', verdict=verdict)
        if args.mutations:
            row['response_bit_mutation_detected'] = mutate_core(entry, out)
        results.append(row)
    wanted = {e['name'] for e in selected}
    board_results, uart_results = [], []
    for row in plan():
        if wanted_groups is not None and row['group'] not in wanted_groups:
            continue
        if wanted and not wanted & set(row['names']):
            continue
        if len(row['names']) != row['units']:
            continue
        if args.board:
            verdict = simulate_board(row, out)
            print(verdict, flush=True)
            board_results.append(dict(group=row['group'], status='PASS', verdict=verdict))
        if args.uart:
            verdict = simulate_uart(row, out)
            print(verdict, flush=True)
            uart_results.append(dict(group=row['group'], status='PASS', verdict=verdict))
    report = dict(timestamp=datetime.now(timezone.utc).isoformat(), count=len(results),
                  status='PASS', cores=results, board_harness_simulations=board_results,
                  uart_simulations=uart_results, sources=source_hashes())
    (out/'summary.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(f'{len(results)}/{len(selected)} cores, {len(board_results)} board, '
          f'{len(uart_results)} uart PASS; evidence={out}')


if __name__ == '__main__':
    main()
