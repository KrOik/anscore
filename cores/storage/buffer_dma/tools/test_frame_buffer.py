"""Two real RTL writers/readers, independent full payload and CRC checking."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import zlib
from decode_metrics import decode

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/storage/buffer_dma'


def main():
    sources = sorted((P / 'rtl').glob('*.v')) + [ROOT / 'cores/system/stream_bus_library/rtl/sys_register_snapshot.v', P / 'tb/tb_frame_buffer_reference.v']
    out = ROOT / 'artifacts/buffer_dma_25k' / datetime.now(timezone.utc).strftime('frame_buffer_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'sources': {p.relative_to(ROOT).as_posix():
        hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [Path(__file__).resolve(), P / 'tools/decode_metrics.py']}, 'cases': []}
    try:
        for fixed in (1, 0):
            exe = out / f'fixed{fixed}.vvp'
            build = subprocess.run(['iverilog', '-g2012', '-s', 'tb_frame_buffer_reference',
                '-P', f'tb_frame_buffer_reference.FIXED_PINGPONG={fixed}', '-o', str(exe)] +
                list(map(str, sources)), capture_output=True, text=True)
            (out / f'compile{fixed}.log').write_text(build.stdout + build.stderr)
            if build.returncode:
                raise RuntimeError(build.stderr)
            run = subprocess.run(['vvp', str(exe)], capture_output=True, text=True, timeout=30)
            (out / f'run{fixed}.log').write_text(run.stdout + run.stderr)
            match = re.search(r'PASS integrated DMA fixed=(\d+) frames=64 words=544 cycles=(\d+)', run.stdout)
            if run.returncode or not match or int(match[1]) != fixed:
                raise RuntimeError(run.stdout + run.stderr)
            samples = re.findall(r'DMA_READ sink=(\d+) source=(\d+) frame=(\d+) offset=(\d+) data=([0-9a-fA-F]+)', run.stdout)
            seen = set()
            payload = [bytearray(), bytearray()]
            for sink, source, frame, offset, data in samples:
                sink, source, frame, offset = map(int, (sink, source, frame, offset))
                key = (source, frame, offset)
                expected = (0x512a309b ^ (source * 0x17351) ^ (frame * 0x103397 + offset * 0x71a3)) & 0xffffffff
                if key in seen or sink != (source ^ (frame & 1)) or int(data, 16) != expected:
                    raise RuntimeError('Python golden mismatch')
                seen.add(key)
                payload[sink] += struct.pack('<I', int(data, 16))
            required = {(s, f, i) for s in range(2) for f in range(32) for i in range(f % 16 + 1)}
            if seen != required:
                raise RuntimeError('Missing or extra words')
            for sink in range(2):
                (out / f'fixed{fixed}_sink{sink}.bin').write_bytes(payload[sink])
            metrics = re.findall(r'METRIC channel=(\d+) bytes=(\d+) frames=(\d+) stalls=(\d+) crc=([0-9a-fA-F]+) last_cycles=(\d+) last_crc=([0-9a-fA-F]+)', run.stdout)
            if len(metrics) != 4:
                raise RuntimeError('Missing stream metrics')
            for channel, byte_count, frames, stalls, crc, duration, last_crc in metrics:
                channel = int(channel)
                if channel < 2:
                    stream = bytearray()
                    last_payload = bytearray()
                    for frame in range(32):
                        last_payload = bytearray()
                        for offset in range(frame % 16 + 1):
                            word = (0x512a309b ^ (channel * 0x17351) ^ (frame * 0x103397 + offset * 0x71a3)) & 0xffffffff
                            last_payload += struct.pack('<I', word)
                        stream += last_payload
                else:
                    stream = payload[channel - 2]
                    # Each sink's final frame in this test has sixteen full words.
                    last_payload = stream[-64:]
                if (int(byte_count), int(frames)) != (1088, 32) or int(crc, 16) != zlib.crc32(stream) or int(last_crc, 16) != zlib.crc32(last_payload) or int(duration) < 16:
                    raise RuntimeError('RTL metric/CRC mismatch')
            registers = re.findall(r'CSRDUMP index=(\d+) value=([0-9a-fA-F]+)', run.stdout)
            stamp = re.search(r'SNAPSHOT id=(\d+) timestamp=(\d+)', run.stdout)
            if len(registers) != 51 or [int(i) for i, _ in registers] != list(range(51)) or not stamp:
                raise RuntimeError('Incomplete CSR dump')
            capture = {'schema': 'buffer_dma_metrics_v1', 'source_kind': 'simulation',
                'epoch_id': out.name + f'_fixed{fixed}', 'clock_hz': 100000000,
                'snapshot_id_before': int(stamp[1]), 'snapshot_id_after': int(stamp[1]),
                'captured': True, 'timestamp': int(stamp[2]),
                'words': [int(word, 16) for _, word in registers]}
            decoded = decode(capture)
            if [decoded[k] for k in ('published', 'released', 'aborted', 'invalid_requests', 'peak_occupied')] != [64, 64, 1, 1, 4]:
                raise RuntimeError('Decoded accounting mismatch')
            for sink in range(2):
                if decoded['streams'][sink+2]['crc32'] != f'{zlib.crc32(payload[sink]):08X}':
                    raise RuntimeError('Decoded output CRC mismatch')
            (out / f'fixed{fixed}_snapshot.json').write_text(json.dumps(capture, indent=2) + '\n')
            (out / f'fixed{fixed}_decoded.json').write_text(json.dumps(decoded, indent=2) + '\n')
            report['cases'].append({'fixed_pingpong': fixed, 'frames': 64, 'words': len(seen),
                'cycles': int(match[2]), 'crc32_le': [f'{zlib.crc32(p):08X}' for p in payload],
                'metrics': metrics, 'status': 'PASS'})
            print(match[0])
        report['status'] = 'PASS'
    except Exception as exc:
        report.update(status='FAIL', reason=str(exc))
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out))


if __name__ == '__main__':
    main()
