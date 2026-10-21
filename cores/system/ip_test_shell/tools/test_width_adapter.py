"""Independent packet-byte golden, all width pairs, sparse keep and stalls."""
import hashlib
import json
import os
from pathlib import Path
import random
import subprocess
from datetime import datetime, timezone

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
PROJECT = ROOT / 'cores/system/ip_test_shell'
SOURCES = [PROJECT / 'rtl/stream_width_adapter.v',
           ROOT / 'cores/system/stream_bus_library/rtl/sys_width_converter.v',
           PROJECT / 'tb/tb_stream_width_adapter.v']


def encode(data, keep, user, last):
    return data | keep << 32 | user << 36 | int(last) << 44


def vectors(iw, ow):
    rng = random.Random(20261020 + iw * 100 + ow)
    inputs, outputs = [], []
    for packet in range(128):
        payload = []
        user = packet & 255
        beats = 1 if packet < 16 else rng.randrange(1, 33)
        for beat in range(beats):
            data = rng.getrandbits(iw)
            keep = packet % (1 << (iw // 8)) if packet < 16 else rng.randrange(1 << (iw // 8))
            last = beat == beats - 1
            inputs.append(encode(data, keep, user, last))
            payload.extend((data >> (8 * lane)) & 255 for lane in range(iw // 8) if keep >> lane & 1)
        chunks = [payload[n:n + ow // 8] for n in range(0, len(payload), ow // 8)] or [[]]
        # Empty terminal input after an exactly full output needs an empty boundary beat.
        # Determine from byte-serialized canonical semantics rather than assuming last byte has TLAST.
        final_keep = inputs[-1] >> 32 & 15
        if payload and len(payload) % (ow // 8) == 0 and final_keep == 0:
            chunks.append([])
        for n, chunk in enumerate(chunks):
            outputs.append(encode(sum(v << (8 * k) for k, v in enumerate(chunk)),
                                  (1 << len(chunk)) - 1, user, n == len(chunks) - 1))
    return inputs, outputs


def main():
    out = ROOT / 'artifacts/ip_test_shell_25k' / datetime.now(timezone.utc).strftime('width_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'source_sha256': {
        p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}, 'cases': []}
    try:
        for iw in (8, 16, 24, 32):
            for ow in (8, 16, 24, 32):
                d = out / f'{iw}_{ow}'
                d.mkdir()
                iv, ov = vectors(iw, ow)
                for name, seq in [('input', iv), ('expected', ov)]:
                    (d / (name + '.hex')).write_text(''.join(f'{v:016x}\n' for v in seq))
                cmd = ['iverilog', '-g2012', '-s', 'tb_stream_width_adapter', '-o', str(d / 'test.vvp')]
                cmd += [f'-Ptb_stream_width_adapter.{k}={v}' for k, v in
                        [('IW', iw), ('OW', ow), ('INPUTS', len(iv)), ('OUTPUTS', len(ov))]]
                cmd += list(map(str, SOURCES))
                build = subprocess.run(cmd, cwd=d, capture_output=True, text=True)
                (d / 'compile.log').write_text(build.stdout + build.stderr)
                if build.returncode:
                    raise RuntimeError(f'compile {iw}/{ow}: {build.stderr}')
                run = subprocess.run(['vvp', str(d / 'test.vvp')], cwd=d, capture_output=True, text=True, timeout=60)
                (d / 'run.log').write_text(run.stdout + run.stderr)
                if run.returncode or 'PASS' not in run.stdout:
                    raise RuntimeError(f'{iw}/{ow}: {run.stdout} {run.stderr}')
                report['cases'].append({'in_width': iw, 'out_width': ow, 'packets': 128,
                                        'inputs': len(iv), 'outputs': len(ov), 'status': 'PASS'})
                print(run.stdout.splitlines()[0], flush=True)
        report['status'] = 'PASS'
    except Exception as exc:
        report['status'] = 'FAIL'
        report['reason'] = str(exc)
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out), flush=True)


if __name__ == '__main__':
    main()
