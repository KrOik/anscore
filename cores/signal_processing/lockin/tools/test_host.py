"""Host acceptance using numerical words emitted by actual CSR RTL simulation."""
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from lockin_host import configuration, run_case

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/signal_processing/lockin'
BUILD = 0x123456789abcdef0


class Bus:
    def __init__(self, words):
        self.words = dict(words)
        self.started = False
        self.acks = 0
        self.never_done = False
        self.fingerprint = BUILD
        self.writes = []

    def access(self, address, value=None):
        if value is not None:
            self.writes.append((address, value))
            if address == 12:
                self.started = True
            if address == 16:
                self.acks += 1
            return 0
        if address == 0:
            return 0x4c4f434b
        if address in (20, 24):
            return (self.fingerprint >> (32 if address == 24 else 0)) & 0xffffffff
        if address == 4:
            return (0 if self.never_done else 10) if self.started else 9
        if address == 8:
            return int(self.started)
        return self.words[address]


def main():
    r = subprocess.run([sys.executable, str(P/'tools/test_control.py')], cwd=ROOT, capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stdout+r.stderr)
    fixture = Path(re.search(r'Evidence=(.+)', r.stdout)[1].strip())
    words = {int(a): int(v) for run, a, v in re.findall(r'CSR_WORD run=(\d+) address=(\d+) value=(\d+)', (fixture/'run.log').read_text()) if run == '100'}
    cfg = configuration(1, [1000, 4000, 12000, 24000], [0, 32, 192, 96], 4, 100)
    bus = Bus(words)
    saved = []
    capture = run_case(bus, cfg, BUILD, lambda data: saved.append(deepcopy(data)))
    assert bus.acks == 1 and capture['status'] == 'ACKNOWLEDGED' and saved[-2]['status'] == 'VERIFIED'
    assert bus.writes[:16] == [(0x40+4*n, v) for n, v in enumerate(cfg['words'])]
    negatives = 0
    for address, value in [(0x80, 999), (0x84, 1), (0x90, 255), (0x94, 1), (0xa0, 1), (0xb0, 0), (0xb4, 0), (0xb8, 10000)]:
        bus = Bus(words);bus.words[address] = value
        try:
            run_case(bus, cfg, BUILD, lambda data: None)
        except ValueError:
            assert bus.acks == 0
            negatives += 1
        else:
            raise AssertionError('accepted corruption '+hex(address))
    bus = Bus(words);bus.fingerprint = 1
    try:
        run_case(bus, cfg, BUILD, lambda data: None)
    except ValueError:
        assert not bus.writes
        negatives += 1
    else:
        raise AssertionError('accepted wrong loaded image')
    bus = Bus(words);bus.never_done = True
    try:
        run_case(bus, cfg, BUILD, lambda data: None, max_polls=2)
    except TimeoutError:
        assert bus.acks == 0
        negatives += 1
    else:
        raise AssertionError('unbounded completion')
    out = ROOT/'artifacts/lockin_dsp_25k'/datetime.now(timezone.utc).strftime('host_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    (out/'capture.json').write_text(json.dumps(capture, indent=2)+'\n')
    report = dict(status='PASS', physical_measurement=False, rtl_fixture=str(fixture.relative_to(ROOT)),
                  negative_cases=negatives, scope='transport-neutral host; no physical UART/JTAG',
                  sources={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in [Path(__file__).resolve(), P/'tools/lockin_host.py']})
    (out/'summary.json').write_text(json.dumps(report, indent=2)+'\n')
    print('PASS actual RTL numeric fixture,host acceptance,10 corruption/identity/timeout guards,no ACK on failure')
    print('Evidence='+str(out))


if __name__ == '__main__':
    main()
