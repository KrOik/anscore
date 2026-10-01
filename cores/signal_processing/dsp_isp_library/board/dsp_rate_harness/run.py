"""UART simulation then optional synthesis/place/route/pack for
dsp_rate_harness (BLK2/RES2 variable-rate contract).  Produces drate.fs
consumed by board/remote/board_case_remote.py in 'drate' mode.

    python run.py --core resampler --build
"""
import argparse, collections, datetime, hashlib, json, os, re, shutil, struct, subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
LIB = HERE.parents[1]
ROOT = LIB.parents[1]

DDCDUC_RTL = ['dsp/ddcduc/rtl/ddcduc_iq_fir.sv',
              'dsp/ddcduc/rtl/ddcduc_nco.sv',
              'infra/stream/stream_sync_fifo.v']

CORES = {
    'resampler': dict(core=0, rtl=['dsp/resampler/rtl/polyphase_resampler.sv'],
                      models={'dsp/resampler/models/reference.py': 'rs_ref.py'}),
    'hb_decim': dict(core=1, rtl=['dsp/halfband/rtl/halfband_decim.sv'],
                     models={'dsp/halfband/models/reference.py': 'hb_ref.py'}),
    'hb_interp': dict(core=2, rtl=['dsp/halfband/rtl/halfband_interp.sv'],
                      models={'dsp/halfband/models/reference.py': 'hb_ref.py'}),
    'ddc': dict(core=3, rtl=['dsp/ddcduc/rtl/ddc_stream.sv'] + DDCDUC_RTL,
                models={'dsp/ddcduc/models/model.py': 'dd_ref.py'}),
    'duc': dict(core=4, rtl=['dsp/ddcduc/rtl/duc_stream.sv'] + DDCDUC_RTL,
                models={'dsp/ddcduc/models/model.py': 'dd_ref.py'}),
}
SHARED_RTL = ['board/block_harness/block_ram.v']


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--core', choices=sorted(CORES), required=True)
    p.add_argument('--build', action='store_true')
    p.add_argument('--nodsp', action='store_true',
                 help='diagnostic: force LUT multipliers (synth_gowin -nodsp)')
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
    files = ([HERE / 'dsp_rate_harness.v', HERE / 'tb_drate.sv',
              HERE / 'dsp_rate_harness_rom.vh']
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
        core=core_id, core_name=a.core), indent=2))
    work = protocol.cases(core=core_id)
    stim = ''
    for tag, c, words, stall in work:
        packet = protocol.make_packet(tag, c, words, stall)
        outn = len(protocol.oracle(c, words, core_id))
        stim += (f'{len(packet)} {20 + outn * 4}\n'
                 + ''.join(f'{b:02x}\n' for b in packet))

    # Malformed-header rejects: no payload follows (count==0 after reject).
    negative = []
    for tag, c, n, stall, oexp, rsvd, flags in [
            (0xBAD10001, 0, 0, 0, 0, 0, 1),      # count=0
            (0xBAD10002, 0, 65, 0, 0, 0, 1),     # count>64
            (0xBAD10003, 0, 1, 8, 1, 0, 1),      # stall>7
            (0xBAD10004, 0, 1, 0, 200, 0, 1),    # out_expect>128
            (0xBAD10005, 0, 1, 0, 1, 1, 1),      # rsvd!=0
            (0xBAD10006, 0xFFFFFFFF, 1, 0, 1, 0, 8),  # cfg reserved bits
            (0xBAD10007, 15, 1, 0, 1, 0, 8)]:    # cfg index out of range
        payload = struct.pack('<I', 0x12345678) if flags == 8 else b''
        packet = (b'BLK2' + struct.pack('<IIBBBB', tag, c, n, stall, oexp,
                                        rsvd) + payload)
        stim += f'{len(packet)} 20\n' + ''.join(f'{b:02x}\n' for b in packet)
        negative.append(b'RES2' + struct.pack('<IIBBBBI', tag, c, 0, flags,
                                              0, 0, 0))

    # Declared-count mismatch: packet is well-formed, oracle output length is
    # real, but out_expect is forced one higher; the RTL must set flags[5]
    # (count==0 rejection path is NOT taken, data section is emitted).
    tag = 0xBAD20001
    mm_config, mm_words = 0, [0x1111] * 16
    mm_exp = protocol.oracle(mm_config, mm_words, core_id)
    mm_pkt = (b'BLK2' + struct.pack('<IIBBBB', tag, mm_config, len(mm_words),
                                    0, min(len(mm_exp) + 1, 128), 0)
              + struct.pack('<16I', *mm_words))
    stim += (f'{len(mm_pkt)} {20 + len(mm_exp) * 4}\n'
             + ''.join(f'{b:02x}\n' for b in mm_pkt))
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
           and f.name not in ('tb_drate.sv', 'gowin_bsram_sim.v')]
    run(['iverilog', '-g2012', '-Wall', '-I.', '-s', 'tb_drate',
         f'-Ptb_drate.CORE={core_id}', '-o', 'sim.vvp',
         'tb_drate.sv', 'gowin_bsram_sim.v', *rtl], 'compile.log')
    run(['vvp', 'sim.vvp', '+stim=stim.txt', '+trace=trace.txt'],
        'simulation.log')
    raw = bytes(int(x, 16)
                for x in (dest / 'trace.txt').read_text().splitlines())
    (dest / 'raw.bin').write_bytes(raw)
    results = []
    offset = 0
    for tag, c, words, stall in work:
        outn = len(protocol.oracle(c, words, core_id))
        size = 20 + 4 * outn
        report = raw[offset:offset + size]
        results.append(protocol.verify(report, tag, c, words, stall,
                                       core=core_id))
        offset += size
        for pos in [0, 4, 8, 12, 13, 14, 15, 20, len(report) - 1]:
            if pos >= len(report):
                continue
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
    # dynamic negative: out_expect off-by-one must surface flags[5]
    dyn = raw[offset:offset + 20 + 4 * len(mm_exp)]
    offset += 20 + 4 * len(mm_exp)
    if dyn[:4] != b'RES2':
        raise AssertionError('dynamic negative magic')
    dt, dc, dn, dflags, dinc, doutc, _dcyc = struct.unpack('<IIBBBBI',
                                                         dyn[4:20])
    if (dt, dc, dn, dflags, dinc, doutc) != (0xBAD20001, mm_config,
                                            len(mm_words), 0x20,
                                            len(mm_words), len(mm_exp)):
        raise AssertionError(('dynamic negative header', dt, dc, dn, dflags,
                              dinc, doutc))
    if dyn[20:] != struct.pack('<%dI' % len(mm_exp), *mm_exp):
        raise AssertionError('dynamic negative payload changed')
    if offset != len(raw):
        raise AssertionError('extra output')
    (dest / 'simulation_summary.json').write_text(json.dumps(dict(
        status='PASS', core=core_id, core_name=a.core, blocks=results,
        negative_packets=len(negative) + 1,
        mutations_per_block=9), indent=2))
    print('UART SIM PASS', dest, flush=True)
    if not a.build:
        return
    (dest / 'build.ys').write_text(
        'read_verilog -sv -I. ' + ' '.join(rtl)
        + f'\nchparam -set CORE {core_id} dsp_rate_harness'
        + ('\nsynth_gowin -noalu -nodsp -family gw2a -top dsp_rate_harness -json top.json\nstat\n'
           if a.nodsp else
           '\nsynth_gowin -noalu -family gw2a -top dsp_rate_harness -json top.json\nstat\n'))
    run(['yosys', '-s', 'build.ys'], 'synthesis.log')
    net = json.loads((dest / 'top.json').read_text())
    counts = collections.Counter(c['type'] for c in
                                 net['modules']['dsp_rate_harness']['cells'].values())
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
         '-o', 'drate.fs', 'pnr.json'], 'pack.log')
    (dest / 'build_summary.json').write_text(json.dumps(dict(
        status='BUILD_PASS_NOT_BOARD', core=core_id, core_name=a.core,
        nodsp=bool(a.nodsp),
        lut=lut, dsp=dsp, routed_lut4=int(routed[1]),
        fmax_mhz=list(map(float, clocks)),
        bitstream_sha256=hashlib.sha256(
            (dest / 'drate.fs').read_bytes()).hexdigest()), indent=2))
    print('BUILD PASS', dest)


if __name__ == '__main__':
    main()
