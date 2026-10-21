"""Host-side codec + UDP transport for eth_rate_harness (RMII/BLK2/RES2/STAT).

The block semantics, canned configurations, model oracle and verifier are NOT
reimplemented here: they are imported by path from
``board/dsp_rate_harness/protocol.py`` (not a package, so importlib is used).
This module only adapts them to the Ethernet datagram framing, where one
request datagram carries one block and one response datagram carries one
report plus fixed zero padding.

Wire contract (must match board/eth_rate_harness/eth_rate_harness.v):
  request  'BLK2' tag(4LE) config(4LE) in_count(1) stall(1) out_expect(1)
           rsvd(1, 0) + in_count * 32-bit words   (1 <= in_count <= 60)
  request  'STA1'                                          (4 bytes)
  reply    'RES2' tag config in_count flags inc outc cycles(4LE)
           + 128 * 32-bit words          ALWAYS 532 bytes, zero padded past
                            the header is a contract violation, not a truncation
  reply    'STAT' + 10 * 32-bit LE counters  ALWAYS 44 bytes:
           rx_frames rx_udp ping tx_frames rx_err cycles_total words_in
           words_out blocks core_index_and_flags (opaque u32, low 8 bits =
           configured CORE id, exposed raw)

Transport limits: this path carries at most ETH_IN_CAP (64) input words per
block, the same per-block limit as the UART harness's IN_CAP, and captures at
most MAX_RESULT_WORDS (128) result words.  Reported cycles are 20 ns each (50 MHz
PHY reference domain), so cycle counts are only converted to a data rate when
the caller supplies that clock via --clock-mhz.  For a core with no flush port
the count stops at the block's last input/output handshake, not at the end of
the 4095-cycle quiet window that proves the core is done, so it is a core
runtime rather than a wall-clock observation.

Usage:
    python eth_protocol.py --self-test        # no hardware needed
"""
import argparse, importlib.util, json, socket, struct, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
LIB = HERE.parents[1]                                  # cores/signal_processing/dsp_isp_library
PROTOCOL_PATH = LIB / 'board' / 'dsp_rate_harness' / 'protocol.py'

BLK_MAGIC, RES_MAGIC = b'BLK2', b'RES2'
STA_MAGIC_REQ, STA_MAGIC_RESP = b'STA1', b'STAT'
XG_MAGIC_REQ, XG_MAGIC_RESP = b'XG1 ', b'XG1 '   # input-store echo (diagnostic)
ETH_IN_CAP = 64            # per-block input word limit of this transport
MAX_RESULT_WORDS = 128     # result words carried by one RES2 datagram
BLK_RESP_BYTES = 20 + 4 * MAX_RESULT_WORDS   # 532, always
STA_RESP_BYTES = 44
HDR = '<IIBBBB'            # tag config in_count stall out_expect rsvd
RPT = '<IIBBBBI'           # tag config in_count flags inc outc cycles
STA_FIELDS = ('rx_frames', 'rx_udp', 'ping', 'tx_frames', 'rx_err',
              'cycles_total', 'words_in', 'words_out', 'blocks',
              'core_index_and_flags')

ENDPOINT_IP = '192.168.137.16'
UDP_PORT = 11452
FPGA_MAC = '06:00:AA:BB:0C:EE'

# protocol.py flag bits; every bit except bit7 is a hard error there.
FLAG_NAMES = {0: 'malformed_packet', 1: 'rx_framing_error',
              2: 'rx_outside_load', 3: 'config_rejected', 4: 'watchdog',
              5: 'outc_ne_out_expect', 6: 'output_capacity_error',
              7: 'sticky_output_clip'}


def _load_protocol():
    if not PROTOCOL_PATH.exists():
        raise FileNotFoundError('drate protocol.py not found: %s' % PROTOCOL_PATH)
    spec = importlib.util.spec_from_file_location('drate_protocol',
                                                  PROTOCOL_PATH)
    mod = importlib.util.module_from_spec(spec)
    sys.modules['drate_protocol'] = mod
    spec.loader.exec_module(mod)
    return mod


protocol = _load_protocol()
CORE_NAMES = dict(protocol.CORE_NAMES)   # 0 resampler .. 4 duc, 5 median (ISP)
CORE_IDS = {v: k for k, v in CORE_NAMES.items()}
# CORE 5 carries one isp/median 8x8 frame per block: the RTL parser rejects any
# other in_count, so the sweep's short length classes simply do not model.
IMAGE_PIXELS = protocol.MEDIAN_PIXELS


def core_id(name):
    if name not in CORE_IDS:
        raise ValueError('unknown core %r; pick one of %s'
                         % (name, ', '.join(sorted(CORE_IDS))))
    return CORE_IDS[name]


def config_count(core):
    return protocol.config_count(core=core)


def model_oracle(config, words, core):
    """Expected result words from the independent model (never from the DUT)."""
    return protocol.oracle(config, words, core=core)


def flag_names(flags):
    return [name for bit, name in sorted(FLAG_NAMES.items())
            if (flags >> bit) & 1]


# ------------------------------------------------------------ requests ----
def make_block_request(tag, config, words, stall, core, oracle_fn=None,
                       rsvd=0, expected=None):
    """One BLK2 request datagram; out_expect comes from the model oracle.

    `rsvd` is the session control byte (bit 0 PERSIST, bit 1 RECONFIG);
    `expected` supplies the result words for a session block whose numbers the
    isolated per-block oracle cannot know, and only its length is used here.
    """
    words = list(words)
    oracle_fn = oracle_fn or model_oracle
    if not 1 <= len(words) <= ETH_IN_CAP:
        raise ValueError('in_count %d outside 1..%d for this transport'
                         % (len(words), ETH_IN_CAP))
    if not 0 <= stall <= 7:
        raise ValueError('stall')
    if not 0 <= rsvd <= 3:
        raise ValueError('rsvd %d outside 0..3' % rsvd)
    if expected is None:
        expected = oracle_fn(config, words, core)
    if len(expected) > MAX_RESULT_WORDS:
        raise ValueError('out_expect %d beyond the %d-word capture'
                         % (len(expected), MAX_RESULT_WORDS))
    body = (BLK_MAGIC + struct.pack(HDR, tag, config, len(words), stall,
                                    len(expected), rsvd)
            + struct.pack('<%dI' % len(words), *words))
    # CRC-32 trailer: the dock PHY clips ~2 octets off the carrier tail, so
    # the wire FCS cannot be verified at the FPGA; integrity rides inside the
    # payload instead (the FPGA checks the residue before running the core).
    import zlib
    return body + struct.pack('<I', zlib.crc32(body))


def make_status_request():
    """The 4-byte STA1 liveness/counter poll."""
    return STA_MAGIC_REQ


def make_store_request():
    """The 4-byte XG1 poll: report what the input store holds for the last block.

    Answers with rxor of the stored words, the number stored, and the first and
    last stored word, so the host can prove the octet-to-word assembly delivered
    exactly what it sent - which pay_ok (CRC over the pipe's own emitted octets)
    and flags[1] (a word stored for every declared input) do not cover.
    """
    return XG_MAGIC_REQ


def parse_store_response(data):
    """Decode an XG1 datagram into the store-echo fields."""
    if len(data) != STA_RESP_BYTES:
        raise AssertionError(('store response length', len(data)))
    if data[:4] != XG_MAGIC_RESP:
        raise AssertionError(('store response magic', data[:4]))
    w = struct.unpack('<10I', data[4:])
    return dict(rxor=w[0], words_written=w[1], word_first=w[2], word_last=w[3],
                count=w[4], input_count=w[5], flags=w[6], data_words=w[7],
                out_expect=w[8], core_id=w[9] & 0xFF)


# ------------------------------------------------------------ responses ---
def parse_block_response(data, tag, config, words, stall, core, expected=None):
    """Decode a RES2 datagram and verify it against the model.

    The datagram is fixed length; it is sliced to 20 + 4*outc before being
    handed to the reused drate verifier, which owns all the checks (identity,
    hard flags, counts, sticky clip, cycles, numerics).  `expected` overrides
    the per-block oracle for a PERSIST session block.  Raises AssertionError
    on any violation.
    """
    if len(data) != BLK_RESP_BYTES:
        raise AssertionError(('block response length', len(data),
                              'expected', BLK_RESP_BYTES))
    if data[:4] != RES_MAGIC:
        raise AssertionError(('block response magic', data[:4]))
    rt, rc, n, flags, inc, outc, cycles = struct.unpack(RPT, data[4:20])
    if outc > MAX_RESULT_WORDS:
        raise AssertionError(('outc exceeds capture', outc))
    if not all(b == 0 for b in data[20 + 4 * outc:]) and outc < MAX_RESULT_WORDS:
        bad_at = next(i for i, b in enumerate(data[20 + 4 * outc:]) if b)
        raise AssertionError(('non-zero zero-pad region', 'first bad byte at',
                              20 + 4 * outc + bad_at,
                              data[20 + 4 * outc + bad_at:][:8].hex()))
    sliced = data[:20 + 4 * outc]
    result = protocol.verify(sliced, tag, config, words, stall, core=core,
                             expected=expected)
    return dict(status=result['status'], tag=rt, config=rc, in_count=n,
                flags=flags, flag_names=flag_names(flags), inc=inc, outc=outc,
                cycles=cycles, words=list(struct.unpack('<%dI' % outc,
                                                         sliced[20:])),
                verify=result)


def parse_status_response(data):
    """Decode a STAT datagram into the ten named u32 counters."""
    if len(data) != STA_RESP_BYTES:
        raise AssertionError(('status response length', len(data),
                              'expected', STA_RESP_BYTES))
    if data[:4] != STA_MAGIC_RESP:
        raise AssertionError(('status response magic', data[:4]))
    raw = struct.unpack('<10I', data[4:])
    out = dict(zip(STA_FIELDS, raw))
    out['core_id'] = out['core_index_and_flags'] & 0xFF
    out['core_name'] = CORE_NAMES.get(out['core_id'], 'unknown')
    return out


def status_delta(before, after):
    """Counter deltas across a traffic window, wrapping at 2**32."""
    mask = (1 << 32) - 1
    return {k: (after[k] - before[k]) & mask for k in STA_FIELDS}


# ------------------------------------------------------- synthetic board --
def synth_block_response(config, words, core, cycles=None):
    """Model the FPGA's 532-byte RES2 reply for --self-test / --dry-run only.

    Builds exactly what the wire contract promises (zero padding beyond the
    results, sticky-clip in bit7, clean low flag bits).  Never used for real
    board traffic.
    """
    expected = model_oracle(config, words, core)
    if cycles is None:
        cycles = 500 + 40 * len(words)
    flags = protocol.expected_clip(config, words, core=core) << 7
    return (RES_MAGIC + struct.pack(RPT, 0, config, len(words), flags,
                                    len(words), len(expected), cycles)
            + struct.pack('<%dI' % len(expected), *expected)
            + b'\x00' * (4 * (MAX_RESULT_WORDS - len(expected))))


def synth_status_response(core, counters=None):
    """Model a 44-byte STAT reply for --self-test / --dry-run only."""
    vals = dict(zip(STA_FIELDS, (0,) * 10))
    vals.update(counters or {})
    vals['core_index_and_flags'] = core & 0xFF
    return STA_MAGIC_RESP + struct.pack('<10I', *[vals[k] for k in STA_FIELDS])


def retitle_response(data, tag):
    """Stamp a synthetic RES2 with the request tag (self-test helper)."""
    rt, rc, n, flags, inc, outc, cycles = struct.unpack(RPT, data[4:20])
    return (RES_MAGIC + struct.pack(RPT, tag, rc, n, flags, inc, outc, cycles)
            + data[20:])


# -------------------------------------------------------------- transport -
class EthClient:
    """Single UDP socket bound to the wired NIC; request/response by datagram.

    The design replies to the source address of the request, so one bound
    socket serves the whole session.  Datagrams that are not from the endpoint
    or carry no known magic are counted and discarded rather than mis-parsed.

    `broadcast` puts requests on the wire as 255.255.255.255 while replies are
    still filtered by the endpoint address.  It exists because the dock accepts
    a limited-broadcast datagram but drops every unicast IPv4 datagram we send
    it (board counters: rx_frames advances, rx_udp never does); replies come
    back unicast, so only the request direction needs the workaround.
    """

    def __init__(self, bind_ip='192.168.137.1', target_ip=ENDPOINT_IP,
                 port=UDP_PORT, source_port=0, timeout=2.0, broadcast=False):
        self.target = (target_ip, port)
        self.send_target = target_ip
        self.timeout = timeout
        self.discarded = []
        self.tx_datagrams = 0
        self.tx_bytes = 0
        self.rx_datagrams = 0
        self.rx_bytes = 0
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind((bind_ip, source_port))
        if broadcast:
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            self.send_target = '255.255.255.255'
        self.local = self.sock.getsockname()

    def close(self):
        self.sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def exchange(self, payload, magic, timeout=None):
        """Send one request datagram, wait for a reply carrying `magic` from
        the endpoint, and return (datagram, round-trip time in us)."""
        t0 = time.perf_counter()
        self.sock.sendto(payload, (self.send_target, self.target[1]))
        self.tx_datagrams += 1
        self.tx_bytes += len(payload)
        deadline = t0 + (timeout or self.timeout)
        while True:
            remaining = deadline - time.perf_counter()
            if remaining <= 0:
                raise TimeoutError('no %r reply from %s within %.2fs'
                                   % (magic, self.target[0],
                                      (timeout or self.timeout)))
            self.sock.settimeout(remaining)
            data, addr = self.sock.recvfrom(4096)
            if addr[0] != self.target[0] or data[:4] != magic:
                self.discarded.append(dict(
                    peer=addr[0], length=len(data), magic=data[:4].hex(),
                    reason='peer' if addr[0] != self.target[0] else 'magic'))
                continue
            rtt_us = int((time.perf_counter() - t0) * 1e6)
            self.rx_datagrams += 1
            self.rx_bytes += len(data)
            return data, rtt_us

    def status(self, timeout=None):
        data, rtt_us = self.exchange(make_status_request(), STA_MAGIC_RESP,
                                     timeout=timeout)
        return parse_status_response(data), rtt_us

    def block(self, tag, config, words, stall, core, timeout=None):
        req = make_block_request(tag, config, words, stall, core)
        data, rtt_us = self.exchange(req, RES_MAGIC, timeout=timeout)
        return parse_block_response(data, tag, config, words, stall, core), rtt_us


# --------------------------------------------------------------- self-test -
def _plan(config, words, core):
    """Longest prefix of `words` the model can evaluate within transport
    limits, or None.  Some canned configs need a minimum block length and
    interpolation-heavy configs overflow the 128-word capture on long blocks."""
    for n in range(min(len(words), ETH_IN_CAP), 0, -1):
        w = list(words[:n])
        try:
            out = model_oracle(config, w, core)
        except Exception:
            continue
        if len(out) <= MAX_RESULT_WORDS:
            return w, len(out)
    return None


def _cases_for_self_test():
    import random
    rng = random.Random(20261001)
    plans = []
    for core in sorted(CORE_NAMES):
        base = protocol.cases(core=core)
        for sel in range(config_count(core)):
            src = [t for t in base if t[1] == sel]
            words = (list(src[0][2]) if src else
                     [rng.randrange(65536) if core < 3 else
                      (rng.randrange(-9000, 9000) & 0xFFFF)
                      | ((rng.randrange(-9000, 9000) & 0xFFFF) << 16)
                      for _ in range(24)])
            # CORE 5's block length is fixed by the frame contract (one 8x8
            # image) and CORE 6's must stay a whole number of M-channel frames,
            # so the short-block variant only applies to the rate cores.
            # CORE 7 is fixed too, and for the opposite reason: fewer than
            # FD_FRAMES frames would leave the cross-frame reference with
            # nothing to be differenced against.
            if sel % 2 == 0 and core not in (5, 6, 7):
                words = words[:2]
            plans.append((core, sel, words))
    return plans


def _drate_packet_ref_usable():
    """protocol.make_packet picks its default core from a variant.json sitting
    next to itself or in cwd, which is not this harness's state.  Only use it
    as a byte-for-byte reference when no such side-file is in play."""
    return not ((PROTOCOL_PATH.parent / 'variant.json').exists()
                or (Path.cwd() / 'variant.json').exists())


def self_test():
    """Round-trip every core/config through the model and prove the parsers
    reject corrupt input.  No hardware, no sockets."""
    log, fails = [], []
    ref_usable = _drate_packet_ref_usable()

    def check(name, fn):
        try:
            fn()
            log.append('ok   %s' % name)
        except Exception as exc:
            fails.append(name)
            log.append('FAIL %s -> %r' % (name, exc))

    for core, sel, words in _cases_for_self_test():
        planned = _plan(sel, words, core)
        if planned is None:
            fails.append('plan core%d cfg%d' % (core, sel))
            log.append('FAIL plan core%d cfg%d: no block length modelable'
                       % (core, sel))
            continue
        w, outn = planned
        tag = (0xE7E50000 + (core << 8) + sel) & 0xFFFFFFFF
        stall = (core + sel) & 7

        def positive(core=core, sel=sel, w=w, tag=tag, stall=stall, outn=outn,
                     ref_usable=ref_usable):
            req = make_block_request(tag, sel, w, stall, core)
            if ref_usable:
                # byte-exact agreement with the reused drate packet builder
                model_oracle(sel, w, core)      # primes drate's core default
                ref = protocol.make_packet(tag, sel, w, stall)
                if req != ref:
                    raise AssertionError('request bytes differ from drate builder')
            if len(req) != 16 + 4 * len(w):
                raise AssertionError('request length')
            resp = retitle_response(synth_block_response(sel, w, core), tag)
            got = parse_block_response(resp, tag, sel, w, stall, core)
            if got['status'] != 'PASS' or got['outc'] != outn:
                raise AssertionError(('decode', got['status'], got['outc'], outn))
            if got['words'] != model_oracle(sel, w, core):
                raise AssertionError('decoded words')
            if got['cycles'] < len(w):
                raise AssertionError('cycles')
            # the verifier itself must reject a flipped bit: the last result
            # byte, or the cycles field when the block legitimately emits none
            bad = bytearray(resp)
            bad[19 if outn == 0 else 20 + 4 * outn - 1] ^= 1
            try:
                parse_block_response(bytes(bad), tag, sel, w, stall, core)
            except AssertionError:
                pass
            else:
                raise AssertionError('corrupt result accepted')

        check('block core%d(%s) cfg%d n=%d out=%d'
              % (core, CORE_NAMES[core], sel, len(w), outn), positive)

    def negatives():
        core, sel = 0, 0
        w = [0x1111, 0x2222, 0x3333, 0x4444]
        tag = 0xFEEDF00D
        good = retitle_response(synth_block_response(sel, w, core), tag)
        for name, mutated in [
            ('magic', b'XXXX' + good[4:]),
            ('short frame', good[:531]),
            ('long frame', good + b'\x00'),
            ('pad polluted', good[:20] + good[20:500]
             + b'\xff' + good[501:]),
            ('wrong tag', retitle_response(good, tag ^ 1)),
        ]:
            try:
                parse_block_response(mutated, tag, sel, w, 0, core)
            except (AssertionError, struct.error):
                pass
            else:
                raise AssertionError('%s accepted' % name)
        for too_many in ([0] * (ETH_IN_CAP + 1),):
            try:
                make_block_request(tag, sel, too_many, 0, core)
            except ValueError:
                pass
            else:
                raise AssertionError('in_count limit not enforced')
        try:
            make_block_request(tag, sel, w, 8, core)
        except ValueError:
            pass
        else:
            raise AssertionError('stall limit not enforced')

    check('block parser negatives', negatives)

    def status_roundtrip():
        vals = dict(rx_frames=1234, rx_udp=900, ping=33, tx_frames=870,
                    rx_err=0, cycles_total=4_000_000, words_in=5000,
                    words_out=6000, blocks=90, core_index_and_flags=3)
        data = synth_status_response(3, vals)
        got = parse_status_response(data)
        if any(got[k] != v for k, v in vals.items()):
            raise AssertionError(('status counters', got, vals))
        if got['core_name'] != 'ddc':
            raise AssertionError('core id decode')
        d = status_delta(parse_status_response(synth_status_response(3)), got)
        if d['words_out'] != 6000 or d['rx_frames'] != 1234:
            raise AssertionError('status delta')
        for name, mutated in [('stat magic', b'XXXX' + data[4:]),
                              ('short', data[:43]), ('long', data + b'\x00')]:
            try:
                parse_status_response(mutated)
            except (AssertionError, struct.error):
                pass
            else:
                raise AssertionError('%s accepted' % name)

    check('status round-trip + negatives', status_roundtrip)

    def contract_shapes():
        if BLK_RESP_BYTES != 532 or STA_RESP_BYTES != 44:
            raise AssertionError('shape constants drifted')
        if make_status_request() != b'STA1':
            raise AssertionError('STA1')

    check('wire shape constants', contract_shapes)

    for line in log:
        print(line)
    print('self-test: %d checks, %d failures' % (len(log) + len(fails),
                                                 len(fails)))
    return 0 if not fails else 1


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument('--self-test', action='store_true',
                   help='codec/model round-trip without hardware')
    a = p.parse_args()
    if a.self_test:
        return self_test()
    print(json.dumps(dict(endpoint_ip=ENDPOINT_IP, udp_port=UDP_PORT,
                          mac=FPGA_MAC, eth_in_cap=ETH_IN_CAP,
                          blk_resp_bytes=BLK_RESP_BYTES,
                          sta_resp_bytes=STA_RESP_BYTES,
                          cores=CORE_NAMES), indent=2))
    print('nothing to do; use --self-test or import from run_eth_round.py')
    return 0


if __name__ == '__main__':
    sys.exit(main())
