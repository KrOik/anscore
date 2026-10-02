"""Runs ON the remote board (bianbu): program SRAM, inject UART, capture FX2, decode, verdict.

Same protocol as probe_external.py but all hardware access is local to the
board where the dock + FX2 are attached (USB ttyUSB1 = dock UART, fx2lafw).
Writes SRAM only (no flash). Emits artifacts + verdict.json into --out.
"""
import argparse, hashlib, json, re, secrets, subprocess, sys, time
from pathlib import Path
import serial

def parse_decode(text):
    result = bytearray()
    for line in text.splitlines():
        if not line.strip():
            continue
        m = re.fullmatch(r'uart-\d+:\s*([0-9A-Fa-f]{2})\s*', line)
        if m is None:
            raise ValueError('Unexpected decoder output: ' + line)
        result.append(int(m.group(1), 16))
    return bytes(result)

def verify_decoded(decoded, expected):
    if len(expected) != 32 or len(decoded) < 96:
        raise ValueError('Expected 32-byte nonce and at least 96 captured bytes')
    positions = [i for i in range(32)
                 if decoded == bytes(expected[(i + j) % 32] for j in range(len(decoded)))]
    if not positions:
        raise ValueError('Capture contains data/order/insertion/deletion mismatch')
    return positions[0]

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--image', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--uart', default='/dev/ttyUSB1')
    p.add_argument('--samples', default='4000000')
    a = p.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    image = Path(a.image)
    status = dict(status='FAIL', image=str(image),
                  sha256=hashlib.sha256(image.read_bytes()).hexdigest())
    capture = None
    try:
        with (out / 'program.log').open('w') as log:
            r = subprocess.run(['openFPGALoader', '-b', 'tangprimer20k', str(image)],
                               stdout=log, stderr=subprocess.STDOUT, timeout=120)
        if r.returncode:
            raise RuntimeError('openFPGALoader failed; see program.log')
        status['sram_programmed'] = True

        packet = b'INJ1' + secrets.token_bytes(28)
        expected = bytes(x ^ 0xA5 for x in packet)
        (out / 'input_packet.bin').write_bytes(packet)
        (out / 'expected_packet.bin').write_bytes(expected)

        with serial.Serial(a.uart, 115200, timeout=0, write_timeout=1) as port:
            port.reset_input_buffer()
            with (out / 'capture.log').open('w') as log:
                capture = subprocess.Popen(
                    ['sigrok-cli', '-d', 'fx2lafw', '--config', 'samplerate=4m',
                     '--samples', a.samples, '-o', str(out / 'capture.sr')],
                    stdout=log, stderr=subprocess.STDOUT)
                received = bytearray(); sent = bytearray()
                time.sleep(0.5)
                for _ in range(24):
                    for byte in packet:
                        port.write(bytes([byte])); sent.append(byte)
                        time.sleep(0.002)
                        received.extend(port.read(4096))
                (out / 'sent.bin').write_bytes(sent)
                (out / 'serial_received.bin').write_bytes(received)
                capture.wait(timeout=60)
                if capture.returncode:
                    raise RuntimeError('FX2 capture failed; see capture.log')

        r = subprocess.run(['sigrok-cli', '-i', str(out / 'capture.sr'), '-P',
                            'uart:rx=D0:baudrate=115200:format=hex',
                            '-A', 'uart=rx-data'],
                           text=True, capture_output=True, timeout=120)
        (out / 'decoded.txt').write_text(r.stdout)
        (out / 'decode_stderr.log').write_text(r.stderr)
        if r.returncode:
            raise RuntimeError('Decode failed')
        decoded = parse_decode(r.stdout)
        (out / 'decoded.bin').write_bytes(decoded)
        offset = verify_decoded(decoded, expected)
        status.update(status='PASS', decoded_bytes=len(decoded),
                      cyclic_start=offset, serial_received_bytes=len(received),
                      sent_bytes=len(sent),
                      scope='remote transport UART(ttyUSB1)->FPGA XOR->FX2(fx2lafw) only')
    except Exception as exc:
        status['error'] = str(exc)
    finally:
        if capture is not None and capture.poll() is None:
            capture.terminate(); capture.wait(timeout=10)
        (out / 'verdict.json').write_text(json.dumps(status, indent=2) + '\n')
    print(json.dumps(status, indent=2))
    return 0 if status['status'] == 'PASS' else 1

if __name__ == '__main__':
    sys.exit(main())
