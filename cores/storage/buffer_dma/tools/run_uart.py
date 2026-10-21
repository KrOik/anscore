"""Run the board's controlled DMA test and save real UART CSR evidence."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import time
import uuid
import struct
import zlib
from decode_metrics import decode


def crc8(data):
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ (7 if crc & 128 else 0)) & 255
    return crc


class UartCsr:
    def __init__(self, port):
        self.port = port
        self.exchanges = []

    def access(self, address, value=None):
        body = bytes((0xa5, int(value is not None), address)) + (0 if value is None else value).to_bytes(4, 'little')
        command = body + bytes((crc8(body),))
        self.port.write(command)
        reply = bytearray()
        deadline = time.monotonic() + 2
        while len(reply) < 8 and time.monotonic() < deadline:
            reply += self.port.read(8 - len(reply))
        self.exchanges.append({'command': command.hex(), 'reply': reply.hex()})
        if len(reply) != 8 or reply[0] != 0x5a or reply[2] != address or crc8(reply[:7]) != reply[7]:
            raise RuntimeError('UART timeout/framing/address/CRC error')
        if reply[1] != 0:
            raise RuntimeError(f'CSR error at {address:02X}')
        return int.from_bytes(reply[3:7], 'little')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True)
    parser.add_argument('--clock-hz', type=int, required=True)
    parser.add_argument('--seed', type=lambda v: int(v, 0), default=0x512a309b)
    parser.add_argument('--no-stalls', action='store_true')
    parser.add_argument('--seconds', type=float, default=10)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not 0 <= args.seed <= 0xffffffff or args.clock_hz <= 0 or args.seconds <= 0:
        parser.error('invalid seed/clock/timeout')
    # Import only for actual physical use; analysis tools remain hardware-free.
    import serial
    args.output.mkdir(parents=True, exist_ok=False)
    report = {'status': 'IN_PROGRESS', 'source_kind': 'board', 'transport': 'UART',
        'port': args.port, 'clock_hz': args.clock_hz, 'seed': args.seed,
        'stalls': not args.no_stalls, 'time_utc': datetime.now(timezone.utc).isoformat(),
        'host_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'physical_jtag_verified': False}
    bus = None
    try:
        with serial.Serial(args.port, 115200, timeout=0.1, write_timeout=2) as port:
            port.reset_input_buffer()
            bus = UartCsr(port)
            if bus.access(0xfc) != 0x42444631:
                raise RuntimeError('unexpected board CSR identifier')
            frames = bus.access(0xec)
            bus.access(0xe4, args.seed)
            bus.access(0xe8, int(not args.no_stalls))
            bus.access(0xe0, 1)
            deadline = time.monotonic() + args.seconds
            while True:
                status = bus.access(0xe0)
                if status & 2:
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError('selftest completion timeout')
                time.sleep(0.01)
            checked, errors, cycles = (bus.access(a) for a in (0xf0, 0xf4, 0xf8))
            expected_words = 2 * sum(f % 16 + 1 for f in range(frames))
            if status & 4 or errors or checked != expected_words:
                raise RuntimeError('board selftest reports failure or incorrect word count')
            bus.access(0, 1)
            first = bus.access(0)
            low, high = bus.access(4), bus.access(8)
            captured = bus.access(12)
            words = [bus.access(16 + i * 4) for i in range(51)]
            last = bus.access(0)
            capture = {'schema': 'buffer_dma_metrics_v1', 'source_kind': 'board',
                'epoch_id': str(uuid.uuid4()), 'clock_hz': args.clock_hz,
                'snapshot_id_before': first, 'snapshot_id_after': last,
                'captured': captured == 1, 'timestamp': low | (high << 32), 'words': words}
            decoded = decode(capture)
            (args.output / 'snapshot.json').write_text(json.dumps(capture, indent=2) + '\n')
            (args.output / 'decoded.json').write_text(json.dumps(decoded, indent=2) + '\n')
            if words[:4] != [2 * frames, 2 * frames, 0, 0]:
                raise RuntimeError('frame publication/release/error accounting mismatch')
            for source in range(2):
                golden = bytearray()
                for frame in range(frames):
                    for offset in range(frame % 16 + 1):
                        word = (args.seed ^ (source * 0x17351) ^ (frame * 0x103397 + offset * 0x71a3)) & 0xffffffff
                        golden += struct.pack('<I', word)
                if words[28+source] != zlib.crc32(golden):
                    raise RuntimeError('input stream CRC differs from host golden')
            expected_bytes = expected_words * 2
            if words[16:20] != [expected_bytes] * 4 or words[20:24] != [frames] * 4:
                raise RuntimeError('stream byte/frame accounting mismatch')
            report.update(status='PASS', frames_per_source=frames, checked_words=checked,
                check_errors=errors, run_cycles=cycles)
    except Exception as exc:
        report.update(status='FAIL', reason=str(exc))
        raise
    finally:
        if bus is not None:
            (args.output / 'uart_exchanges.json').write_text(json.dumps(bus.exchanges, indent=2) + '\n')
        (args.output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
