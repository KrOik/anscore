"""Simulate external SCL1 frames, then optionally synthesize/route/pack.

Mirrors board/image_harness/run.py.  No hardware access here."""
import argparse, collections, datetime, hashlib, json, os, re, random
import shutil, struct, subprocess
from pathlib import Path
from protocol import (HERE, LIB, ROOT, MAXP, cases, make_packet, oracle,
                      verify, make_frame, frame_to_words, HEADER_SIZE)


def audit_warnings(dest):
    patterns = (r'found logic loop', r'(?<!no )latch inferred',
                r'inferred latch', r'\$dlatch',
                r'no clocks? (found|defined|constrained)', r'unconstrained',
                r'no (timing|clock) constraints?', r'failed to (match|constrain)',
                r'not constrained')
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
    p.add_argument('--build', action='store_true')
    a = p.parse_args()
    dest = HERE / 'evidence' / ('scale_%s' %
        datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    dest.mkdir(parents=True)
    cad = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
    env = dict(os.environ)
    env['PATH'] = str(cad / 'bin') + os.pathsep + str(cad / 'lib') + \
        os.pathsep + env['PATH']

    files = [HERE / 'scale_harness.v', HERE / 'tb_scale.sv',
             LIB / 'isp/scale/scale_poly6_stream.v',
             LIB / 'isp/scale/scale_lanczos3.vh',
             ROOT / 'cores/communication/primitives/src/uart_rx.v',
             ROOT / 'cores/communication/primitives/src/uart_tx.v']
    for f in files:
        shutil.copy2(f, dest / f.name)
    for f in [HERE / 'run.py', HERE / 'protocol.py',
              LIB / 'isp/scale/scale_model.py']:
        shutil.copy2(f, dest / f.name)
    shutil.copy2(LIB / 'board/uart_injection_probe.cst', dest / 'top.cst')
    (dest / 'hashes.json').write_text(json.dumps(
        {str(f): hashlib.sha256(f.read_bytes()).hexdigest()
         for f in files}, indent=2))

    rng = random.Random(20260925)
    stim = ''
    negative = []
    frames = []
    for i, c in enumerate(cases()):
        dims = c['dims']
        tag = 0x5C100000 + i
        frame = make_frame(rng, dims[0], dims[1], c['kind'])
        words = frame_to_words(frame)
        packet = make_packet(tag, dims, words, c['stall'])
        nresp = HEADER_SIZE + 4 * dims[2] * dims[3]
        stim += f'{len(packet)} {nresp}\n'
        stim += ''.join(f'{b:02x}\n' for b in packet)
        frames.append((tag, dims, words, c['stall'], c['kind']))
    # negative packets: bad dims / count / stall / pad -> 26-byte error resp
    for j, (tag, dims, cnt, stall, pad) in enumerate([
            (0xBAD60000, (0, 8, 16, 16), 0, 0, 0),        # in_w=0
            (0xBAD60001, (300, 8, 16, 16), 2400, 0, 0),   # in_w>MAXW
            (0xBAD60002, (32, 8, 16, 16), 255, 0, 0),     # count!=in_w*in_h
            (0xBAD60003, (32, 8, 16, 16), 256, 8, 0),     # stall>7
            (0xBAD60004, (32, 8, 80, 60), 256, 0, 0),     # out>MAXP
            (0xBAD60005, (32, 8, 16, 16), 256, 0, 1),     # pad!=0
            ]):
        iw, ih, ow, oh = dims
        pkt = (b'SCL1' + struct.pack('<IHHHHHBB', tag, iw, ih, ow, oh,
                                     cnt, stall, pad))
        stim += f'{len(pkt)} 26\n'
        stim += ''.join(f'{b:02x}\n' for b in pkt)
        negative.append(b'SCR1' + struct.pack('<IHHHHHHBBI', tag,
                        iw, ih, ow, oh, 0, 0, 1, 0, 0))
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
           if f.suffix in ('.v', '.sv') and f.name != 'tb_scale.sv']
    run(['iverilog', '-g2012', '-Wall', '-I.', '-s', 'tb_scale',
         '-o', 'sim.vvp', 'tb_scale.sv', *rtl], 'compile.log')
    run(['vvp', 'sim.vvp', '+stim=stim.txt', '+trace=trace.txt'],
        'simulation.log')
    raw = bytes(int(x, 16)
                for x in (dest / 'trace.txt').read_text().splitlines())
    (dest / 'raw.bin').write_bytes(raw)
    offset = 0
    results = []
    for tag, dims, words, stall, kind in frames:
        nresp = HEADER_SIZE + 4 * dims[2] * dims[3]
        report = raw[offset:offset + nresp]
        results.append(verify(report, tag, dims, words, stall))
        offset += nresp
        for pos in (0, 4, 8, 20, HEADER_SIZE, HEADER_SIZE + 4, nresp - 1):
            bad = bytearray(report)
            bad[pos] ^= 1
            try:
                verify(bytes(bad), tag, dims, words, stall)
            except AssertionError:
                pass
            else:
                raise AssertionError('mutation accepted')
    for expected in negative:
        got = raw[offset:offset + 26]
        assert got == expected, ('negative packet', got, expected)
        offset += 26
    assert offset == len(raw), 'extra response bytes'
    (dest / 'simulation_summary.json').write_text(json.dumps(
        dict(status='PASS', frames=results, negative_packets=len(negative),
             checker_mutations=7 * len(frames)), indent=2))
    print('SIM PASS', dest, flush=True)

    if not a.build:
        return
    (dest / 'build.ys').write_text(
        'read_verilog -sv -I. ' + ' '.join(rtl) +
        '\nsynth_gowin -family gw2a -top scale_harness -json top.json\nstat\n')
    run(['yosys', '-s', 'build.ys'], 'synthesis.log')
    audit_warnings(dest)
    net = json.loads((dest / 'top.json').read_text())
    cells = collections.Counter(c['type'] for c in
        net['modules']['scale_harness']['cells'].values())
    lut = sum(n for t, n in cells.items()
              if re.fullmatch('LUT[1-4]|ALU', t))
    dsp = sum(n for t, n in cells.items()
              if t.startswith(('MULT', 'PADD', 'ALU54')))
    (dest / 'resources.json').write_text(json.dumps(
        dict(lut=lut, dsp=dsp, cells=dict(cells)), indent=2))
    assert lut <= 15000, 'LUT budget'
    # dsp<=4 shared-image budget does NOT apply to this dedicated test build;
    # the 36-MAC scaler is recorded, not gated.
    run(['nextpnr-himbaechel', '--json', 'top.json', '--write', 'pnr.json',
         '--device', 'GW2A-LV18PG256C8/I7', '--vopt', 'family=GW2A-18',
         '--vopt', 'cst=top.cst', '--freq', '27', '--seed', '1',
         '--log', 'nextpnr.log'], 'route.log')
    text = (dest / 'nextpnr.log').read_text()
    routed = re.search(r'\bLUT4:\s+(\d+)', text)
    freq = re.findall(r'Max frequency for clock[^\n]*?:\s*([\d.]+)\s*MHz',
                      text)
    audit_warnings(dest)
    assert routed and int(routed[1]) <= 15000 and freq and \
        min(map(float, freq)) >= 27, 'route/timing gate'
    py = cad / 'lib/python3.exe'
    py = py if py.exists() else cad / 'bin/python.exe'
    run([str(py), str(cad / 'bin/gowin_pack-script.py'), '-d', 'GW2A-18',
         '-o', 'image.fs', 'pnr.json'], 'pack.log')
    (dest / 'build_summary.json').write_text(json.dumps(dict(
        status='BUILD_PASS_NOT_BOARD', lut=lut, dsp=dsp,
        routed_lut4=int(routed[1]), fmax_mhz=list(map(float, freq)),
        bitstream_sha256=hashlib.sha256(
            (dest / 'image.fs').read_bytes()).hexdigest()), indent=2))
    print('BUILD PASS', dest, flush=True)


if __name__ == '__main__':
    main()
