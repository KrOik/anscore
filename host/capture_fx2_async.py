"""Capture 8-bit fx2lafw samples with prequeued libusb transfers (libusb1)."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import time

import usb1


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('output', type=Path)
    p.add_argument('--rate', type=int, default=4000000)
    p.add_argument('--samples', type=int, default=8000000)
    p.add_argument('--queue', type=int, default=32)
    p.add_argument('--timeout', type=float, default=15)
    a = p.parse_args()
    if a.rate <= 0 or 48000000 % a.rate or not 1 <= 48000000 // a.rate - 1 <= 1536:
        p.error('rate must divide 48 MHz with delay in 1..1536')
    if a.samples <= 0 or a.queue <= 0 or a.timeout <= 0:
        p.error('samples, queue and timeout must be positive')
    if a.output.exists() or a.output.with_suffix('.json').exists():
        p.error('refusing to overwrite capture evidence')
    a.output.parent.mkdir(parents=True, exist_ok=True)
    meta = dict(start_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                samplerate=a.rate, requested_samples=a.samples, queue=a.queue)
    data = bytearray()
    errors = []
    stopping = False
    started = time.monotonic()
    with usb1.USBContext() as ctx:
        h = ctx.openByVendorIDAndProductID(0x1d50, 0x608c, skip_on_error=False)
        if h is None:
            raise RuntimeError('fx2lafw 1d50:608c not found')
        transfers = []
        try:
            h.claimInterface(0)
            meta['firmware'] = list(h.controlRead(0xc0, 0xb0, 0, 0, 2, timeout=1000))

            def callback(t):
                if stopping:
                    return
                status = t.getStatus()
                if status != usb1.TRANSFER_COMPLETED:
                    errors.append(dict(status=status, actual=t.getActualLength()))
                    return
                data.extend(t.getBuffer()[:min(t.getActualLength(), a.samples - len(data))])
                if len(data) < a.samples and not errors:
                    t.submit()

            for _ in range(a.queue):
                t = h.getTransfer()
                t.setBulk(0x82, 32768, callback=callback, timeout=int(a.timeout * 1000))
                t.submit()
                transfers.append(t)
            delay = 48000000 // a.rate - 1
            h.controlWrite(0x40, 0xb1, 0, 0, bytes([0x40, delay >> 8, delay & 255]), timeout=1000)
            while len(data) < a.samples and not errors and time.monotonic() - started < a.timeout:
                ctx.handleEventsTimeout(tv=0.1)
        except Exception as exc:
            errors.append(dict(exception=repr(exc)))
        finally:
            stopping = True
            for t in transfers:
                if t.isSubmitted():
                    try:
                        t.cancel()
                    except usb1.USBErrorNotFound:
                        # Completion may already be queued; dispatch it below.
                        pass
            while any(t.isSubmitted() for t in transfers):
                ctx.handleEventsTimeout(tv=0.1)
            h.close()
    a.output.write_bytes(data)
    meta.update(samples=len(data), elapsed=time.monotonic() - started,
                sha256=hashlib.sha256(data).hexdigest(), errors=errors,
                status='COMPLETE' if len(data) == a.samples and not errors else 'INCOMPLETE')
    a.output.with_suffix('.json').write_text(json.dumps(meta, indent=2))
    print(json.dumps(meta))
    raise SystemExit(0 if meta['status'] == 'COMPLETE' else 1)


if __name__ == '__main__':
    main()
