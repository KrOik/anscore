"""Windows D2XX UART controlled board tests. This is not runtime hard JTAG."""
import argparse
import ctypes as c
from ctypes import wintypes as w
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import time
import zlib

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())


def crc8(data):
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = ((crc << 1) ^ (7 if crc & 128 else 0)) & 255
    return crc


class UART:
    def __init__(self, serial):
        self.dll = c.WinDLL('C:/Windows/System32/ftd2xx.dll')
        self.handle = w.HANDLE()
        self.check(self.dll.FT_OpenEx(c.c_char_p(serial.encode()), 1, c.byref(self.handle)))
        for name, args in [('FT_SetBitMode', (0, 0)), ('FT_SetBaudRate', (115200,)),
                           ('FT_SetDataCharacteristics', (8, 0, 0)), ('FT_SetFlowControl', (0, 0, 0)),
                           ('FT_SetTimeouts', (100, 1000)), ('FT_SetLatencyTimer', (2,)), ('FT_Purge', (3,))]:
            self.check(getattr(self.dll, name)(self.handle, *args))

    @staticmethod
    def check(status):
        if status:
            raise RuntimeError('D2XX status ' + str(status))

    def exchange(self, packet):
        written = w.DWORD()
        self.check(self.dll.FT_Write(self.handle, c.c_char_p(packet), len(packet), c.byref(written)))
        if written.value != len(packet):
            raise RuntimeError('short FTDI write')
        result = bytearray()
        deadline = time.monotonic() + 2
        while len(result) < 8 and time.monotonic() < deadline:
            buf = c.create_string_buffer(8 - len(result))
            got = w.DWORD()
            self.check(self.dll.FT_Read(self.handle, buf, len(buf), c.byref(got)))
            result.extend(buf.raw[:got.value])
        return bytes(result)

    def close(self):
        self.dll.FT_Close(self.handle)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--build', type=Path, required=True)
    ap.add_argument('--serial', default='2025030317B')
    ap.add_argument('--program', action='store_true')
    a = ap.parse_args()
    build = a.build.resolve()
    summary = build / ('summary_recovery.json' if (build / 'summary_recovery.json').exists() else 'summary.json')
    design = json.loads(summary.read_text())
    if design['status'] != 'PASS':
        raise RuntimeError('build not passed')
    for file, sha in design['sources'].items():
        if hashlib.sha256((ROOT / file).read_bytes()).hexdigest() != sha:
            raise RuntimeError('stale build source ' + file)
    bitstream = build / 'test_shell.fs'
    if hashlib.sha256(bitstream.read_bytes()).hexdigest() != design['bitstream_sha256']:
        raise RuntimeError('bitstream mismatch')
    out = ROOT / 'artifacts/ip_test_shell_25k' / datetime.now(timezone.utc).strftime('physical_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'transport': 'D2XX UART 115200 8N1',
              'bitstream_sha256': design['bitstream_sha256'], 'program_count': 0, 'transactions': [], 'cases': []}
    uart = None
    try:
        if a.program:
            det = subprocess.run(['openFPGALoader', '-b', 'tangprimer25k', '--detect'], capture_output=True, text=True)
            (out / 'detect.log').write_text(det.stdout + det.stderr)
            if det.returncode or '0x1281b' not in det.stdout + det.stderr:
                raise RuntimeError('unexpected JTAG target')
            run = subprocess.run(['openFPGALoader', '-b', 'tangprimer25k', str(bitstream)], capture_output=True, text=True)
            (out / 'program.log').write_text(run.stdout + run.stderr)
            if run.returncode:
                raise RuntimeError('SRAM programming failed')
            report['program_count'] = 1
        uart = UART(a.serial)

        def access(addr, data=None):
            packet = bytes([0xa5, int(data is not None), addr]) + int(data or 0).to_bytes(4, 'little')
            packet += bytes([crc8(packet)])
            reply = uart.exchange(packet)
            report['transactions'].append({'request': packet.hex(), 'reply': reply.hex()})
            if len(reply) != 8 or reply[0] != 0x5a or reply[2] != addr or crc8(reply[:7]) != reply[7]:
                raise RuntimeError('UART missing/invalid reply: ' + reply.hex())
            if reply[1]:
                raise RuntimeError('CSR error at ' + hex(addr))
            return int.from_bytes(reply[3:7], 'little')

        if access(0) != 0x49503034:
            raise RuntimeError('wrong design ID')
        for seed, length, mask in [(18, 7, 0), (189, 63, 0x33333333), (255, 256, 0x55555555)]:
            access(12, seed); access(16, length); access(20, mask); access(4, 1)
            deadline = time.monotonic() + 3
            while True:
                status = access(4)
                if status & 2:
                    break
                if time.monotonic() > deadline:
                    raise RuntimeError('run timeout')
            if status != 2:
                raise RuntimeError('board run error')
            count, crc, byte_count = access(48), access(52), access(56)
            expected = bytes((seed + source * 73 + i) & 255 for source in range(4) for i in range(length))
            payload, words = bytearray(), []
            source, offset = 0, 0
            for index in range(count):
                access(36, index)
                word = access(40) | access(44) << 32
                n = min(3, length - offset)
                if (word >> 27 & 255) != source or (word >> 24 & 7) != (1 << n) - 1 or (word >> 35) != int(offset + n == length):
                    raise RuntimeError('trace metadata mismatch')
                words.append(f'{word:09x}')
                payload.extend((word >> (8 * b)) & 255 for b in range(n))
                offset += n
                if offset == length:
                    source += 1; offset = 0
            if payload != expected or byte_count != len(expected) or crc != zlib.crc32(expected) or source != 4:
                raise RuntimeError('board full trace/golden mismatch')
            report['cases'].append({'seed': seed, 'length': length, 'status': 'PASS', 'crc': f'{crc:08x}', 'trace_words': words})
        report['status'] = 'PASS'
    except Exception as exc:
        report['status'] = 'FAIL'
        report['reason'] = str(exc)
        raise
    finally:
        if uart:
            uart.close()
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out))


if __name__ == '__main__':
    main()
