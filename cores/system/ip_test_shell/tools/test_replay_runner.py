"""Runtime replay regression with independent zlib CRC and immutable logs."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zlib

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/system/ip_test_shell'
SOURCES = [P / 'rtl' / (n + '.v') for n in
           ('fabric_replay_runner', 'stream_fabric4', 'stream_width_adapter')]
SOURCES += [ROOT / 'cores/system/stream_bus_library/rtl' / ('sys_' + n + '.v')
            for n in ('frame_switch4', 'width_converter', 'packet_async_fifo')]
SOURCES += [P / 'tb/tb_fabric_replay_runner.v']
SOURCES += [P / 'rtl' / (n + '.v') for n in ('ip_test_shell_core', 'test_shell_csr', 'logic_probe8')]
SOURCES += [P / 'tb/tb_ip_test_shell_core.v']
SOURCES += [P / 'rtl/csr_capture_replay.v', P / 'rtl/loaded_fabric_replay.v',
            ROOT / 'cores/system/stream_bus_library/rtl/sys_capture_replay.v']


def main():
    out = ROOT / 'artifacts/ip_test_shell_25k' / datetime.now(timezone.utc).strftime('replay_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'sources': {
        p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}, 'cases': []}
    try:
        cmd = ['iverilog', '-g2012', '-s', 'tb_fabric_replay_runner', '-o', str(out / 'test.vvp')] + list(map(str, SOURCES))
        build = subprocess.run(cmd, capture_output=True, text=True)
        (out / 'compile.log').write_text(build.stdout + build.stderr)
        if build.returncode:
            raise RuntimeError(build.stderr)
        run = subprocess.run(['vvp', str(out / 'test.vvp')], capture_output=True, text=True, timeout=60)
        (out / 'run.log').write_text(run.stdout + run.stderr)
        if run.returncode or 'PASS runner three runtime cases' not in run.stdout:
            raise RuntimeError(run.stdout + run.stderr)
        rows = re.findall(r'PASS replay seed=([0-9a-f]+) length=(\d+) bytes=(\d+) trace=(\d+) cycles=(\d+) crc=([0-9a-f]+)', run.stdout)
        if len(rows) != 3:
            raise RuntimeError('missing replay results')
        for seed, length, byte_count, count, cycles, crc in rows:
            seed, length = int(seed, 16), int(length)
            payload = bytes((seed + source * 73 + i) & 255 for source in range(4) for i in range(length))
            golden = zlib.crc32(payload)
            if int(crc, 16) != golden or int(byte_count) != len(payload):
                raise RuntimeError('independent golden mismatch')
            report['cases'].append({'seed': seed, 'length': length, 'bytes': len(payload),
                                    'trace_words': int(count), 'cycles': int(cycles), 'crc32': f'{golden:08x}', 'status': 'PASS'})
        cmd = ['iverilog', '-g2012', '-s', 'tb_ip_test_shell_core', '-o', str(out / 'core.vvp')] + list(map(str, SOURCES))
        build = subprocess.run(cmd, capture_output=True, text=True)
        (out / 'core_compile.log').write_text(build.stdout + build.stderr)
        if build.returncode:
            raise RuntimeError(build.stderr)
        core = subprocess.run(['vvp', str(out / 'core.vvp')], capture_output=True, text=True, timeout=60)
        (out / 'core_run.log').write_text(core.stdout + core.stderr)
        if core.returncode or 'PASS shell_core three CSR-controlled runs' not in core.stdout:
            raise RuntimeError(core.stdout + core.stderr)
        report['csr_full_trace_readback'] = 'PASS: 3 runs, 440 complete trace words, no intervening reset'
        loaded = re.findall(r'LOADED_WORD case=(\d+) index=(\d+) data=([0-9a-f]+)', core.stdout)
        if len(loaded) != 290:
            raise RuntimeError('missing loaded fabric readback')
        report['loaded_fabric_cases'] = []
        for case, count in enumerate((3, 31, 256)):
            rows = [(int(i), int(d, 16)) for c, i, d in loaded if int(c) == case]
            golden = [((0xd324a519 ^ (case * 0x710341)) + i * 0x198371) & 0xffffffff for i in range(count)]
            if rows != list(enumerate(golden)):
                raise RuntimeError('independent loaded golden mismatch')
            payload = b''.join(word.to_bytes(4, 'little') for _, word in rows)
            (out / f'loaded_case{case}.bin').write_bytes(payload)
            report['loaded_fabric_cases'].append({'case': case, 'words': count,
                'bytes': len(payload), 'crc32': f'{zlib.crc32(payload):08x}', 'status': 'PASS'})
        report['status'] = 'PASS'
        print(run.stdout, end='')
        print('\n'.join(line for line in core.stdout.splitlines() if not line.startswith('LOADED_WORD ')))
    except Exception as exc:
        report['status'] = 'FAIL'
        report['reason'] = str(exc)
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out))


if __name__ == '__main__':
    main()
