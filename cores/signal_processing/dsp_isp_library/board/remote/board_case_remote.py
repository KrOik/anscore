"""Runs ON the remote board: generic per-case UART inject + FX2 capture +
verify for dsp_isp_library harness images.

Modes (auto-detected from the uploaded build dir):
- chain mode: build dir contains chain.fs + frozen protocol.py
  (dsp_chain_harness evidence builds; protocol.py bundled, models bundled).
- block mode: build dir contains block.fs; shared block_harness/protocol.py
  and its model deps are uploaded under REMOTE_BASE/{block_harness,isp,dsp}
  so its internal sys.path layout resolves.

Faithful port of run_board.py / run_block_board.py hardware loops. SRAM only.
"""
import argparse, hashlib, importlib.util, json, secrets, subprocess, sys, time
from pathlib import Path

import serial


def parse_decode(text):
    import re
    result = bytearray()
    for line in text.splitlines():
        if not line.strip():
            continue
        m = re.fullmatch(r'uart-\d+:\s*([0-9A-Fa-f]{2})\s*', line)
        if m is None:
            raise ValueError('Unexpected decoder output: ' + line)
        result.append(int(m.group(1), 16))
    return bytes(result)


def load_protocol(build, support_root):
    """Return (cases_fn, make_packet, oracle, verify, mode)."""
    frozen = build / 'protocol.py'
    if (build / 'chain.fs').exists() and frozen.exists():
        spec = importlib.util.spec_from_file_location('frozen_protocol', frozen)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.cases, mod.make_packet, mod.oracle, mod.verify, 'chain'
    if (build / 'image.fs').exists() and frozen.exists():
        # Frozen protocol imports its frozen models (csc_model, model) by name;
        # the build dir is self-contained, so expose it directly.
        sys.path.insert(0, str(build))
        spec = importlib.util.spec_from_file_location('frozen_protocol', frozen)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.cases, mod.make_packet, mod.oracle, mod.verify, 'image'
    if (build / 'dstream.fs').exists() and frozen.exists():
        # dsp_stream_harness build: frozen protocol.py reads variant.json from
        # its own directory; models are frozen siblings (flat filenames).
        spec = importlib.util.spec_from_file_location('frozen_protocol', frozen)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.cases, mod.make_packet, mod.oracle, mod.verify, 'dstream'
    if (build / 'drate.fs').exists() and frozen.exists():
        # dsp_rate_harness build (BLK2/RES2 variable output count); frozen
        # protocol.py reads variant.json from its own directory.
        spec = importlib.util.spec_from_file_location('frozen_protocol', frozen)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.cases, mod.make_packet, mod.oracle, mod.verify, 'drate'
    shared = support_root / 'board' / 'block_harness' / 'protocol.py'
    spec = importlib.util.spec_from_file_location('shared_protocol', shared)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.cases, mod.make_packet, mod.oracle, mod.verify, 'block'


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--build', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--support', default='/tmp/dsp_isp_remote_support')
    p.add_argument('--uart', default='/dev/ttyUSB1')
    p.add_argument('--board', default='tangprimer20k')
    p.add_argument('--vector-json', type=Path)
    a = p.parse_args()
    build = Path(a.build).resolve()
    out = Path(a.out).resolve()
    support = Path(a.support).resolve()
    out.mkdir(parents=True, exist_ok=True)

    cases, make_packet, oracle, verify, mode = load_protocol(build, support)
    sim = json.loads((build / 'simulation_summary.json').read_text())

    if mode == 'chain':
        latency = sim['dc_latency']
        stats_latency = sim.get('stats_latency', 1)
        image = build / 'chain.fs'
        verify_kwargs = dict(dc_latency=latency)
        if 'stats_latency' in sim:
            verify_kwargs['stats_latency'] = stats_latency
    elif mode == 'image':
        bits = sim['bits']
        padding = sim['padding']
        image = build / 'image.fs'
        verify_kwargs = {}
    elif mode == 'dstream':
        image = build / 'dstream.fs'
        verify_kwargs = {}
    elif mode == 'drate':
        image = build / 'drate.fs'
        verify_kwargs = {}
    else:
        core = {'dc': 0, 'csc': 1, 'identity': 2}[sim['core']]
        bits = sim['bits']
        latency = sim.get('latency', 1)
        image = build / 'block.fs'
        verify_kwargs = {}

    sha = hashlib.sha256(image.read_bytes()).hexdigest()
    verdict = dict(status='FAIL', image=str(image), sha256=sha, mode=mode,
                   remote='bianbu: openFPGALoader + ttyUSB1 + fx2lafw', cases=[])
    if mode == 'block':
        verdict.update(core=sim['core'], bits=bits, latency=latency)
    elif mode == 'image':
        verdict.update(bits=bits, padding=padding)
    elif mode == 'dstream':
        verdict.update(core=sim.get('core'), core_name=sim.get('core_name'))
    elif mode == 'drate':
        verdict.update(core=sim.get('core'), core_name=sim.get('core_name'))
    else:
        verdict.update(dc_latency=latency, stats_latency=stats_latency,
                       chain_latency=latency + stats_latency)
    cap = None
    try:
        with (out / 'program.log').open('w') as log:
            r = subprocess.run(['openFPGALoader', '-b', a.board, str(image)],
                               stdout=log, stderr=subprocess.STDOUT, timeout=180)
        if r.returncode:
            raise RuntimeError('Programming failed; SRAM state unconfirmed')
        verdict['sram_programmed'] = True

        with serial.Serial(a.uart, 115200, timeout=0, write_timeout=1) as port:
            (out / 'serial_before_diagnostic.bin').write_bytes(port.read(65536))
            if mode == 'chain':
                work = cases()
            elif mode == 'image':
                work = cases(bits)
            elif mode == 'dstream':
                work = cases()
            elif mode == 'drate':
                work = cases()
            else:
                work = cases(core, bits)
            if a.vector_json:
                saved = json.loads(a.vector_json.read_text())
                saved = saved if isinstance(saved, list) else [saved]
                if not saved:
                    raise ValueError('Empty host vector matrix')
                work = [(i, item['config'], item['words'], item['stall']) for i, item in enumerate(saved)]
                verdict['replayed_host_vector'] = str(a.vector_json.resolve())
            for index, (_, config, initial, stall) in enumerate(work):
                folder = out / f'case_{index:02d}'
                folder.mkdir()
                tag = secrets.randbits(32)
                if mode == 'image' and not a.vector_json:
                    words = [0 if i % 7 == 0 else secrets.randbits(3 * bits) for i in range(64)]
                else:
                    words = list(initial)
                if not a.vector_json and mode not in ('image', 'dstream', 'drate'):
                    if mode == 'chain':
                        for i in range(4, len(words)):
                            words[i] = secrets.randbelow(65536) - 32768
                    else:
                        for i in range(4, len(words)):
                            words[i] = secrets.randbits(32 if core == 2 else (3 * bits if core else 16))
                packet = make_packet(tag, config, words, stall)
                (folder / 'request.bin').write_bytes(packet)
                if mode == 'chain':
                    exp = oracle(config, words)
                elif mode == 'image':
                    exp = oracle(bits, config, words, padding)
                elif mode in ('dstream', 'drate'):
                    exp = oracle(config, words)
                else:
                    exp = oracle(core, bits, config, words)
                (folder / 'expected.json').write_text(json.dumps(
                    dict(tag=tag, config=config, words=words, stall=stall,
                         outputs=exp), indent=2))
                with (folder / 'capture.log').open('w') as log:
                    started = time.monotonic()
                    cap = subprocess.Popen(
                        ['sigrok-cli', '-l', '4', '-d', 'fx2lafw',
                         '--config', 'samplerate=4m', '--samples', '4000000',
                         '-o', str(folder / 'capture.sr')],
                        stdout=log, stderr=subprocess.STDOUT)
                    while 'receive_transfer():' not in (folder / 'capture.log').read_text(errors='replace'):
                        if cap.poll() is not None or time.monotonic() - started > 15:
                            raise RuntimeError('No live FX2 acquisition transfer observed')
                        time.sleep(0.01)
                    send_start = time.monotonic()
                    for byte in packet:
                        if port.write(bytes([byte])) != 1:
                            raise RuntimeError('Short serial write')
                        time.sleep(0.0015)
                    port.flush()
                    send_end = time.monotonic()
                    cap.wait(timeout=60)
                    (folder / 'timing.json').write_text(json.dumps(
                        dict(acquisition_ready_seconds=send_start - started,
                             send_seconds=send_end - send_start), indent=2))
                    (folder / 'serial_diagnostic.bin').write_bytes(port.read(65536))
                if cap.returncode:
                    raise RuntimeError('FX2 capture failed')
                r = subprocess.run(
                    ['sigrok-cli', '-i', str(folder / 'capture.sr'), '-P',
                     'uart:rx=D0:baudrate=115200:format=hex', '-A', 'uart=rx-data'],
                    text=True, capture_output=True, timeout=120)
                (folder / 'decoded.txt').write_text(r.stdout)
                (folder / 'decode_stderr.log').write_text(r.stderr)
                if r.returncode:
                    raise RuntimeError('Decode failed')
                data = parse_decode(r.stdout)
                (folder / 'decoded.bin').write_bytes(data)
                if mode == 'chain':
                    def call_verify(d):
                        return verify(d, tag, config, words, stall, **verify_kwargs)
                elif mode == 'image':
                    def call_verify(d):
                        return verify(d, tag, config, words, bits, stall, padding)
                elif mode == 'dstream':
                    def call_verify(d):
                        return verify(d, tag, config, words, stall)
                elif mode == 'drate':
                    def call_verify(d):
                        return verify(d, tag, config, words, stall)
                else:
                    def call_verify(d):
                        return verify(d, tag, config, words, core, bits, stall, latency=latency)
                result = call_verify(data)
                bad = bytearray(data); bad[-1] ^= 1
                try:
                    call_verify(bad)
                except AssertionError:
                    pass
                else:
                    raise RuntimeError('Checker accepted corrupted payload')
                result['negative_check'] = 'PASS'
                (folder / 'verdict.json').write_text(json.dumps(result, indent=2))
                verdict['cases'].append(result)
                print('PASS', mode, index, result, flush=True)
            (out / 'serial_after_diagnostic.bin').write_bytes(port.read(65536))
        verdict['status'] = 'PASS'
    except Exception as exc:
        verdict['error'] = repr(exc)
    finally:
        if cap is not None and cap.poll() is None:
            cap.terminate(); cap.wait(timeout=10)
        (out / 'verdict.json').write_text(json.dumps(verdict, indent=2) + '\n')
    print(json.dumps(verdict, indent=2))
    return int(verdict['status'] != 'PASS')


if __name__ == '__main__':
    sys.exit(main())
