"""Three asynchronous clock ratios, independent host codec/golden, retained logs."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zlib
from scan_protocol import encode_command, decode_response

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/system/ip_test_shell'


def main():
    sources = [P / 'rtl/scan_csr_mailbox.v', P / 'tb/tb_scan_csr_mailbox.v',
               P / 'tools/scan_protocol.py', Path(__file__).resolve()]
    core_sources = sorted((P / 'rtl').glob('*.v')) + [P / 'tb/tb_scan_loaded_core.v']
    core_sources += [ROOT / 'cores/system/stream_bus_library/rtl' / ('sys_' + n + '.v')
                     for n in ('frame_switch4', 'width_converter', 'packet_async_fifo', 'capture_replay')]
    out = ROOT / 'artifacts/ip_test_shell_25k' / datetime.now(timezone.utc).strftime('scan_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'sources': {p.relative_to(ROOT).as_posix():
        hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + core_sources}, 'cases': []}
    try:
        cases = [(9, 0x38, True, 5, 0x78351ad6)]
        cases += [(i, 0xfc if i == 49 else i * 4, bool(i & 1), i & 15,
                   0x9bc83710 + i * 713) for i in range(50)]
        cases += [(100, 0x18, False, 7, 0x21)]
        for half in (3, 7, 23):
            exe = out / f'scan_{half}.vvp'
            build = subprocess.run(['iverilog', '-g2012', '-s', 'tb_scan_csr_mailbox',
                '-P', f'tb_scan_csr_mailbox.TCK_HALF={half}', '-o', str(exe),
                str(sources[0]), str(sources[1])], capture_output=True, text=True)
            (out / f'compile_{half}.log').write_text(build.stdout + build.stderr)
            if build.returncode:
                raise RuntimeError(build.stderr)
            run = subprocess.run(['vvp', str(exe)], capture_output=True, text=True, timeout=30)
            (out / f'run_{half}.log').write_text(run.stdout + run.stderr)
            if run.returncode or 'PASS scan mailbox' not in run.stdout:
                raise RuntimeError(run.stdout + run.stderr)
            rows = re.findall(r'SCAN_VECTOR request=([0-9a-f]+) response=([0-9a-f]+)', run.stdout)
            if len(rows) != len(cases):
                raise RuntimeError('missing scan golden vectors')
            for (request, response), (tag, addr, write, strobes, data) in zip(rows, cases):
                if int(request, 16).to_bytes(9, 'little') != encode_command(tag, addr, data, write=write, strobe=strobes):
                    raise RuntimeError('independent command codec mismatch')
                answer = decode_response(int(response, 16).to_bytes(9, 'little'))
                expected = data ^ (addr * 0x01010101) ^ ((int(write) << 4) | strobes)
                if (answer.tag, answer.valid, answer.busy, answer.csr_error, answer.data) != (tag, True, False, addr == 0xfc, expected):
                    raise RuntimeError('independent response golden mismatch')
            report['cases'].append({'tck_period_ns': 2 * half, 'clk_period_ns': 10,
                                    'full_response_vectors': len(rows), 'status': 'PASS'})
            print(next(line for line in run.stdout.splitlines() if line.startswith('PASS')))
        build = subprocess.run(['iverilog', '-g2012', '-s', 'tb_scan_loaded_core',
            '-o', str(out / 'core.vvp')] + list(map(str, core_sources)), capture_output=True, text=True)
        (out / 'core_compile.log').write_text(build.stdout + build.stderr)
        if build.returncode:
            raise RuntimeError(build.stderr)
        run = subprocess.run(['vvp', str(out / 'core.vvp')], capture_output=True, text=True, timeout=60)
        (out / 'core_run.log').write_text(run.stdout + run.stderr)
        if run.returncode or 'PASS scan to real shell' not in run.stdout:
            raise RuntimeError(run.stdout + run.stderr)
        rows = re.findall(r'LOADED_WORD case=(\d+) index=(\d+) data=([0-9a-f]+)', run.stdout)
        if len(rows) != 290:
            raise RuntimeError('scan loaded trace missing')
        report['loaded_cases'] = []
        for case, count in enumerate((3, 31, 256)):
            actual = [(int(i), int(d, 16)) for c, i, d in rows if int(c) == case]
            golden = [((0xd324a519 ^ (case * 0x710341)) + i * 0x198371) & 0xffffffff for i in range(count)]
            if actual != list(enumerate(golden)):
                raise RuntimeError('scan loaded independent golden mismatch')
            raw = b''.join(d.to_bytes(4, 'little') for _, d in actual)
            (out / f'loaded_case{case}.bin').write_bytes(raw)
            report['loaded_cases'].append({'case': case, 'words': count,
                'crc32': f'{zlib.crc32(raw):08x}', 'status': 'PASS'})
        print('PASS scan to real CSR/fabric: three datasets, 290 complete words, independent Python golden')
        report['status'] = 'PASS'
    except Exception as exc:
        report.update(status='FAIL', reason=str(exc))
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out))


if __name__ == '__main__':
    main()
