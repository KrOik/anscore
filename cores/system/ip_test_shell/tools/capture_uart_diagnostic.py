"""Program isolated diagnostic, synchronously capture all eight pins and test D2XX."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
import ctypes
from ctypes import wintypes
from replay_runner import UART

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())


def decode(raw, channel, rate):
    step = rate * 434 / 50000000
    found = []
    i = 1
    while i + int(10 * step) < len(raw):
        if (raw[i - 1] >> channel & 1) and not (raw[i] >> channel & 1):
            bits = [(raw[round(i + (n + .5) * step)] >> channel) & 1 for n in range(10)]
            if bits[0] == 0 and bits[9] == 1:
                found.append({'sample': i, 'data': sum(bits[b + 1] << b for b in range(8))})
                i += int(10 * step)
                continue
        i += 1
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--build', type=Path, required=True)
    ap.add_argument('--serial', default='2025030317B')
    ap.add_argument('--bitbang', action='store_true', help='drive only UART TXD B0 as slow GPIO to isolate UART engine')
    ap.add_argument('--no-program', action='store_true')
    args = ap.parse_args()
    if args.bitbang:
        raise RuntimeError('GPIO bitbang diagnostic disabled after USB driver failure; use UART mode')
    build = args.build.resolve()
    design = json.loads((build / 'summary.json').read_text())
    if design['status'] != 'PASS' or design.get('top') != 'uart_diagnostic_top':
        raise RuntimeError('diagnostic build required')
    for file, sha in design['sources'].items():
        if hashlib.sha256((ROOT / file).read_bytes()).hexdigest() != sha:
            raise RuntimeError('stale source: ' + file)
    fs = build / 'test_shell.fs'
    if hashlib.sha256(fs.read_bytes()).hexdigest() != design['bitstream_sha256']:
        raise RuntimeError('bitstream hash mismatch')
    out = ROOT / 'artifacts/ip_test_shell_25k' / datetime.now(timezone.utc).strftime('uart_la_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'bitstream_sha256': design['bitstream_sha256'],
              'probe_page': 'isolated_uart_diagnostic', 'clock_hz': 50000000, 'sample_rate': 2000000,
              'pinmap': design.get('probe_pins', ['A10', 'A11', 'E10', 'E11', 'L11', 'K11', 'K5', 'L5'])}
    capture = uart = None
    try:
        report['program_count'] = 0
        report['host_mode'] = 'B0 asynchronous bitbang' if args.bitbang else 'UART'
        if not args.no_program:
            run = subprocess.run(['openFPGALoader', '-b', 'tangprimer25k', str(fs)], capture_output=True, text=True)
            (out / 'program.log').write_text(run.stdout + run.stderr)
            if run.returncode:
                raise RuntimeError('SRAM program failure')
            report['program_count'] = 1
        uart = UART(args.serial)
        with (out / 'capture.log').open('w') as log:
            capture = subprocess.Popen([sys.executable, str(ROOT / 'host/capture_fx2_async.py'), str(out / 'capture.bin'),
                                        '--rate', '2000000', '--samples', '2000000'], stdout=log, stderr=subprocess.STDOUT)
            time.sleep(.25)
            sent = bytes.fromhex('a500000000000069')
            if args.bitbang:
                uart.check(uart.dll.FT_SetBitMode(uart.handle, 1, 1))
                uart.check(uart.dll.FT_SetBaudRate(uart.handle, 9600))
                report['ftdi_gpio_samples'] = []
                for level in [0, 1] * 8:
                    written = wintypes.DWORD()
                    value = ctypes.c_char_p(bytes([level]))
                    uart.check(uart.dll.FT_Write(uart.handle, value, 1, ctypes.byref(written)))
                    time.sleep(.02)
                    pins = ctypes.c_ubyte()
                    uart.check(uart.dll.FT_GetBitMode(uart.handle, ctypes.byref(pins)))
                    report['ftdi_gpio_samples'].append({'requested_B0': level, 'pins': pins.value})
                received = b''
            else:
                received = uart.exchange(sent)
            report['host_sent_hex'] = sent.hex()
            report['host_received_hex'] = received.hex()
            report['capture_exit'] = capture.wait(timeout=20)
        if report['capture_exit']:
            raise RuntimeError('LA capture failed')
        raw = (out / 'capture.bin').read_bytes()
        report['capture_sha256'] = hashlib.sha256(raw).hexdigest()
        report['channels'] = [{'channel': ch, 'edges': sum(((a ^ b) >> ch) & 1 for a, b in zip(raw, raw[1:])),
                               'high_samples': sum((b >> ch) & 1 for b in raw)} for ch in range(8)]
        report['fpga_rx_decoded'] = decode(raw, 0, 2000000)
        report['fpga_tx_decoded'] = decode(raw, 1, 2000000)
        report['ftdi_received_beacon'] = received == b'\x55' * 8
        decoded_rx = bytes(x['data'] for x in report['fpga_rx_decoded'])
        report['fpga_received_host_pattern'] = sent in decoded_rx
        report['probe_capture_valid'] = report['channels'][6]['edges'] > 0 and report['channels'][1]['edges'] > 0
        report['status'] = 'MEASURED' if report['probe_capture_valid'] else 'INVALID_PROBE_CAPTURE'
        print(json.dumps({k: report[k] for k in ('ftdi_received_beacon', 'fpga_received_host_pattern', 'host_received_hex', 'channels')}, indent=2))
    except Exception as exc:
        report['status'] = 'FAIL'
        report['reason'] = str(exc)
        raise
    finally:
        if capture is not None and capture.poll() is None:
            capture.terminate(); capture.wait()
        if uart:
            uart.dll.FT_SetBitMode(uart.handle, 0, 0)
            uart.close()
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out))


if __name__ == '__main__':
    main()
