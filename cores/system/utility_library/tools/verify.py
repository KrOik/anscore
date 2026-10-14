"""Fail-closed unit simulation runner with source-bound evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from datetime import datetime, timezone
from catalog import CORES

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]


def environment():
    env = os.environ.copy()
    suite = REPO / 'tools/oss-cad-suite/oss-cad-suite'
    env['PATH'] = os.pathsep.join([str(suite/'bin'), str(suite/'lib'), env['PATH']])
    return env


def run(command, log):
    command = [str(v) for v in command]
    local_tool = REPO/'tools/oss-cad-suite/oss-cad-suite/bin'/(command[0]+'.exe')
    if local_tool.is_file():
        command[0] = str(local_tool)
    p = subprocess.run(command, cwd=ROOT, env=environment(),
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    text = p.stdout.decode('utf-8', 'replace')
    log.write_text(text, encoding='utf-8')
    if p.returncode:
        raise RuntimeError(f'{command[0]} failed ({p.returncode}), see {log}')
    return text


def source_hashes():
    paths = sorted(p for folder in ['rtl', 'integration', 'tools', 'vectors', 'sim', 'board', 'ip', 'doc']
                   for p in (ROOT/folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts)
    return {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--core')
    ap.add_argument('--board', action='store_true')
    ap.add_argument('--uart', action='store_true')
    ap.add_argument('--integration', action='store_true')
    ap.add_argument('--mutations', action='store_true')
    args = ap.parse_args()
    selected = [e for e in CORES if not args.core or e['name'] == args.core]
    if not selected:
        ap.error('unknown core')
    out = ROOT/'evidence'/('sim_'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
    out.mkdir(parents=True, exist_ok=False)
    results = []
    for entry in selected:
        name = entry['name']
        vvp = out/(name+'.vvp')
        run(['iverilog', '-g2012', '-s', 'tb_'+name, '-o', vvp,
             ROOT/f'rtl/prod_{name}.v', ROOT/f'sim/tb_{name}.sv'], out/(name+'_compile.log'))
        text = run(['vvp', vvp], out/(name+'.log'))
        if f'PASS {name} vectors=' not in text:
            raise RuntimeError('missing verdict: '+name)
        verdict = text.splitlines()[0]
        print(verdict, flush=True)
        results.append(dict(name=name, status='PASS', verdict=verdict))
        if args.mutations:
            original = (ROOT/f'rtl/prod_{name}.v').read_text(encoding='utf-8')
            changed = original.replace('result<=r;', "result<=r^32'd1;")
            if name == 'bcd8_encode':
                changed = original.replace("result<=stage_fault?32'd0:second[63:32];",
                                           "result<=(stage_fault?32'd0:second[63:32])^32'd1;")
            assert changed != original
            mutated = out/(name+'_mutated.v')
            mutated.write_text(changed, encoding='utf-8')
            mutated_vvp = out/(name+'_mutated.vvp')
            run(['iverilog', '-g2012', '-s', 'tb_'+name, '-o', mutated_vvp,
                 mutated, ROOT/f'sim/tb_{name}.sv'], out/(name+'_mutation_compile.log'))
            # A failing DUT must be rejected by the normal, unmodified test.
            try:
                run(['vvp', mutated_vvp], out/(name+'_mutation.log'))
            except RuntimeError:
                if 'FATAL:' not in (out/(name+'_mutation.log')).read_text(encoding='utf-8'):
                    raise RuntimeError('mutation failed for a non-test reason: '+name)
            else:
                raise RuntimeError('mutation escaped: '+name)
            results[-1]['response_bit_mutation_detected'] = True
    board_results = []
    if args.board:
        for group in range(7):
            vvp = out/f'board_{group}.vvp'
            src = [ROOT/f'rtl/prod_{e["name"]}.v' for e in CORES[group*8:group*8+8]]
            run(['iverilog', '-g2012', '-s', f'tb_board_{group}', '-o', vvp,
                 ROOT/f'board/prod_board_group_{group}.v', ROOT/f'sim/tb_board_{group}.sv',
                 *src], out/f'board_{group}_compile.log')
            text = run(['vvp', vvp], out/f'board_{group}.log')
            if f'PASS board group={group}' not in text:
                raise RuntimeError('missing board harness verdict')
            print(text.splitlines()[0], flush=True)
            board_results.append(dict(group=group, status='PASS', verdict=text.splitlines()[0]))
    uart_results = []
    if args.uart:
        for group in range(7):
            vvp = out/f'uart_{group}.vvp'
            src = [ROOT/f'rtl/prod_{e["name"]}.v' for e in CORES[group*8:group*8+8]]
            src += sorted((ROOT/'board').glob('*.v'))
            run(['iverilog', '-g2012', '-s', f'tb_uart_{group}', '-o', vvp,
                 ROOT/f'sim/tb_uart_{group}.sv', *src], out/f'uart_{group}_compile.log')
            text = run(['vvp', vvp], out/f'uart_{group}.log')
            if f'PASS UART group={group}' not in text:
                raise RuntimeError('missing UART verdict')
            print(text.splitlines()[0], flush=True)
            uart_results.append(dict(group=group, status='PASS', verdict=text.splitlines()[0]))
    integration_results = []
    if args.integration:
        vvp = out/'apb_adapter.vvp'
        run(['iverilog', '-g2012', '-s', 'tb_apb_adapter', '-o', vvp,
             ROOT/'integration/prod_apb3_adapter.v', ROOT/'sim/tb_apb_adapter.sv'],
            out/'apb_adapter_compile.log')
        text = run(['vvp', vvp], out/'apb_adapter.log')
        if 'PASS APB adapter:' not in text:
            raise RuntimeError('missing APB integration verdict')
        print(text.splitlines()[0], flush=True)
        integration_results.append(dict(name='apb_adapter', status='PASS', verdict=text.splitlines()[0]))
    report = dict(timestamp=datetime.now(timezone.utc).isoformat(), count=len(results),
                  status='PASS', cores=results, board_harness_simulations=board_results,
                  uart_simulations=uart_results,
                  integration_simulations=integration_results,
                  sources=source_hashes())
    (out/'summary.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(f'{len(results)}/{len(selected)} PASS; evidence={out}')


if __name__ == '__main__':
    main()
