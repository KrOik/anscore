"""Transport-neutral, bounded numerical acceptance for coherent lock-in runs."""
import math
import hashlib
import json
from pathlib import Path
ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
import time


def signed(value, bits):
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def configuration(bins, amplitudes, phases, period=16, run_id=0):
    if type(bins) is not int or bins not in (1, 3, 7):
        raise ValueError('acceptance uses coherent bins 1,3,7 per256')
    if len(amplitudes) != 4 or any(type(a) is not int or not 1 <= a <= 32767 for a in amplitudes):
        raise ValueError('four nonzero unsigned amplitudes required')
    if len(phases) != 4 or any(type(a) is not int or not 0 <= a <= 255 for a in phases):
        raise ValueError('four byte phase indices required')
    if type(period) is not int or not 4 <= period <= 1000000 or type(run_id) is not int or not 0 <= run_id < 2**32:
        raise ValueError('period/id range')
    pairs = lambda values: [values[n] | values[n+1] << 16 for n in (0, 2)]
    words = [bins << 24, period, 8, run_id, 256*period+4096]
    words += pairs(amplitudes) + [sum(a << (8*n) for n, a in enumerate(phases))]
    words += [0, 0, 0x80008000, 0x80008000, 0, 0, 0, 0]
    return dict(words=words, bins=bins, amplitudes=list(amplitudes), phases=list(phases))


def golden(config):
    c = [round(32767*math.cos(2*math.pi*n/256)) for n in range(256)]
    s = [round(32767*math.sin(2*math.pi*n/256)) for n in range(256)]
    result = []
    for a, phase in zip(config['amplitudes'], config['phases']):
        indices = [n*config['bins'] % 256 for n in range(256)]
        samples = [a*c[(n+phase) % 256] >> 15 for n in indices]
        result.append((sum(x*c[n] for x, n in zip(samples, indices)) >> 23,
                       -sum(x*s[n] for x, n in zip(samples, indices)) >> 23))
    return result


def identify(bus, build_id):
    if not 0 < build_id < 2**64 or bus.access(0) != 0x4c4f434b:
        raise ValueError('lock-in identifier')
    if bus.access(20) | bus.access(24) << 32 != build_id:
        raise ValueError('loaded build fingerprint differs')


def run_case(bus, config, build_id, save, seconds=10, max_polls=10000):
    if not math.isfinite(seconds) or seconds <= 0 or type(max_polls) is not int or max_polls < 1:
        raise ValueError('finite positive polling bounds required')
    # Validate metadata and words before touching hardware.
    expected_config = configuration(config['bins'], config['amplitudes'], config['phases'], config['words'][1], config['words'][3])
    if config != expected_config:
        raise ValueError('configuration metadata/word mismatch')
    expected = golden(config)
    identify(bus, build_id)
    if bus.access(4) != 9:
        raise ValueError('requires idle, no result or pending command')
    version = bus.access(8)
    for n, value in enumerate(config['words']):
        bus.access(0x40+4*n, value)
    bus.access(12, 1)
    deadline = time.monotonic()+seconds
    for _ in range(max_polls):
        status = bus.access(4)
        if status & 2:
            break
        if time.monotonic() >= deadline:
            raise TimeoutError('measurement completion timeout; no automatic ACK/retry')
        time.sleep(.001)
    else:
        raise TimeoutError('completion poll limit')
    capture = dict(status='READING', build_id=f'{build_id:016x}', configuration=config, words={})
    save(capture)
    for addr in list(range(0x80, 0xa8, 4)) + list(range(0xb0, 0xe0, 4)):
        value = bus.access(addr)
        if type(value) is not int or not 0 <= value < 2**32:
            raise ValueError('invalid CSR word')
        capture['words'][f'{addr:02x}'] = value
        save(capture)
    w = capture['words']
    if w['80'] != config['words'][3] or w['84'] or w['8c'] != 256 or w['90'] != 256 or w['94']:
        raise ValueError('ID/error/sample accounting')
    first = w['98'] | w['9c'] << 32
    last = w['a0'] | w['a4'] << 32
    if last-first != 255*config['words'][1] or not 0 < w['88'] < config['words'][4]:
        raise ValueError('timestamp/cycle span')
    rows = []
    for lane, (i, q) in enumerate(expected):
        packed = w[f'{0xb0+12*lane:02x}']
        actual = signed(packed & 65535, 16), signed(packed >> 16, 16)
        amplitude = w[f'{0xb4+12*lane:02x}']
        phase = signed(w[f'{0xb8+12*lane:02x}'], 32)/16384
        amplitude_error = abs(amplitude-config['amplitudes'][lane])
        target = config['phases'][lane]*2*math.pi/256
        phase_error = abs((phase-target+math.pi) % (2*math.pi)-math.pi)
        if actual != (i, q) or amplitude_error > 12 or phase_error > .06:
            raise ValueError('numeric mismatch lane='+str(lane))
        rows.append(dict(lane=lane, i=actual[0], q=actual[1], amplitude=amplitude,
                         phase_rad=phase, amplitude_error=amplitude_error, phase_error_rad=phase_error))
    identify(bus, build_id)
    if bus.access(8) != (version+1) % 2**32 or bus.access(4) != status or bus.access(0x80) != w['80']:
        raise ValueError('incoherent held completion')
    capture.update(status='VERIFIED', lanes=rows, first_timestamp=first, last_timestamp=last)
    save(capture)
    bus.access(16, 1)
    capture['status'] = 'ACKNOWLEDGED'
    save(capture)
    return capture


def validate_build(path):
    build=json.loads(path.read_text())
    if build['status']!='PASS' or build['target']!='GW5A-LV25MG121NES' or build['clock_mhz']!=50:
        raise ValueError('requires completed50MHz25K build')
    if any(c['achieved']<50 or c['constraint']!=50 for c in build['pnr_report']['fmax'].values()) or not build['pnr_report']['fmax']:
        raise ValueError('physical timing not closed')
    if hashlib.sha256((path.parent/'lockin.fs').read_bytes()).hexdigest()!=build['bitstream_sha256']:
        raise ValueError('packed image hash mismatch')
    for name,digest in build['sources'].items():
        if hashlib.sha256((ROOT/name).read_bytes()).hexdigest()!=digest:raise ValueError('current source differs: '+name)
    fingerprint=hashlib.sha256(json.dumps(build['sources'],sort_keys=True,separators=(',',':')).encode()).hexdigest()[:16]
    if fingerprint!=build['hardware_build_id']:raise ValueError('build fingerprint manifest mismatch')
    return build

