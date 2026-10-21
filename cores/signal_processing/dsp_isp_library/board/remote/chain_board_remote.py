"""Runs ON the remote board: per-case UART inject + FX2 capture + verify for
the dsp_chain_harness image. Faithful port of run_board.py's hardware loop —
all gates/identity checks are enforced by the local build (run.py --build)
and the local driver before upload; this runner performs the physical part.

The build directory is uploaded intact (frozen protocol.py + reference models
included), so verification here uses the same frozen oracle as local runs.
Writes SRAM only. Emits out/verdict.json + per-case folders.
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


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--build', required=True, help='Uploaded build dir containing chain.fs + protocol.py')
    p.add_argument('--out', required=True)
    p.add_argument('--uart', default='/dev/ttyUSB1')
    p.add_argument('--board', default='tangprimer20k')
    p.add_argument('--vector-json', type=Path)
    a = p.parse_args()
    build = Path(a.build).resolve()
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=True)

    sim = json.loads((build / 'simulation_summary.json').read_text())
    spec = importlib.util.spec_from_file_location('frozen_chain_protocol', build / 'protocol.py')
    protocol = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(protocol)
    cases, make_packet, oracle, verify = (protocol.cases, protocol.make_packet,
                                        protocol.oracle, protocol.verify)
    latency = sim['dc_latency']
    stats_latency = sim.get('stats_latency', 1)
    verify_kwargs = dict(dc_latency=latency)
    if 'stats_latency' in sim:
        verify_kwargs['stats_latency'] = stats_latency

    image = build / 'chain.fs'
    sha = hashlib.sha256(image.read_bytes()).hexdigest()
    verdict = dict(status='FAIL', image=str(image), sha256=sha,
                   dc_latency=latency, stats_latency=stats_latency,
                   chain_latency=latency + stats_latency,
                   remote='bianbu: openFPGALoader + ttyUSB1 + fx2lafw', cases=[])
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
            work = cases()
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
                words = list(initial)
                if not a.vector_json:
                    for i in range(4, len(words)):
                        words[i] = secrets.randbelow(65536) - 32768
                packet = make_packet(tag, config, words, stall)
                (folder / 'request.bin').write_bytes(packet)
                (folder / 'expected.json').write_text(json.dumps(
                    dict(tag=tag, config=config, words=words, stall=stall,
                         outputs=oracle(config, words)), indent=2))
                with (folder / 'capture.log').open('w') as log:
                    started = time.monotonic()
                    cap = subprocess.Popen(
                        ['sigrok-cli', '-l', '4', '-d', 'fx2lafw',
                         '--config', 'samplerate=4m', '--samples', '4000000',
                         '-o', str(folder / 'capture.sr')],
                        stdout=log, stderr=subprocess.STDOUT)
                    # Positive transfer evidence instead of a guessed delay.
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
                result = verify(data, tag, config, words, stall, **verify_kwargs)
                bad = bytearray(data); bad[-1] ^= 1
                try:
                    verify(bad, tag, config, words, stall, **verify_kwargs)
                except AssertionError:
                    pass
                else:
                    raise RuntimeError('Checker accepted corrupted payload')
                result['negative_check'] = 'PASS'
                (folder / 'verdict.json').write_text(json.dumps(result, indent=2))
                verdict['cases'].append(result)
                print('PASS chain', index, result, flush=True)
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
