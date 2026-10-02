"""Host mirror of stim_25k.v: the packet byte stream the FPGA emits on-chip.

The dock's USB-UART bridge cannot drive pad B3, so 25K board rounds feed their
cases from inside the fabric.  This module is the *only* definition of the
payload data for those rounds; the descriptors (tag/config/count/stall) are
taken verbatim from the frozen protocol.cases().  Reports are still checked with
the frozen protocol.verify()/oracle(), which is independent of the DUT, and
tb_rom_harness_25k.sv compares the RTL byte stream against this mirror byte for
byte, so the two can never drift apart silently.

Word shapes and the LFSR are documented in stim_25k.v.
"""
import struct

PATTERN, SINGLE, DOUBLE = 0, 1, 2
K = 0x9E3779B9
PATTERN_WORDS = (0x0000, 0x8000, 0x7FFF, 0x03E8)


def step(s):
    fb = ((s >> 31) ^ (s >> 21) ^ (s >> 1) ^ s) & 1
    return ((s << 1) | fb) & 0xFFFFFFFF


def seed_for(index, base):
    return (base + index * K) & 0xFFFFFFFF


def words(desc, seed):
    """Exactly the words stim_25k.v puts on the harness's rx pin."""
    s = seed
    out = []
    shape, mask, shift, imp = desc['shape'], desc['mask'], desc['shift'], desc['imp']
    for j in range(desc['count']):
        n1 = step(s)
        n2 = step(n1)
        n3 = step(n2)
        s = n3
        if shape == PATTERN:
            w = PATTERN_WORDS[j & 3]
        elif shape == SINGLE:
            w = n1 & mask
        else:
            w = (n1 & mask) | ((n2 & mask) << shift)
            if imp and j % 7 == 0:
                w = n3 & 3
        w &= 0xFFFFFFFF
        # the DC chain's payload is signed16: the same 16 bits, read as s16, which
        # is what its frozen oracle() consumes.
        if desc.get('signed16') and (w & 0x8000):
            w -= 1 << 16
        out.append(w)
    return out


def packet(magic, desc, seed):
    wl = words(desc, seed)
    fmt = 'h' if desc.get('signed16') else 'I'
    return (magic + struct.pack('<IIBB', desc['tag'], desc['config'],
                                desc['count'], desc['stall'])
            + struct.pack('<' + fmt * len(wl), *wl)), wl


def shape_for(family, core, bits):
    if family == 'dstream':
        # core 3 (lms) and core 5 (the agc_power bundle) take full 32-bit words --
        # the bundle packs I at [15:0] and Q at [31:16] -- the rest are s16 payloads
        return (SINGLE, 0xFFFFFFFF if core in (3, 5) else 0xFFFF, 0, 0)
    if family == 'isp':
        # two pixels per 32-bit word, low lane at [bits-1:0] and high lane at
        # [16+bits-1:16] -- exactly how the frozen protocol.cases() packs them
        return (DOUBLE, (1 << bits) - 1, 16, 1)
    if family == 'chain_isp':
        # the CSC->morphology chain takes one RGB pixel per word: r,g,b at
        # [2*bits:0], which is a single masked draw of the low 3*bits lanes
        return (SINGLE, (1 << (3 * bits)) - 1, 0, 0)
    if family == 'chain_dsp':
        # the DC->statistics chain packet carries one signed16 sample per word,
        # two bytes each, exactly as its frozen make_packet() packs them
        return (SINGLE, 0xFFFF, 0, 0)
    if core == 0:
        return (PATTERN, 0, 0, 0)
    if core == 1:
        return (SINGLE, (1 << (3 * bits)) - 1, 0, 0)
    return (SINGLE, 0xFFFFFFFF, 0, 0)


def descriptors(family, core, work, bits=8, seed=0xA5A51234,
                bad_config=False):
    """Case descriptors from the frozen case list, plus packet-level negatives.

    ``work`` is protocol.cases(...) output: (tag, config, words, stall).  The
    word lists there are ignored; only count/stall/config/tag are reused.
    """
    shape, mask, shift, imp = shape_for(family, core, bits)
    signed16 = (family == 'chain_dsp')
    out = []
    for tag, config, wl, stall in work:
        out.append(dict(kind='case', tag=tag, config=config, count=len(wl),
                        stall=stall, shape=shape, mask=mask, shift=shift,
                        imp=imp, signed16=signed16))
    out.append(dict(kind='neg_count', tag=0xBAD00001, config=0, count=0,
                    stall=0, shape=shape, mask=mask, shift=shift, imp=0,
                    flags=1, signed16=signed16))
    if bad_config:
        out.append(dict(kind='neg_config', tag=0xBAD00002, config=0xFFFFFFFF,
                        count=1, stall=0, shape=shape, mask=mask, shift=shift,
                        imp=0, flags=8, signed16=signed16))
    for i, d in enumerate(out):
        d['index'] = i
        d['seed'] = seed_for(i, seed)
    return out


def byte_stream(outs, magic=b'BLK1', seed=0xA5A51234):
    """The whole round's emitted stimulus, and the words per case."""
    data = b''
    all_words = []
    for d in outs:
        pkt, wl = packet(magic, d, d['seed'])
        data += pkt
        all_words.append(wl)
    return data, all_words
