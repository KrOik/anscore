"""Simulate external 8x8 frames against an ISP stream core, then optionally
synthesize/route/pack. Produces an image.fs bitstream consumed by
board/remote/board_case_remote.py in 'image' mode (IMG1/IMR1 contract).

    python run.py --core median --build
    python run.py --core conv --build
    python run.py --core gradient --build
"""
import argparse, collections, datetime, hashlib, json, os, re, shutil, struct, subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
LIB = HERE.parents[1]
ROOT = LIB.parents[1]

CORES = {
    'median': dict(core=0, rtl=['isp/median/median_stream.v',
                                'isp/median/median_network.v'],
                   models={'isp/median/model.py': 'median_model.py'}),
    'conv': dict(core=1, rtl=['isp/convolution/convolution_stream.v'],
                 models={'isp/convolution/model.py': 'conv_model.py'}),
    'gradient': dict(core=2, rtl=['isp/gradient/gradient_stream.v'],
                     models={'isp/gradient/model.py': 'grad_model.py'}),
    'morphology': dict(core=3, rtl=['isp/morphology/morphology_stream.v',
                                   'isp/morphology/morph_reduce.v'],
                       models={'isp/morphology/model.py': 'morph_model.py'}),
    'bayer': dict(core=4, rtl=['isp/bayer/rtl/bayer_demosaic.sv'],
                  models={'isp/bayer/models/reference.py': 'bayer_reference.py'}),
    # Delivery bundle, not a leaf core: chains/morph_median composes the two
    # board-verified leaves above (morphology + median) behind one port contract.
    'morph_median': dict(core=5, bundle=True,
                         rtl=['chains/morph_median/morph_median_stream.v',
                              'isp/morphology/morphology_stream.v',
                              'isp/morphology/morph_reduce.v',
                              'isp/median/median_stream.v',
                              'isp/median/median_network.v'],
                         models={'isp/morphology/model.py': 'morph_model.py',
                                 'isp/median/model.py': 'median_model.py'}),
}
SHARED_RTL = ['infra/window/stream_window.v',
              'infra/window/stream_window_padded.v',
              'board/block_harness/block_ram.v']


def audit_warnings(dest):
    patterns = (r'found logic loop', r'(?<!no )latch inferred', r'inferred latch',
                r'\$dlatch', r'no clocks? (found|defined|constrained)',
                r'unconstrained', r'no (timing|clock) constraints?',
                r'failed to (match|constrain)', r'not constrained')
    findings = []
    for name in ('synthesis.log', 'route.log', 'nextpnr.log'):
        path = dest / name
        if path.exists():
            for line in path.read_text(errors='replace').splitlines():
                if any(re.search(p, line, re.I) for p in patterns):
                    findings.append(dict(log=name, line=line))
    (dest / 'warning_audit.json').write_text(json.dumps(
        dict(status='FAIL' if findings else 'PASS', findings=findings),
        indent=2))
    assert not findings, ('strict warning gate', findings)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--core', choices=sorted(CORES), required=True)
    p.add_argument('--bits', type=int, choices=(8, 10), default=8)
    p.add_argument('--padding', type=int, choices=(0, 1), default=1)
    p.add_argument('--build', action='store_true')
    a = p.parse_args()
    import protocol
    sel = CORES[a.core]
    core_id = sel['core']
    dest = (HERE / 'evidence' /
            f'{a.core}{a.bits}_pad{a.padding}_'
            f'{datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f")}')
    dest.mkdir(parents=True)
    cad = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
    env = dict(os.environ)
    env['PATH'] = (str(cad / 'bin') + os.pathsep + str(cad / 'lib')
                   + os.pathsep + env['PATH'])
    files = ([HERE / 'isp_stream_harness.v', HERE / 'tb_isp_stream.sv']
             + [LIB / s for s in sel['rtl'] + SHARED_RTL]
             + [ROOT / 'cores/image_processing/window/sim/gowin_bsram_sim.v',
                ROOT / 'cores/communication/primitives/src/uart_rx.v',
                ROOT / 'cores/communication/primitives/src/uart_tx.v'])
    for f in files:
        shutil.copy2(f, dest / f.name)
    for f in [HERE / 'run.py', HERE / 'protocol.py']:
        shutil.copy2(f, dest / f.name)
    for src, alias in sel['models'].items():
        shutil.copy2(LIB / src, dest / alias)
    shutil.copy2(LIB / 'board/uart_injection_probe.cst', dest / 'top.cst')
    (dest / 'hashes.json').write_text(json.dumps(
        {str(f): hashlib.sha256(f.read_bytes()).hexdigest() for f in files},
        indent=2))
    (dest / 'variant.json').write_text(json.dumps(dict(
        core=core_id, core_name=a.core, bits=a.bits, padding=a.padding),
        indent=2))
    frames = protocol.cases(a.bits, core=core_id)
    stim = ''
    negative = []
    for tag, c, w, stall in frames:
        packet = protocol.make_packet(tag, c, w, stall)
        stim += (f'{len(packet)} 276\n'
                 + ''.join(f'{b:02x}\n' for b in packet))
    # config=0 is a VALID config for these cores (unlike csc_morphology where
    # mask=0 is illegal), so both invalid-config negatives use high bits set.
    for tag, c, count, stall, flag in [(0xBAD10001, 32, 0, 0, 1),
                                       (0xBAD10002, 32, 63, 0, 1),
                                       (0xBAD10003, 32, 64, 8, 1),
                                       (0xBAD10004, 0xF0000000, 64, 0, 8),
                                       (0xBAD10005, 0x80000020, 64, 0, 8)]:
        packet = (b'IMG1' + struct.pack('<IIBB', tag, c, count, stall)
                  + (bytes(256) if flag == 8 else b''))
        stim += f'{len(packet)} 20\n' + ''.join(f'{b:02x}\n' for b in packet)
        negative.append(b'IMR1' + struct.pack('<IIBBBBI', tag, c, 0, flag, 0, 0, 0))
    (dest / 'stim.txt').write_text(stim)

    def run(command, log):
        command = [shutil.which(command[0], path=env['PATH']) or command[0],
                   *command[1:]]
        with (dest / log).open('w') as f:
            f.write('$ ' + ' '.join(command) + '\n')
            f.flush()
            r = subprocess.run(command, cwd=dest, env=env, stdout=f,
                               stderr=subprocess.STDOUT)
        if r.returncode:
            raise RuntimeError(f'{log} failed; {dest}')

    rtl = [f.name for f in files
           if f.suffix in ('.v', '.sv')
           and f.name not in ('tb_isp_stream.sv', 'gowin_bsram_sim.v')]
    run(['iverilog', '-g2012', '-Wall', '-I.', '-s', 'tb_isp_stream',
         f'-Ptb_isp_stream.CORE={core_id}', f'-Ptb_isp_stream.BITS={a.bits}',
         f'-Ptb_isp_stream.PAD_MODE={a.padding}', '-o', 'sim.vvp',
         'tb_isp_stream.sv', 'gowin_bsram_sim.v', *rtl], 'compile.log')
    run(['vvp', 'sim.vvp', '+stim=stim.txt', '+trace=trace.txt'],
        'simulation.log')
    raw = bytes(int(x, 16) for x in (dest / 'trace.txt').read_text().splitlines())
    (dest / 'raw.bin').write_bytes(raw)
    offset = 0
    results = []
    for tag, c, w, stall in frames:
        report = raw[offset:offset + 276]
        results.append(protocol.verify(report, tag, c, w, a.bits, stall,
                                       a.padding, core=core_id))
        offset += 276
        for pos in (0, 4, 8, 12, 13, 14, 15, 20, 23, 275):
            bad = bytearray(report)
            bad[pos] ^= 1
            try:
                protocol.verify(bad, tag, c, w, a.bits, stall, a.padding,
                                core=core_id)
            except AssertionError:
                pass
            else:
                raise AssertionError('mutation accepted')
    for expected in negative:
        assert raw[offset:offset + 20] == expected, (
            'negative packet', raw[offset:offset + 20], expected)
        offset += 20
    assert offset == len(raw), 'extra response bytes'
    (dest / 'simulation_summary.json').write_text(json.dumps(dict(
        status='PASS', core=core_id, core_name=a.core, bits=a.bits,
        padding=a.padding, frames=results, negative_packets=5,
        checker_mutations=10 * len(frames)), indent=2))
    print('SIM PASS', dest, flush=True)
    if not a.build:
        return
    (dest / 'build.ys').write_text(
        'read_verilog -sv -I. ' + ' '.join(rtl)
        + f'\nchparam -set CORE {core_id} -set BITS {a.bits} -set PAD_MODE {a.padding} isp_stream_harness'
        + '\nsynth_gowin -noalu -family gw2a -top isp_stream_harness -json top.json\nstat\n')
    run(['yosys', '-s', 'build.ys'], 'synthesis.log')
    audit_warnings(dest)
    net = json.loads((dest / 'top.json').read_text())
    cells = collections.Counter(
        c['type'] for c in net['modules']['isp_stream_harness']['cells'].values())
    lut = sum(n for t, n in cells.items() if re.fullmatch('LUT[1-4]|ALU', t))
    dsp = sum(n for t, n in cells.items()
              if t.startswith(('MULT', 'PADD', 'ALU54')))
    (dest / 'resources.json').write_text(json.dumps(
        dict(lut=lut, dsp=dsp, cells=dict(cells)), indent=2))
    assert lut <= 15000 and dsp <= 4
    run(['nextpnr-himbaechel', '--json', 'top.json', '--write', 'pnr.json',
         '--device', 'GW2A-LV18PG256C8/I7', '--vopt', 'family=GW2A-18',
         '--vopt', 'cst=top.cst', '--freq', '27', '--seed', '1',
         '--log', 'nextpnr.log'], 'route.log')
    text = (dest / 'nextpnr.log').read_text()
    routed = re.search(r'\bLUT4:\s+(\d+)', text)
    freq = re.findall(r'Max frequency for clock[^\n]*?:\s*([\d.]+)\s*MHz', text)
    audit_warnings(dest)
    assert routed and int(routed[1]) <= 15000 and freq and min(map(float, freq)) >= 27, 'route/timing gate'
    py = cad / 'lib/python3.exe'
    py = py if py.exists() else cad / 'bin/python.exe'
    run([str(py), str(cad / 'bin/gowin_pack-script.py'), '-d', 'GW2A-18',
         '-o', 'image.fs', 'pnr.json'], 'pack.log')
    (dest / 'build_summary.json').write_text(json.dumps(dict(
        status='BUILD_PASS_NOT_BOARD', core=core_id, core_name=a.core,
        bits=a.bits, padding=a.padding, lut=lut, dsp=dsp,
        routed_lut4=int(routed[1]), fmax_mhz=list(map(float, freq)),
        bitstream_sha256=hashlib.sha256(
            (dest / 'image.fs').read_bytes()).hexdigest()), indent=2))
    print('BUILD PASS', dest, flush=True)


if __name__ == '__main__':
    main()
