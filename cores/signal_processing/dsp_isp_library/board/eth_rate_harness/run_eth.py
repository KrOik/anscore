"""Ethernet (RMII) simulation, then optional synthesis/P&R/pack for
eth_rate_harness, the BLK2/RES2 block contract over UDP at 100M.

    python run_eth.py --core resampler
    python run_eth.py --core resampler --build

Simulation drives the DUT with real RMII octet streams (preamble, Ethernet,
IPv4, UDP, FCS) and records the octets the DUT transmits.  Every reply is
checked here: CRC-32, MAC/IP/UDP identity, declared datagram length, then the
reused drate oracle for the numbers.  Nothing is verified inside Verilog.
"""
import argparse, binascii, collections, datetime, hashlib, json, os, re, shutil
import struct, subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
LIB = HERE.parents[1]
ROOT = LIB.parents[1]

import eth_protocol as ep

CORES = ep.CORE_IDS          # name -> core id, same map as dsp_rate_harness
SHARED_RTL = ['board/block_harness/block_ram.v']
DDCDUC_RTL = ['dsp/ddcduc/rtl/ddcduc_iq_fir.sv', 'dsp/ddcduc/rtl/ddcduc_nco.sv',
              'infra/stream/stream_sync_fifo.v']
CORE_RTL = {
    0: ['dsp/resampler/rtl/polyphase_resampler.sv'],
    1: ['dsp/halfband/rtl/halfband_decim.sv'],
    2: ['dsp/halfband/rtl/halfband_interp.sv'],
    3: ['dsp/ddcduc/rtl/ddc_stream.sv'] + DDCDUC_RTL,
    4: ['dsp/ddcduc/rtl/duc_stream.sv'] + DDCDUC_RTL,
    # The ISP core: isp/median over the same block contract.  It pulls in the
    # infra/window raster engine it is built on.
    5: ['isp/median/median_stream.v', 'isp/median/median_network.v',
        'infra/window/stream_window_padded.v', 'infra/window/stream_window.v'],
    # DSP-16 channelizer: M and P are elaboration parameters, so the image
    # carries one geometry.  pfb_stream `include`s its generated coefficient
    # LUT, which is staged (suffix-filtered out of the read_verilog list).
    6: ['dsp/pfb/rtl/pfb_stream.sv', 'dsp/pfb/rtl/pfb_coeffs.vh'],
    # ISP-17 frame differencing.  Its reference RAM is internal to the core, so
    # the block carries four 4x4 frames rather than one image; no other core
    # needs the raster to repeat inside a block.
    7: ['isp/framediff/rtl/framediff_stream.sv'],
    # ISP-14 color correction + tone map.  Its config is a 211-entry shadow
    # image the harness itself loads, so unlike the ROM-backed cores there is no
    # generated coefficient file to stage -- the bundle table lives in the
    # harness top as a function and protocol.py's ccm_pack() mirrors it.
    8: ['isp/ccm/rtl/ccm_stream.sv'],
}

BOARD_MAC = '06:00:AA:BB:0C:EE'
HOST_MAC = '06:00:AA:BB:0C:01'
BOARD_IP = ep.ENDPOINT_IP
HOST_IP = '192.168.137.1'
HOST_PORT = 40000


def mac_bytes(text):
    return bytes(int(p, 16) for p in text.split(':'))


def ip_bytes(text):
    return bytes(int(p) for p in text.split('.'))


def ip_checksum(header):
    s = sum(struct.unpack('!%dH' % (len(header) // 2), header))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def udp_frame(payload, seq=0):
    """One IPv4/UDP datagram as Ethernet octets, FCS included, no preamble.

    The IPv4 header copies what Windows puts on the wire for a datagram this
    size: identification from the sequence, the DF flag set, TTL 128.  Modelling
    the synthetic 0x4000-id/no-flags/TTL-64 header instead hides receive bugs
    that only the real host's field values trigger.
    """
    ip_len = 20 + 8 + len(payload)
    udp = struct.pack('!HHHH', HOST_PORT, ep.UDP_PORT, 8 + len(payload), 0)
    ip = bytearray(struct.pack('!BBHHHBBH', 0x45, 0, ip_len, seq,
                               0x4000, 128, 17, 0) + ip_bytes(HOST_IP)
                   + ip_bytes(BOARD_IP))
    ip[10:12] = struct.pack('!H', ip_checksum(bytes(ip)))
    frame = mac_bytes(BOARD_MAC) + mac_bytes(HOST_MAC) + b'\x08\x00' + bytes(ip) \
        + udp + payload
    return frame + struct.pack('<I', binascii.crc32(frame) & 0xFFFFFFFF)


def rmii_octets(frame):
    """Preamble + SFD + frame, i.e. what the MAC actually puts on the wire."""
    return [0x55] * 7 + [0xD5] + list(frame)


def parse_frames(octets, lengths):
    """Split a recorded transmit octet stream into UDP payloads, checked.

    Frame boundaries come from the testbench's carrier (txen) log, not from
    searching for a byte value that also occurs inside payloads.  The preamble
    and SFD are verified, the minimum-size padding rule is checked against the
    IPv4 total-length field, and the CRC-32 is recomputed over the padded body.
    """
    out, pos = [], 0
    if sum(lengths) != len(octets):
        raise AssertionError(('frame lengths', sum(lengths), len(octets)))
    for flen in lengths:
        f = octets[pos:pos + flen]
        pos += flen
        if flen < 8 + 60 + 4:
            raise AssertionError(('short carrier burst', flen))
        if f[:7] != b'\x55' * 7 or f[7] != 0xD5:
            raise AssertionError(('missing preamble/SFD', f[:8].hex()))
        body, fcs = f[8:-4], f[-4:]
        if body[12:14] != b'\x08\x00':
            raise AssertionError(('non-IPv4 frame', body[:14].hex()))
        ihl = (body[14] & 0x0F) * 4
        if ihl < 20:
            raise AssertionError(('bad IHL', ihl))
        total = struct.unpack('!H', body[16:18])[0]
        if len(body) != max(14 + total, 60):
            raise AssertionError(('padding/length mismatch', len(body), total))
        if binascii.crc32(body) & 0xFFFFFFFF != struct.unpack('<I', fcs)[0]:
            raise AssertionError(('FCS mismatch', body[:4].hex()))
        if body[:6] != mac_bytes(HOST_MAC) or body[6:12] != mac_bytes(BOARD_MAC):
            raise AssertionError(('address mismatch', body[:12].hex()))
        if body[14 + 9] != 17:
            raise AssertionError('not UDP')
        ulen = struct.unpack('!H', body[14 + ihl + 4:14 + ihl + 6])[0]
        # A reply leaves the board from its own UDP_PORT and goes back to the
        # host port the request came from.
        sport = struct.unpack('!H', body[14 + ihl:14 + ihl + 2])[0]
        dport = struct.unpack('!H', body[14 + ihl + 2:14 + ihl + 4])[0]
        if sport != ep.UDP_PORT or dport != HOST_PORT:
            raise AssertionError(('wrong udp ports', sport, dport))
        if 14 + ihl + ulen > 14 + total:
            raise AssertionError(('udp length beyond ip total', ulen, total))
        out.append(body[14 + ihl + 8:14 + ihl + ulen])
    return out


def build_stim(core_id, protocol):
    """(stim lines, per-packet expectations) for one core."""
    packets = []
    for tag, cfg, words, stall in protocol.cases(core=core_id):
        packets.append(('block', ep.make_block_request(tag, cfg, words, stall,
                                                       core_id),
                        tag, cfg, words, stall, 0))
    # ---- PERSIST sessions (CORE 7) ------------------------------------------
    # rsvd=1 tells the parser not to pulse the core reset, so the reference frame
    # the PREVIOUS block wrote is what this block differences against.  That has
    # to show up as a difference: four one-frame blocks on a reset core each
    # re-seed and can output nothing but zeros, while the same four blocks in a
    # session produce the real frame-to-frame differences.  The session's numbers
    # come from ONE threaded model State, never from the RTL.
    if core_id == 7:
        npix = protocol.FD_W * protocol.FD_H
        scenes = [[v] * npix for v in (40, 200, 40, 200)]
        for k, sc in enumerate(scenes):          # control: no persistence
            tag = 0x5E050000 + k
            packets.append(('block', ep.make_block_request(tag, 0, sc, 0,
                                                           core_id),
                            tag, 0, sc, 0, 0))
        # One threaded model State per phase; rsvd=0 starts a fresh session in
        # the model exactly as it pulses the core reset in the RTL.
        def phase(base, seq):
            st = None
            for k, (sel, rsvd, sc) in enumerate(seq):
                tag = base + k
                if rsvd == 0:
                    st = protocol.fd_state()
                want = protocol._fd_run(sc, sel, st)
                packets.append(('session',
                                ep.make_block_request(tag, sel, sc, 0, core_id,
                                                      rsvd=rsvd, expected=want),
                                tag, sel, sc, 0, 0, (rsvd, want)))
        phase(0x5E150000, [(0, r, sc) for r, sc in zip((0, 1, 1, 1), scenes)])
        phase(0x5E250000, [(s, r, sc) for s, r, sc in
                           zip((0, 5, 5, 5), (0, 3, 1, 1), scenes)])
    # ---- PERSIST sessions (CORE 8) ------------------------------------------
    # Same transport question as CORE 7, different thing persisting: what survives
    # a rsvd=1 boundary here is the APPLIED BUNDLE.  A PERSIST block steps over
    # CONFIG, so it runs the bundle its previous block committed even though the
    # request itself carries a different config_word -- which is exactly the
    # differential: an image that ignored rsvd would apply the new bundle and
    # answer different pixels.  A RECONFIG block (rsvd=3) carries a new bundle AND
    # gets it, because CONFIG is re-entered and the commit applies at that block's
    # own first SOF.  `want` always comes from the model, never from the RTL.
    if core_id == 8:
        def block(base, k):
            return 0x5E650000 + base * 16 + k

        # Non-gray, in [96,160] per channel: clamp-free for every bundle (see
        # protocol.cases core 8) and different enough that bundles 0/3/5/7 cannot
        # agree by accident.
        scenes = [[(96 + 13 * c) | ((160 - 11 * c) << 8) | ((96 + 7 * c) << 16)
                   for c in range(8)] for _ in range(4)]

        def phase8(base, seq):
            applied = None
            for k, (sel, rsvd, w) in enumerate(seq):
                tag = block(base, k)
                alt = None
                if rsvd == 0:
                    applied = sel       # reset + CONFIG: this block's own bundle
                elif rsvd == 3:
                    # No reset, but CONFIG is re-entered, so the NEW bundle
                    # applies at this block's first SOF.  The interpretation this
                    # case falsifies is an image that stepped over CONFIG anyway,
                    # i.e. the PREVIOUS bundle -- and on a streaming, stateless
                    # core that is the ONLY thing a RECONFIG block can differ
                    # from, since a fresh reset with the same bundle would give
                    # the same numbers.
                    alt = protocol._ccm_run(w, applied)
                    applied = sel
                else:
                    # rsvd=1: CONFIG is skipped, so the core keeps running the
                    # bundle its previous block committed.  The interpretation
                    # this falsifies is an image that configured every block.
                    alt = protocol._ccm_run(w, sel)
                want = protocol._ccm_run(w, applied)
                if alt is not None and alt == want:
                    raise AssertionError(
                        'session case %d%d is not separable from an unpersisted '
                        'block (rsvd=%d sel=%d applied=%d)'
                        % (base, k, rsvd, sel, applied))
                packets.append(('session',
                                ep.make_block_request(tag, sel, w, 0, core_id,
                                                      rsvd=rsvd, expected=want),
                                tag, sel, w, 0, 0, (rsvd, want, alt)))

        # Controls: the same four scenes, every block configured from a reset.
        phase8(0, [(s, 0, sc) for s, sc in zip((0, 3, 5, 7), scenes)])
        # Persistence: blocks 1-3 ASK for bundle 5 but must keep running bundle 0.
        phase8(1, [(0, 0, scenes[0]), (5, 1, scenes[1]), (5, 1, scenes[2]),
                   (5, 1, scenes[3])])
        # Mid-session re-config: 0, then 3 (committed), then 7 (committed), then a
        # persisted block that asks for 5 while still running 7.
        phase8(2, [(0, 0, scenes[0]), (3, 3, scenes[1]), (7, 3, scenes[2]),
                   (5, 1, scenes[3])])
    # One BLK2 header that this core's parser accepts, so a negative test that
    # is *meant* to fail on some other rule does not trip the frame-length rule
    # instead.  CORE 5 pins in_count to one 8x8 frame and CORE 7 to four 4x4
    # frames -- both happen to be 64 words, which is why one constant serves.
    legal_n = ep.IMAGE_PIXELS if core_id in (5, 7) else 1
    long_n = ep.IMAGE_PIXELS if core_id in (5, 7) else 16
    # The lowest config_word this core must reject.  Hard-coding 15 would be a
    # legal bundle for CORE 7, which has 16 of them.
    bad_cfg = ep.config_count(core_id)
    # Reject paths: header-only requests that must come back with flags set and
    # no result words.  Same seven malformed configs the UART harness proves.
    rejects = [(0xBAD10001, 0, 0, 0, 0, 0, 1), (0xBAD10002, 0, 65, 0, 0, 0, 1),
               (0xBAD10003, 0, legal_n, 8, 1, 0, 1), (0xBAD10004, 0, legal_n, 0,
                                                       200, 0, 1),
               # rsvd is the session byte: 4 is out of range and 2 asks for
               # RECONFIG without PERSIST.  Both must be refused as malformed --
               # a silently ignored session request would run a block the host
               # believes is persistent, which is the worst possible failure.
               (0xBAD10005, 0, legal_n, 0, 1, 4, 1), (0xBAD10006, 0xFFFFFFFF,
                                                       legal_n, 0, 1, 0, 8),
               (0xBAD10007, bad_cfg, legal_n, 0, 1, 0, 8),
               (0xBAD10008, 0, legal_n, 0, 1, 2, 1)]
    for tag, cfg, n, stall, oexp, rsvd, flags in rejects:
        pkt = (ep.BLK_MAGIC + struct.pack(ep.HDR, tag, cfg, n, stall, oexp, rsvd)
               + (struct.pack('<%dI' % n, *([0x12345678] * n)) if flags == 8
                  else b''))
        import zlib
        pkt += struct.pack('<I', zlib.crc32(pkt))
        packets.append(('reject', pkt, tag, cfg, [], stall, flags))
    # Declared-count mismatch: a legal block whose out_expect is one too high.
    cfg, words, tag = 0, [0x1111] * long_n, 0xBAD20001
    exp = ep.model_oracle(cfg, words, core_id)
    pkt = (ep.BLK_MAGIC + struct.pack(ep.HDR, tag, cfg, len(words), 0,
                                      min(len(exp) + 1, 128), 0)
           + struct.pack('<%dI' % len(words), *words))
    import zlib
    pkt += struct.pack('<I', zlib.crc32(pkt))
    packets.append(('countmismatch', pkt, tag, cfg, words, 0, 0x20))
    # Integrity negatives: a request whose in-payload CRC-32 trailer is wrong
    # must be dropped WITHOUT any reply, and the parser must still serve the
    # requests after it.  Interleaved rather than appended, because a parser that
    # fails to resynchronise after a drop looks to the host exactly like a dead
    # dock, and nothing else in the case list sends a corrupt request at all.
    for tag, where in [(0xBAD30001, 'head'), (0xBAD30002, 'tail')]:
        bad_words = [0x12345678] * long_n
        payload = bytearray(ep.make_block_request(tag, 0, bad_words, 0, core_id))
        payload[-2] ^= 0x01
        item = ('silent', bytes(payload), tag, 0, bad_words, 0, 0)
        if where == 'head':
            packets.insert(next(i for i, q in enumerate(packets)
                                if q[0] == 'block') + 1, item)
        else:
            packets.append(item)
    # Liveness poll, answered by the 44-byte STAT datagram.
    packets.append(('status', ep.make_status_request(), 0, 0, [], 0, 0))
    return packets


def check_reply(kind, data, tag, cfg, words, stall, want_flags, core_id,
                protocol, seq, acc=None, replies=None, want=None, silent=0):
    if kind == 'status':
        st = ep.parse_status_response(data)
        if st['core_id'] != core_id:
            raise AssertionError(('STAT core id', st['core_id'], core_id))
        # The core id is the only defined field of that word; the harness drives
        # its upper 24 bits with zeros, so any other value is corruption.
        if st['core_index_and_flags'] != core_id:
            raise AssertionError(('STAT core word',
                                  st['core_index_and_flags'], core_id))
        # The cumulative counters must agree with the per-block reports the same
        # run produced, byte for byte; otherwise a STAT reply could be silently
        # corrupted and the poll would still look alive.
        if acc is not None:
            for key, want in (('cycles_total', acc['cycles']),
                              ('words_in', acc['words_in']),
                              ('words_out', acc['words_out']),
                              ('blocks', acc['blocks'])):
                if st[key] != want:
                    raise AssertionError(('STAT ' + key, st[key], want, acc))
        if replies is not None:
            # In this simulation every carrier burst is one of our UDP requests.
            # The pipe counts a complete frame at end of carrier and a datagram
            # when its last payload octet leaves the parser, so the poll's own
            # request is already in rx_udp but not yet in rx_frames, and the poll
            # reply has not finished when tx_frames is snapshotted.  Dropped
            # requests still arrive as frames and datagrams, so they count in
            # rx_frames/rx_udp but never in tx_frames.
            if st['rx_frames'] != replies + silent:
                raise AssertionError(('pipe frame counter', st, replies, silent))
            if st['tx_frames'] != replies:
                raise AssertionError(('pipe tx counter', st, replies))
            if st['rx_udp'] != replies + 1 + silent:
                raise AssertionError(('pipe udp counter', st['rx_udp'],
                                      replies, silent))
            # rx_err is the pipe's own rejection count.  Nothing else in the
            # flow puts a bad datagram on the wire, so it must equal the number
            # of dropped requests -- zero error is not the expectation any more
            # once the CRC negatives are in the stream.
            if st['rx_err'] != silent or st['ping']:
                raise AssertionError(('pipe error counter', st['rx_err'], silent,
                                      st['ping']))
        return dict(kind=kind, status=st)
    if kind == 'reject':
        if len(data) != ep.BLK_RESP_BYTES:
            raise AssertionError(('reject length', len(data)))
        if data[:4] != ep.RES_MAGIC:
            raise AssertionError(('reject magic', data[:4]))
        rt, rc, n, flags, inc, outc, cycles = struct.unpack(ep.RPT, data[4:20])
        if (rt, rc) != (tag, cfg) or (flags & 0x7F) != want_flags:
            raise AssertionError(('reject header', rt, rc, flags, want_flags))
        # A rejected request must report that it consumed and produced nothing;
        # the RTL zeroes the counters on both the malformed and config-reject
        # paths, so a non-zero echo here means the reply came from a run that
        # should never have started.
        if n != 0 or inc != 0:
            raise AssertionError(('reject counts', n, inc))
        if cycles != 0:
            raise AssertionError(('reject cycles', cycles))
        if outc != 0 or any(b for b in data[20:]):
            raise AssertionError('reject carried results')
        return dict(kind=kind, tag=rt, flags=flags,
                    flag_names=ep.flag_names(flags))
    if kind == 'countmismatch':
        # A legal block whose declared out_expect is wrong: the numbers must be
        # the model's, flags[5] must be the only flag set, and the run must have
        # consumed and produced the real counts.  The strict drate verifier is
        # not used here because it treats any flag as a failure.
        if len(data) != ep.BLK_RESP_BYTES or data[:4] != ep.RES_MAGIC:
            raise AssertionError(('count mismatch framing', len(data),
                                  data[:4]))
        rt, rc, n, flags, inc, outc, cycles = struct.unpack(ep.RPT, data[4:20])
        if (rt, rc, n) != (tag, cfg, len(words)):
            raise AssertionError(('count mismatch header', rt, rc, n))
        if (flags & 0x7F) != want_flags:
            raise AssertionError(('count mismatch flags', flags, want_flags))
        want = ep.model_oracle(cfg, words, core_id)
        if inc != len(words) or outc != len(want) or cycles == 0:
            raise AssertionError(('count mismatch counters', inc, outc, cycles))
        if list(struct.unpack('<%dI' % outc, data[20:20 + 4 * outc])) != want:
            raise AssertionError('count mismatch changed the numbers')
        if outc < ep.MAX_RESULT_WORDS and any(b for b in data[20 + 4 * outc:]):
            raise AssertionError('count mismatch padding is not zero')
        return dict(kind=kind, tag=rt, outc=outc, inc=inc, cycles=cycles,
                    flags=flags)
    if kind == 'session':
        rsvd, want_words = want[0], want[1]
        # A persisted block only counts as evidence if its numbers could not
        # have come from a reset core.  Without this the differential would be
        # vacuous: an image that ignored the session byte and reset anyway would
        # still match a model that had also forgotten to persist.  For a
        # streaming core (CORE 8) a reset block and a persisted block under the
        # same bundle agree by construction, so the caller names the alternative
        # it actually checked against; otherwise this guard would either reject
        # every RECONFIG case or wave through a vacuous one.
        alt = want[2] if len(want) > 2 else ep.model_oracle(cfg, words, core_id)
        if rsvd and alt is not None and list(alt) == list(want_words):
            raise AssertionError(('persisted block identical to unpersisted',
                                  tag, cfg))
        want = want_words
    res = ep.parse_block_response(data, tag, cfg, words, stall, core=core_id,
                                  expected=want)
    return dict(kind=kind, tag=res['tag'], outc=res['outc'], inc=res['inc'],
                cycles=res['cycles'], flags=res['flags'])


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--core', choices=sorted(ep.CORE_NAMES.values()),
                   required=True)
    p.add_argument('--build', action='store_true')
    # Diagnostic-only synth variant: -nodsp maps every multiplier to LUT logic,
    # so a board round on that image can tell "the hard DSP cell misbehaves on
    # silicon" apart from "something else is wrong".  It does not relax any gate.
    p.add_argument('--nodsp', action='store_true')
    # Same idea for block RAM: -nobram would keep every inferred memory in
    # fabric, separating "the 18 Kb BSRAM primitive behaves differently from
    # what the toolchain assumes" from everything else.  The shipped Gowin deck
    # has DPX9B/SDPX9B as empty black boxes, so a BSRAM-mapped state array is
    # the one part of an image nothing can simulate.  This yosys build ignores
    # -nobram (see the gate below), so the option currently only serves to
    # prove that fact; no image is delivered under this label.
    p.add_argument('--nobsram', action='store_true')
    p.add_argument('--freq', type=int, default=50, help='PnR timing target MHz')
    p.add_argument('--out', default=None)
    a = p.parse_args()
    core_id = ep.core_id(a.core)
    dest = Path(a.out) if a.out else (
        HERE / 'evidence' /
        f'{a.core}_{datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f")}')
    dest.mkdir(parents=True, exist_ok=True)
    cad = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
    env = dict(os.environ)
    env['PATH'] = (str(cad / 'bin') + os.pathsep + str(cad / 'lib')
                   + os.pathsep + env['PATH'])
    protocol = ep._load_protocol()

    sim_only = [HERE / 'pll_6m_sim.v', HERE / 'tb_eth_rate.sv']
    # iverilog uses the behavioural PLL stand-in above; yosys must see the real
    # Gowin rPLL wrapper, so it is staged but kept out of the simulation list.
    synth_only = [HERE / 'PLL_6M.v']
    files = ([HERE / 'eth_rate_harness.v', HERE / 'rmii_eth_pipe.sv',
              HERE / 'eth_support.sv',
              LIB / 'board/dsp_rate_harness/dsp_rate_harness_rom.vh']
             + [LIB / s for s in CORE_RTL[core_id] + SHARED_RTL]
             + [ROOT / 'cores/image_processing/window/sim/gowin_bsram_sim.v'])
    for f in files + sim_only + synth_only:
        if not f.is_file():
            raise FileNotFoundError(str(f))
        shutil.copy2(f, dest / f.name)
    for f in [HERE / 'run_eth.py', HERE / 'eth_protocol.py',
              HERE / 'top_eth.cst']:
        shutil.copy2(f, dest / (f.name if f.name != 'top_eth.cst'
                                else 'top.cst'))
    shutil.copy2(LIB / 'board/dsp_rate_harness/protocol.py', dest / 'protocol.py')
    model = {'resampler': 'dsp/resampler/models/reference.py',
             'hb_decim': 'dsp/halfband/models/reference.py',
             'hb_interp': 'dsp/halfband/models/reference.py',
             'ddc': 'dsp/ddcduc/models/model.py',
             'duc': 'dsp/ddcduc/models/model.py',
             'median': 'isp/median/model.py',
             'pfb': 'dsp/pfb/models/model.py',
             'framediff': 'isp/framediff/models/model.py',
             'ccm': 'isp/ccm/models/model.py'}[a.core]
    alias = {'resampler': 'rs_ref.py', 'hb_decim': 'hb_ref.py',
             'hb_interp': 'hb_ref.py', 'ddc': 'dd_ref.py', 'duc': 'dd_ref.py',
             'median': 'med_ref.py', 'pfb': 'pfb_ref.py',
             'framediff': 'fd_ref.py', 'ccm': 'ccm_ref.py'}[a.core]
    shutil.copy2(LIB / model, dest / alias)
    (dest / 'hashes.json').write_text(json.dumps(
        {f.name: hashlib.sha256(f.read_bytes()).hexdigest()
         for f in files + sim_only + synth_only}, indent=2))
    (dest / 'variant.json').write_text(json.dumps(
        dict(core=core_id, core_name=a.core, transport='rmii-udp'), indent=2))

    packets = build_stim(core_id, protocol)
    stim, expects = '', []
    for seq, item in enumerate(packets):
        kind, payload, tag, cfg, words, stall, wflags = item[:7]
        want = item[7] if len(item) > 7 else None
        octets = rmii_octets(udp_frame(payload, seq))
        # preamble(7) + SFD(1) + Ethernet(14) + IPv4(20) + UDP(8) + payload + FCS(4).
        # tb_eth_rate's second field counts RECEIVED reply-frame octets, so a
        # request that must be dropped is declared as expecting zero: a reply
        # length there would make the TB wait for a datagram that correctly never
        # arrives, which looks exactly like a hang in the design.
        if kind == 'silent':
            wire = 0
        else:
            rlen = ep.BLK_RESP_BYTES if kind != 'status' else ep.STA_RESP_BYTES
            wire = 8 + 14 + 28 + rlen + 4
        stim += f'{len(octets)} {wire}\n' + \
            ''.join(f'{b:02x}\n' for b in octets)
        expects.append(dict(kind=kind, tag=tag, cfg=cfg, words=words,
                            stall=stall, wflags=wflags, want=want))
    (dest / 'stim.txt').write_text(stim)

    def run(cmd, log):
        cmd = [shutil.which(cmd[0], path=env['PATH']) or cmd[0], *cmd[1:]]
        with (dest / log).open('w') as f:
            f.write('$ ' + ' '.join(str(c) for c in cmd) + '\n')
            f.flush()
            r = subprocess.run([str(c) for c in cmd], cwd=dest, env=env,
                               stdout=f, stderr=subprocess.STDOUT)
        if r.returncode:
            raise RuntimeError(f'{log} failed; see {dest}')

    rtl = [f.name for f in files if f.suffix in ('.v', '.sv')
           and f.name not in ('tb_eth_rate.sv', 'gowin_bsram_sim.v',
                              'pll_6m_sim.v')]
    run(['iverilog', '-g2012', '-Wall', '-I.', '-I' + str(HERE),
         '-s', 'tb_eth_rate', f'-Ptb_eth_rate.CORE={core_id}',
         '-o', 'sim.vvp', 'tb_eth_rate.sv', 'pll_6m_sim.v', 'gowin_bsram_sim.v',
         *rtl], 'compile.log')
    run(['vvp', 'sim.vvp', '+stim=stim.txt', '+trace=trace.txt',
         '+len=trace.txt.len'], 'simulation.log')
    toks = (dest / 'trace.txt').read_text().split()
    undef = [t for t in toks if not re.fullmatch(r'[0-9a-f]{2}', t)]
    if undef:
        raise AssertionError(('undefined octets on the wire', undef[:8],
                              len(undef), 'of', len(toks)))
    raw = bytes(int(x, 16) for x in toks)
    (dest / 'raw.bin').write_bytes(raw)
    lengths = [int(v) for v in (dest / 'trace.txt.len').read_text().split()]
    (dest / 'tx_frame_lengths.json').write_text(json.dumps(lengths, indent=2))
    payloads = parse_frames(raw, lengths)
    # Dropped requests answer nothing by design; every other packet must be
    # answered, and one reply too many means a corrupt request was served.
    answered = [e for e in expects if e['kind'] != 'silent']
    if len(payloads) != len(answered):
        raise AssertionError(('datagram count', len(payloads), 'replies for',
                              len(answered), 'answerable of', len(expects)))
    results = []
    # Mirror the harness's own cumulative counters so the final STAT poll can be
    # checked against the per-block reports this same run produced.  Only blocks
    # that reach the RUN state move cyc_total/words_in/words_out/blocks_done:
    # malformed and config-rejected requests answer from the parse state.
    acc = dict(cycles=0, words_in=0, words_out=0, blocks=0)

    def acc_add(r):
        if r['kind'] not in ('block', 'countmismatch', 'session'):
            return
        if r['flags'] & 0x40:
            raise AssertionError('overflow reply not modelled in the '
                                 'STAT accumulator')
        for key, field in (('cycles', 'cycles'), ('words_in', 'inc'),
                           ('words_out', 'outc')):
            acc[key] = (acc[key] + r[field]) & 0xFFFFFFFF
        acc['blocks'] = (acc['blocks'] + 1) & 0xFFFFFFFF

    n_silent = len(expects) - len(answered)
    for exp, data in zip(answered, payloads):
        summary = acc.copy() if exp['kind'] == 'status' else None
        r = check_reply(exp['kind'], data, exp['tag'], exp['cfg'],
                        exp['words'], exp['stall'], exp['wflags'],
                        core_id, protocol, len(results), acc=summary,
                        replies=len(results), want=exp['want'],
                        silent=n_silent)
        results.append(r)
        acc_add(r)
        # the verifier must reject a corrupted reply
        for pos in [0, 4, 12, 13, 20, max(20, len(data) - 1)]:
            bad = bytearray(data)
            bad[pos] ^= 1
            try:
                if exp['kind'] in ('block', 'session'):
                    ep.parse_block_response(bytes(bad), exp['tag'],
                                            exp['cfg'], exp['words'],
                                            exp['stall'], core=core_id,
                                            expected=(exp['want'][1]
                                                      if exp['want'] else None))
                else:
                    check_reply(exp['kind'], bytes(bad), exp['tag'], exp['cfg'],
                                exp['words'], exp['stall'], exp['wflags'],
                                core_id, protocol, 0, acc=summary,
                                replies=len(results) - 1)
            except AssertionError:
                pass
            else:
                raise AssertionError(('corruption accepted', exp['kind'], pos,
                                      len(data)))
    (dest / 'simulation_summary.json').write_text(json.dumps(dict(
        status='PASS', core=core_id, core_name=a.core, transport='rmii-udp',
        packets=len(results), results=results,
        wire_octets=len(raw)), indent=2))
    print('ETH SIM PASS', dest, flush=True)
    if not a.build:
        return

    opts = (' -nodsp' if a.nodsp else '') + (' -nobram' if a.nobsram else '')
    (dest / 'build.ys').write_text(
        'read_verilog -sv -I. ' + ' '.join(rtl + ['PLL_6M.v'])
        + '\nchparam -set CORE %d eth_rate_harness' % core_id
        + '\nsynth_gowin -noalu%s -family gw2a -top eth_rate_harness'
        ' -json top.json\nstat\n' % opts)
    run(['yosys', '-s', 'build.ys'], 'synthesis.log')
    net = json.loads((dest / 'top.json').read_text())
    counts = collections.Counter(
        c['type'] for c in net['modules']['eth_rate_harness']['cells'].values())
    lut = sum(v for k, v in counts.items() if re.fullmatch(r'LUT[1-4]|ALU', k))
    dsp = sum(v for k, v in counts.items()
              if k.startswith(('MULT', 'PADD', 'ALU54')))
    # yosys emits the 18 Kb block as DPX9B/DPB/SDPX9B/SDPB/SPX9/SP; only nextpnr
    # calls it "BSRAM" (its utilisation line reads "BSRAM: 5/46").  Matching the
    # literal name BSRAM here reported bsram=0 for every image ever built, so a
    # core whose state landed in block RAM looked identical to one that had
    # none -- and block RAM is exactly the mapping a simulation of the RTL
    # cannot see, because the shipped Gowin deck has those cells as black boxes.
    bram = sum(v for k, v in counts.items()
               if k in ('DPX9B', 'DPB', 'SDPX9B', 'SDPB', 'SPX9', 'SP'))
    # Measured on 2026-10-03: this yosys build runs MEMORY_LIBMAP and reads
    # gowin/brams_map.v even with -nobram, so the option changes nothing and an
    # image labelled nobsram would silently still carry block RAM.  Fail loudly
    # rather than hand the board a misleading discriminator.
    if a.nobsram and bram:
        raise AssertionError(('--nobsram had no effect: %d BSRAM cells remain'
                              % bram))
    dram = sum(v for k, v in counts.items()
               if re.match(r'RAM(16|[DS])', k) or k.startswith('RAMW'))
    ff = sum(v for k, v in counts.items()
             if re.match(r'(DFF|DL|SD|DAGR|SRESET)', k))
    (dest / 'synthesis_counts.json').write_text(json.dumps(
        dict(lut=lut, dsp=dsp, bsram=bram, distributed_ram=dram, ff=ff,
             cells=dict(counts)), indent=2))
    if lut > 15000 or dsp > 4:
        raise AssertionError('resource gate')
    run(['nextpnr-himbaechel', '--json', 'top.json', '--write', 'pnr.json',
         '--device', 'GW2A-LV18PG256C8/I7', '--vopt', 'family=GW2A-18',
         '--vopt', 'cst=top.cst', '--freq', str(a.freq), '--seed', '1',
         '--log', 'nextpnr.log'], 'pnr_console.log')
    log = (dest / 'nextpnr.log').read_text()
    routed = re.search(r'\bLUT4:\s+(\d+)', log)
    # nextpnr's own device utilisation is the authority on what actually landed
    # in the 18 Kb blocks; keep it beside the synthesis count.
    pnr_bram = re.search(r'\bBSRAM:\s+(\d+)/\s*(\d+)', log)
    pairs = re.findall(r"Max frequency for clock '?([^':\s]+)'?:\s*([\d.]+)\s*MHz",
                       log)
    clocks = [float(f) for _, f in pairs]
    if not routed or int(routed[1]) > 15000 or not clocks:
        raise AssertionError('route gate')
    # The block contract only holds at the PHY reference rate, so the 50 MHz
    # domain must actually place and route at 50 MHz; the PLL-derived MDC and
    # 6 MHz nets are slow by design and only need their own rate.
    required = {'clk50m': 50.0, 'clk': 27.0, 'clk6m': 6.0, 'clk1m': 1.0}
    for name, freq in pairs:
        for key, floor in required.items():
            if re.search(r'(^|\W)%s(\W|$)' % key, name):
                if float(freq) < floor:
                    raise AssertionError(('timing gate', name, freq, floor))
    (dest / 'timing_report.json').write_text(json.dumps(dict(
        clocks={name: float(freq) for name, freq in pairs},
        required=required), indent=2))
    python = cad / 'lib/python3.exe'
    if not python.exists():
        python = cad / 'bin/python.exe'
    run([str(python), str(cad / 'bin/gowin_pack-script.py'), '-d', 'GW2A-18',
         '-o', 'eth.fs', 'pnr.json'], 'pack.log')
    (dest / 'build_summary.json').write_text(json.dumps(dict(
        status='BUILD_PASS_NOT_BOARD', core=core_id, core_name=a.core,
        target_clock_mhz=a.freq, fmax_reported_mhz=list(map(float, clocks)),
        lut=lut, dsp=dsp, routed_lut4=int(routed[1]),
        bsram=bram, distributed_ram=dram,
        bsram_placed=(int(pnr_bram[1]) if pnr_bram else None),
        nodsp=bool(a.nodsp), nobsram=bool(a.nobsram),
        bitstream_sha256=hashlib.sha256(
            (dest / 'eth.fs').read_bytes()).hexdigest()), indent=2))
    print('BUILD PASS', dest)


if __name__ == '__main__':
    main()
