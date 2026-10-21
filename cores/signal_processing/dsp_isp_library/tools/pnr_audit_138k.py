"""Per-core P&R / timing audit for Tang Mega 138K Pro SOM (GW5AST-138C).

Reuses the spec table from pnr_audit.py but targets:
  - device GW5AST-LV138FPG676AES
  - family GW5AST-138C
  - 50 MHz (board oscillator) timing check

Usage:
    python tools/pnr_audit_138k.py --only DSP-14 ISP-06 ISP-10 ISP-11
"""
import argparse, collections, datetime, json, os, re, subprocess, sys
from pathlib import Path

import pnr_audit as base

HERE = Path(__file__).resolve().parent
LIB = HERE.parent
ROOT = LIB.parents[1]
CAD = ROOT / 'tools/oss-cad-suite/oss-cad-suite'

YOSYS = base.YOSYS
NEXTPNR = base.NEXTPNR

DEVICE = 'GW5AST-LV138FPG676AES'
FAMILY = 'GW5AST-138C'
DEFAULT_FREQ = 50.0

CST = '''IO_LOC "clk" P16;
IO_PORT "clk" PULL_MODE=NONE BANK_VCCIO=3.3;
IO_LOC "rst_n" U4;
IO_PORT "rst_n" PULL_MODE=UP BANK_VCCIO=3.3;
IO_LOC "obs" P15;
IO_PORT "obs" PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
'''


def run(cmd, cwd, logname, env):
    with open(Path(cwd) / logname, 'w') as log:
        r = subprocess.run([str(c) for c in cmd], cwd=cwd, env=env,
                           stdout=log, stderr=subprocess.STDOUT)
    if r.returncode:
        raise RuntimeError(f'{logname} rc={r.returncode}')


def audit_138k(spec, env, freq=DEFAULT_FREQ):
    base_out = Path(base.libsrc(spec['sources'][0]))
    core_dir = base_out.parent.parent if base_out.parent.name == 'rtl' else base_out.parent
    outroot = core_dir / 'evidence' / ('pnr_gw5a138_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    outroot.mkdir(parents=True)
    dest = outroot / spec['case']
    dest.mkdir()
    result = dict(req=spec['req'], case=spec['case'], top=spec['top'],
                  params=spec.get('params', {}),
                  target_device=DEVICE, target_family=FAMILY,
                  target_freq_mhz=freq,
                  sources=[str(LIB / s) for s in spec['sources']],
                  status='FAIL')
    try:
        ports = base.dump_ports(spec, dest, env)
        (dest / 'ports.json.json').unlink(missing_ok=True)
        base.gen_wrapper(spec, ports, dest)
        inc = ''.join(f'verilog_defaults -add -I{base.libsrc(i)}; '
                      for i in spec.get('incdirs', []))
        read = ' '.join(f'read_verilog -sv "{base.libsrc(s)}";' for s in spec['sources'])
        script = (f'{inc}{read} read_verilog -sv "pnr_wrap.sv"; '
                  f'synth_gowin -noalu -family gw5a -top pnr_top -json mapped.json; stat')
        (dest / 'build.ys').write_text(script + '\n')
        run([YOSYS, '-Q', '-s', 'build.ys'], dest, 'yosys.log', env)

        chp = ''
        if spec.get('params'):
            chp = ('chparam ' + ' '.join(f'-set {k} {v}'
                   for k, v in spec['params'].items()) + f' {spec["top"]};')
        script = (f'{inc}{read} {chp} synth_gowin -noalu -family gw5a '
                  f'-top {spec["top"]} -json dut.json')
        if spec.get('no_dut_pass'):
            dut = collections.Counter()
            result['resource_source'] = 'wrapper_upper_bound'
            result['dut_count_error'] = 'skipped by spec (design too large for second synth pass)'
        else:
            try:
                run([YOSYS, '-Q', '-p', script], dest, 'yosys_dut.log', env)
                dnet = json.loads((dest / 'dut.json').read_text())
                dmod = dnet['modules'].get(spec['top'])
                if dmod is None:
                    cand = [k for k in dnet['modules'] if spec['top'] in k]
                    dmod = dnet['modules'][cand[0]]
                dut = collections.Counter(c['type'] for c in dmod['cells'].values())
            except Exception as exc:
                dut = collections.Counter()
                result['dut_count_error'] = repr(exc)
        wnet = json.loads((dest / 'mapped.json').read_text())
        wrapper = collections.Counter(c['type'] for c in
                                      wnet['modules']['pnr_top']['cells'].values())
        result['dut_cells'] = dict(dut)
        result['dut'] = base.summarize(dut)
        result['wrapper_total_cells'] = dict(wrapper)
        result['wrapper_total'] = base.summarize(wrapper)
        (dest / 'top.cst').write_text(CST)
        run([NEXTPNR, '--json', 'mapped.json', '--write', 'pnr.json',
             '--device', DEVICE, '--vopt', f'family={FAMILY}',
             '--vopt', 'cst=top.cst', '--freq', str(int(freq)),
             '--seed', '1', '--log', 'nextpnr.log'], dest, 'pnr_console.log', env)
        log = (dest / 'nextpnr.log').read_text(errors='replace')
        freqs = [float(x) for x in re.findall(
            r'Max frequency for clock[^\n]*?:\s*([\d.]+)\s*MHz', log)]
        util = re.search(r'Device utilisation:(.*?)\n\n', log, re.S)
        result['fmax_mhz'] = freqs
        result['fmax_min'] = min(freqs) if freqs else None
        if util:
            result['utilisation'] = util.group(1).strip()
        r4 = re.search(r'\bLUT4:\s+(\d+)', log)
        result['routed_lut4'] = int(r4.group(1)) if r4 else None
        res_source = dut if dut else wrapper
        timing_ok = (result['fmax_min'] is not None and result['fmax_min'] >= freq)
        result['resource_source'] = 'dut' if dut else 'wrapper_upper_bound'
        result['gates'] = dict(timing_ok=timing_ok,
                               lut=base.summarize(res_source)['lut1_4'],
                               ff=base.summarize(res_source)['ff'],
                               dsp=base.summarize(res_source)['dsp'],
                               bram=base.summarize(res_source)['bram'])
        result['status'] = 'PASS' if timing_ok else 'FAIL_TIMING'
    except Exception as exc:
        result['error'] = repr(exc)
    (dest / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    (outroot / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--only', nargs='*')
    p.add_argument('--list', action='store_true')
    p.add_argument('--freq', type=float, default=DEFAULT_FREQ,
                   help='target clock frequency in MHz (default 50.0)')
    a = p.parse_args()
    if a.list:
        for s in base.SPECS:
            print(s['req'], s['case'], s['top'], s.get('params'))
        return
    env = os.environ.copy()
    env['PATH'] = (str(CAD / 'lib') + os.pathsep + str(CAD / 'bin') +
                   os.pathsep + env.get('PATH', ''))
    results = []
    for spec in base.SPECS:
        if a.only and spec['req'] not in a.only and spec['case'] not in a.only:
            continue
        r = audit_138k(spec, env, freq=a.freq)
        results.append(r)
        print(json.dumps({k: r[k] for k in
                          ('req', 'case', 'status', 'error') if k in r},
                         ensure_ascii=False), flush=True)
        if 'dut' in r:
            print('   dut:', r['dut'], 'fmax:', r.get('fmax_min'),
                  'gates:', r.get('gates'), flush=True)
    n_pass = sum(1 for r in results if r['status'] == 'PASS')
    print(f'TOTAL {n_pass}/{len(results)} PASS')


if __name__ == '__main__':
    main()
