"""Build a frozen, simulated public-IP acceptance case; optionally validate SRAM."""
import argparse
import datetime
import json
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
BOARD = HERE.parent
ROOT = BOARD.parents[3]
sys.path.insert(0, str(BOARD))
import resume_candidate_route_official as route


def build(candidate, attempt, chipdb, program=False, port='COM44', no_lutram=False):
    candidate = Path(candidate).resolve()
    provenance = route.verify_simulation_gate(candidate)
    frozen = set(provenance.get('source_sha256_verified', {})) | set(
        provenance.get('freeze_files_sha256_verified', {}))
    specification = json.loads((candidate / 'case.json').read_text(encoding='utf-8'))
    top = specification['top']
    if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', top):
        raise ValueError('invalid top module')
    sources = specification['sources']
    if not sources:
        raise ValueError('empty source list')
    for name in sources:
        path = route.contained_file(candidate, name)
        if not re.fullmatch(r'[A-Za-z_0-9./-]+', name) or path.suffix not in ('.v', '.sv'):
            raise ValueError('unsafe or unsupported source filename')
        if name not in frozen:
            raise ValueError(f'source missing from simulation freeze: {name}')
    for name in ('expected_uart.txt', 'tang25k.cst', 'case.json'):
        if name not in frozen:
            raise ValueError(f'acceptance input missing from simulation freeze: {name}')
    if (candidate / 'top25k.json').exists():
        raise ValueError('existing synthesized netlist preserved; choose a fresh case directory')
    synthesis = ['read_verilog -sv -I. ' + ' '.join(sources)]
    library = route.device_flow.cells_xtra_lib()
    if library:
        synthesis.append('read_verilog -lib "' + str(library).replace('\\', '/') + '"')
    memory_option=' -nolutram' if no_lutram else ''
    synthesis.extend([f'synth_gowin -noalu{memory_option} -family gw5a -top {top} -json top25k.json', 'stat'])
    (candidate / 'acceptance_synthesis.ys').write_text('\n'.join(synthesis)+'\n', encoding='utf-8')
    route.device_flow.run(candidate, ['yosys', '-s', 'acceptance_synthesis.ys'],
                          'acceptance_synthesis.log', timeout=1200)
    route.verify_simulation_gate(candidate)
    result = route.run_attempt(candidate, attempt, Path(chipdb).resolve(), seed=3,
                               route_only=True)
    if result:
        return result
    if program:
        command = [sys.executable, '-B', str(BOARD / 'validate_candidate_uart.py'),
                   str(candidate), '--port', port, '--summary', f'build_{attempt}_summary.json']
        return subprocess.run(command, check=False).returncode
    return 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--attempt', default='accept_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S'))
    parser.add_argument('--chipdb', type=Path,
                        default=ROOT/'scratch/bram_timing_db_20261017/GW5A-25A_patched.bin')
    parser.add_argument('--program', action='store_true', help='load volatile SRAM and compare UART')
    parser.add_argument('--port', default='COM44')
    parser.add_argument('--no-lutram', action='store_true', help='disable automatic distributed RAM mapping')
    args = parser.parse_args()
    raise SystemExit(build(args.candidate, args.attempt, args.chipdb, args.program, args.port,args.no_lutram))
