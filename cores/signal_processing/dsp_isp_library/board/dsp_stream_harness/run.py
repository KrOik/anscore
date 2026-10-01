"""UART simulation then optional synthesis/place/route/pack for
dsp_stream_harness.  Produces dstream.fs consumed by
board/remote/board_case_remote.py in 'dstream' mode (BLK1/RES1 contract).

    python run.py --core farrow --build
"""
import argparse, collections, datetime, hashlib, json, os, re, shutil, struct, subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
LIB = HERE.parents[1]
ROOT = LIB.parents[1]

CORES = {
    'farrow': dict(core=0, rtl=['dsp/farrow/rtl/farrow_cubic_stream.sv'],
                   models={'dsp/farrow/models/reference.py': 'farrow_reference.py'}),
    'agc': dict(core=1, rtl=['dsp/agc/rtl/agc_stream.sv'],
                models={'dsp/agc/models/reference.py': 'agc_reference.py'}),
    'biquad': dict(core=2, rtl=['dsp/biquad/rtl/biquad_sos_stream.sv'],
                   models={'dsp/biquad/models/reference.py': 'biquad_reference.py'},
                   extra=['board/dsp_stream_harness/dsp_stream_harness_biquad_rom.vh']),
    'lms': dict(core=3, rtl=['dsp/lms/rtl/lms_stream.sv',
                             'infra/fixedpoint/rtl/recip_div.sv'],
                models={'dsp/lms/models/lms_model.py': 'lms_model.py'}),
    'mag_squared': dict(core=4, rtl=['dsp/spectrum/rtl/mag_squared.sv'],
                        models={'dsp/spectrum/models/reference.py': 'spectrum_reference.py'}),
    # Delivery bundle: two AGC lanes -> mag_squared.  Composition only; every leaf
    # is already board-verified on its own.
    'agc_power': dict(core=5, bundle=True,
                      rtl=['chains/agc_power/agc_power_stream.v',
                           'dsp/agc/rtl/agc_stream.sv',
                           'dsp/spectrum/rtl/mag_squared.sv'],
                      models={'dsp/agc/models/reference.py': 'agc_reference.py',
                              'dsp/spectrum/models/reference.py':
                              'spectrum_reference.py'}),
}
SHARED_RTL = ['board/block_harness/block_ram.v']


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--core', choices=sorted(CORES), required=True)
    p.add_argument('--build', action='store_true')
    a = p.parse_args()
    import protocol
    sel = CORES[a.core]
    core_id = sel['core']
    dest = (HERE / 'evidence'
            / f'{a.core}_{datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f")}')
    dest.mkdir(parents=True)
    cad = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
    env = dict(os.environ)
    env['PATH'] = (str(cad / 'bin') + os.pathsep + str(cad / 'lib')
                   + os.pathsep + env['PATH'])
    # the biquad ROM include is preprocessed regardless of CORE, so it must be
    # present in every build dir.
    files = ([HERE / 'dsp_stream_harness.v', HERE / 'tb_dstream.sv',
              HERE / 'dsp_stream_harness_biquad_rom.vh']
             + [LIB / s for s in sel['rtl'] + SHARED_RTL]
             + [LIB / s for s in sel.get('extra', [])]
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
        core=core_id, core_name=a.core), indent=2))
    work = protocol.cases(core=core_id)
    stim = ''
    negative = []
    for tag, c, words, stall in work:
        packet = protocol.make_packet(tag, c, words, stall)
        stim += (f'{len(packet)} {20 + len(words) * 4}\n'
                 + ''.join(f'{b:02x}\n' for b in packet))
    for tag, c, n, stall, flags in [(0xBAD00001, 0, 0, 0, 1),
                                    (0xBAD00002, 0, 65, 0, 1),
                                    (0xBAD00003, 0, 1, 8, 1),
                                    (0xBAD00004, 0xFFFFFFFF, 1, 0, 8),
                                    (0xBAD00005, 0x80000000, 1, 0, 8)]:
        packet = (b'BLK1' + struct.pack('<IIBB', tag, c, n, stall)
                  + (b'\0' * 4 if flags == 8 else b''))
        stim += f'{len(packet)} 20\n' + ''.join(f'{b:02x}\n' for b in packet)
        negative.append(b'RES1' + struct.pack('<IIBBBBI', tag, c, 0, flags, 0, 0, 0))
    (dest / 'stim.txt').write_text(stim)

    def run(cmd, log):
        cmd = [shutil.which(cmd[0], path=env['PATH']) or cmd[0], *cmd[1:]]
        with (dest / log).open('w') as f:
            f.write('$ ' + ' '.join(str(c) for c in cmd) + '\n')
            f.flush()
            r = subprocess.run([str(c) for c in cmd], cwd=dest, env=env,
                               stdout=f, stderr=subprocess.STDOUT)
        if r.returncode:
            raise RuntimeError(f'{log} failed; {dest}')

    rtl = [f.name for f in files
           if f.suffix in ('.v', '.sv')
           and f.name not in ('tb_dstream.sv', 'gowin_bsram_sim.v')]
    run(['iverilog', '-g2012', '-Wall', '-I.', '-s', 'tb_dstream',
         f'-Ptb_dstream.CORE={core_id}', '-o', 'sim.vvp',
         'tb_dstream.sv', 'gowin_bsram_sim.v', *rtl], 'compile.log')
    run(['vvp', 'sim.vvp', '+stim=stim.txt', '+trace=trace.txt'],
        'simulation.log')
    raw = bytes(int(x, 16)
                for x in (dest / 'trace.txt').read_text().splitlines())
    (dest / 'raw.bin').write_bytes(raw)
    results = []
    offset = 0
    for tag, c, words, stall in work:
        size = 20 + 4 * len(words)
        report = raw[offset:offset + size]
        results.append(protocol.verify(report, tag, c, words, stall,
                                       core=core_id))
        offset += size
        # Cycle-counter bytes (16..19) are only mutated for cores whose
        # protocol has an exact elastic-latency cycle model; serial engines
        # (biquad/lms) keep bounds checking instead (see protocol.py).
        mpos = [0, 4, 8, 12, 13, 14, 15, 16, 20, len(report) - 1]
        if core_id not in protocol.EXACT_LATENCY:
            mpos = [p for p in mpos if not 16 <= p <= 19]
        for pos in mpos:
            bad = bytearray(report)
            bad[pos] ^= 1
            try:
                protocol.verify(bad, tag, c, words, stall, core=core_id)
            except AssertionError:
                pass
            else:
                raise AssertionError('corruption accepted')
    for expected in negative:
        if raw[offset:offset + 20] != expected:
            raise AssertionError(('negative response', raw[offset:offset + 20],
                                  expected))
        offset += 20
    if offset != len(raw):
        raise AssertionError('extra output')
    (dest / 'simulation_summary.json').write_text(json.dumps(dict(
        status='PASS', core=core_id, core_name=a.core, blocks=results,
        negative_packets=len(negative),
        mutations_per_block=10), indent=2))
    print('UART SIM PASS', dest, flush=True)
    if not a.build:
        return
    (dest / 'build.ys').write_text(
        'read_verilog -sv -I. ' + ' '.join(rtl)
        + f'\nchparam -set CORE {core_id} dsp_stream_harness'
        + '\nsynth_gowin -noalu -family gw2a -top dsp_stream_harness -json top.json\nstat\n')
    run(['yosys', '-s', 'build.ys'], 'synthesis.log')
    net = json.loads((dest / 'top.json').read_text())
    counts = collections.Counter(c['type'] for c in
                                 net['modules']['dsp_stream_harness']['cells'].values())
    lut = sum(v for k, v in counts.items() if re.fullmatch(r'LUT[1-4]|ALU', k))
    dsp = sum(v for k, v in counts.items()
              if k.startswith(('MULT', 'PADD', 'ALU54')))
    (dest / 'synthesis_counts.json').write_text(json.dumps(
        dict(lut=lut, dsp=dsp, cells=dict(counts)), indent=2))
    if lut > 15000 or dsp > 4:
        raise AssertionError('resource gate')
    run(['nextpnr-himbaechel', '--json', 'top.json', '--write', 'pnr.json',
         '--device', 'GW2A-LV18PG256C8/I7', '--vopt', 'family=GW2A-18',
         '--vopt', 'cst=top.cst', '--freq', '27', '--seed', '1',
         '--log', 'nextpnr.log'], 'pnr_console.log')
    log = (dest / 'nextpnr.log').read_text()
    routed = re.search(r'\bLUT4:\s+(\d+)', log)
    clocks = re.findall(r'Max frequency for clock[^\n]*?:\s*([\d.]+)\s*MHz', log)
    if (not routed or int(routed[1]) > 15000 or not clocks
            or min(map(float, clocks)) < 27):
        raise AssertionError('route/timing gate')
    python = cad / 'lib/python3.exe'
    if not python.exists():
        python = cad / 'bin/python.exe'
    run([str(python), str(cad / 'bin/gowin_pack-script.py'), '-d', 'GW2A-18',
         '-o', 'dstream.fs', 'pnr.json'], 'pack.log')
    (dest / 'build_summary.json').write_text(json.dumps(dict(
        status='BUILD_PASS_NOT_BOARD', core=core_id, core_name=a.core,
        lut=lut, dsp=dsp, routed_lut4=int(routed[1]),
        fmax_mhz=list(map(float, clocks)),
        bitstream_sha256=hashlib.sha256(
            (dest / 'dstream.fs').read_bytes()).hexdigest()), indent=2))
    print('BUILD PASS', dest)


if __name__ == '__main__':
    main()
