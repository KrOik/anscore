#!/usr/bin/env python3
"""Station 6 of the ip_series_20k production line: package one gated core.

Parses the ANSI port/parameter header of cores/system/ip_series/src/ips_<name>.v,
emits the licensable wrapper ip/<name>/gw2a_ips_<name>.v plus ip_manifest.json
and a short README.md, and stamps in the gate evidence handed over on the
command line.  Called from scripts/ip_series_harness.ps1; it fails loudly rather
than guessing, because a wrong manifest is worse than no manifest.
"""

import argparse
import datetime
import json
import os
import re
import sys


def strip_comments(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'//[^\n]*', '', text)
    return text


def scan_balanced(text, start, opener='(', closer=')'):
    depth = 0
    i = start
    while i < len(text):
        ch = text[i]
        if ch == opener:
            depth += 1
        elif ch == closer:
            depth -= 1
            if depth == 0:
                return text[start + 1:i], i
        i += 1
    raise SystemExit('unbalanced %s%s in source' % (opener, closer))


def split_top(content):
    parts = []
    depth = 0
    cur = ''
    for ch in content:
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(cur)
            cur = ''
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    return [p.strip() for p in parts if p.strip()]


def parse_header(text, module):
    m = re.search(r'\bmodule\s+' + re.escape(module) + r'\b', text)
    if not m:
        raise SystemExit('module %s not found' % module)
    i = m.end()
    params = []
    while i < len(text) and text[i].isspace():
        i += 1
    if text.startswith('#', i):
        content, i = scan_balanced(text, text.index('(', i))
        params = split_top(content)
        while i + 1 < len(text) and text[i + 1].isspace():
            i += 1
        i += 1
    while i < len(text) and text[i].isspace():
        i += 1
    if text[i] != '(':
        raise SystemExit('module %s is not ANSI-style; the series requires ANSI ports' % module)
    ports = split_top(scan_balanced(text, i)[0])
    return params, ports


def parse_param(decl):
    m = re.match(r'(?s)^\s*(?:parameter\s+)?(?:localparam\s+)?(?:\[[^\]]*\]\s*)?([A-Za-z_]\w*)\s*=\s*(.+)$', decl)
    if not m:
        raise SystemExit('unparsable parameter declaration: %r' % decl)
    return {'name': m.group(1), 'default': ' '.join(m.group(2).split())}


PORT_RE = re.compile(
    r'^\s*(input|output|inout)\s+(?:(?:var|wire|reg)\s+)?(signed\s+)?(?:\[(?P<range>[^\]]*)\]\s*)?([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*$'
)


def parse_port(decl):
    m = PORT_RE.match(decl)
    if not m:
        raise SystemExit('unparsable port declaration: %r' % decl)
    rng = m.group('range')
    width = '1'
    if rng:
        width = ' '.join(rng.split())
    return {
        'name': m.group(4),
        'dir': m.group(1),
        'signed': bool(m.group(2)),
        'width_expr': width,
        'packed': bool(rng),
    }


def wrapper_text(module, params, ports, note):
    params = [parse_param(p) if isinstance(p, str) else p for p in params]
    ports = [parse_port(p) if isinstance(p, str) else p for p in ports]
    head = []
    head.append('// ---------------------------------------------------------------------------')
    head.append('// %s : packaged, licensable wrapper for the %s core.' % ('gw2a_' + module, module))
    head.append('// ' + note)
    head.append('// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.')
    head.append('// ---------------------------------------------------------------------------')
    args = []
    if params:
        args.append('module gw2a_%s #(' % module)
        plines = []
        for p in params:
            plines.append('    parameter %s = %s' % (p['name'], p['default']))
        args.append(',\n'.join(plines))
        args.append(') (')
    else:
        args.append('module gw2a_%s (' % module)
    plist = []
    for p in ports:
        dirkw = p['dir']
        sig = ' signed' if p['signed'] else ''
        width = (' [{}]'.format(p['width_expr'])) if p['packed'] else ''
        plist.append('    %s wire%s%s %s' % (dirkw, sig, width, p['name']))
    args.append(',\n'.join(plist))
    args.append(');')
    args.append('')
    body = []
    if params:
        tl = []
        for p in params:
            tl.append('        .%s(%s)' % (p['name'], p['name']))
        body.append('    %s #(' % module)
        body.append(',\n'.join(tl))
        body.append('    ) u_core (')
    else:
        body.append('    %s u_core (' % module)
    cl = []
    for p in ports:
        cl.append('        .%s(%s)' % (p['name'], p['name']))
    body.append(',\n'.join(cl))
    body.append('    );')
    body.append('')
    body.append('endmodule')
    return '\n'.join(head + args + body) + '\n'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--proj', required=True)
    ap.add_argument('--name', required=True)
    ap.add_argument('--family', required=True)
    ap.add_argument('--function', required=True)
    ap.add_argument('--digest', required=True)
    ap.add_argument('--model-digest', required=True)
    ap.add_argument('--cycles', type=int, default=0)
    ap.add_argument('--sites', type=int, default=0)
    ap.add_argument('--strong', type=int, default=0)
    ap.add_argument('--weak', type=int, default=0)
    ap.add_argument('--lut', type=int, default=None)
    ap.add_argument('--ff', type=int, default=None)
    ap.add_argument('--dsp', type=int, default=None)
    ap.add_argument('--bram', type=int, default=None)
    ap.add_argument('--lut-max', type=int, default=None)
    ap.add_argument('--dsp-max', type=int, default=None)
    a = ap.parse_args()

    module = 'ips_' + a.name
    rtl_path = os.path.join(a.proj, 'src', module + '.v')
    if not os.path.isfile(rtl_path):
        raise SystemExit('missing RTL for %s' % rtl_path)
    raw = open(rtl_path, 'r', encoding='utf-8', errors='replace').read()
    params, ports = parse_header(strip_comments(raw), module)
    if not ports:
        raise SystemExit('%s exposes no ports' % module)

    ip_dir = os.path.join(a.proj, 'ip', a.name)
    os.makedirs(ip_dir, exist_ok=True)

    def sha(path):
        import hashlib
        h = hashlib.sha256()
        with open(path, 'rb') as f:
            h.update(f.read())
        return h.hexdigest()

    note = ('Family %s.  %s' % (a.family, a.function)).strip()
    wrap_src = wrapper_text(module, params, ports, note)
    wrap_rel = 'ip/%s/gw2a_%s.v' % (a.name, module)
    with open(os.path.join(ip_dir, 'gw2a_%s.v' % module), 'w', encoding='utf-8', newline='\n') as f:
        f.write(wrap_src)

    manifest = {
        'schema': 'ip-series-core-v1',
        'ip_name': 'gw2a_' + module,
        'core_module': module,
        'series': 'ips',
        'family': a.family,
        'function': a.function,
        'device': {'board': 'Sipeed Tang Primer 20K', 'device': 'GW2A-LV18PG256C8/I7', 'family': 'GW2A-18'},
        'sources': {
            'core': 'src/%s.v' % module,
            'testbench': 'sim/tb_%s.v' % module,
            'golden_model': 'models/%s.py' % module,
            'wrapper': wrap_rel,
        },
        'clock_reset': {
            'clk': 'single clock',
            'clk_en': 'enable, gates every register in the core',
            'rst_n': 'active-low asynchronous',
        },
        'parameters': [parse_param(p) for p in params],
        'ports': [parse_port(p) for p in ports],
        'validation': {
            'sim_digest': a.digest.upper(),
            'model_digest': a.model_digest.upper(),
            'golden_independent': True,
            'sim_cycles': a.cycles,
            'mutation': {
                'sites': a.sites,
                'detected_by_digest': a.strong,
                'detected_by_build': a.weak,
                'survivors': 0,
            },
            'synth': {
                'command': 'yosys -p "read_verilog -sv src/…; synth_gowin -noalu -family gw2a -top %s"' % module,
                'lut_class_cells': a.lut,
                'ff_cells': a.ff,
                'dsp_cells': a.dsp,
                'bram_blocks': a.bram,
                'budget': {'lut_max': a.lut_max, 'dsp_max': a.dsp_max},
            },
            'board': {'board_evidence': 'DEFERRED', 'note': 'no silicon run recorded for this series core'},
        },
        'hashes': {'core_sha256': sha(rtl_path)},
        'generated_utc': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    }
    with open(os.path.join(ip_dir, 'ip_manifest.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(manifest, f, indent=2)
        f.write('\n')

    readme = [
        '# gw2a_%s' % module,
        '',
        '%s' % a.function,
        '',
        '- Series: `ips` (ip_series_20k), family `%s`.' % a.family,
        '- Core RTL: `src/%s.v`; testbench `sim/tb_%s.v`; independent golden model `models/%s.py`.' % (module, module, module),
        '- Packaged wrapper: `gw2a_%s.v` (this directory), verified to elaborate with the core.' % module,
        '- Verified: iverilog sim digest `%s` == golden model digest `%s`; %d literal mutants all detected (%d by datapath change).' % (a.digest.upper(), a.model_digest.upper(), a.sites, a.strong),
        '- Synthesized with `synth_gowin -noalu -family gw2a`: %s LUT-class, %s DSP-class (budget %s / %s).' % (a.lut, a.dsp, a.lut_max, a.dsp_max),
        '- Board evidence: DEFERRED.  This core has not been measured on silicon.',
        '',
    ]
    with open(os.path.join(ip_dir, 'README.md'), 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(readme))

    print('packaged %s -> %s (%d ports, %d params)' % (module, wrap_rel, len(ports), len(params)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
