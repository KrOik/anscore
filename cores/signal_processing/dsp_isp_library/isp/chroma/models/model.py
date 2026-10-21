"""ISP-15 chroma resampling and pixel packing reference models.

Two layers:
  * float/exact-rational functions  -> ideal algorithm values (error bounds)
  * integer functions               -> bit-exact contract shared with the RTL

Geometry conventions (all modules):
  frames are HEIGHT lines of WIDTH pixels, raster order.
  4:4:4 input pixel word: {Y, Cb, Cr} MSB->LSB, tuser=SOF at (0,0),
  tlast=EOL at x==WIDTH-1.

chroma_422 (4:4:4 -> 4:2:2):
  one output beat per chroma column pair, ceil(W/2) beats per line:
      word = {Y_even, Cb_f, Y_odd, Cr_f}  MSB->LSB   (YUYV field order)
  siting 0 (co-sited left): chroma at even columns, FIR [1,2,1]/4.
  siting 1 (centre): chroma midway between columns 2i and 2i+1,
      FIR [1,3,3,1]/8.
  Replicate edge extension; odd W -> last pair is a single column, the
  missing luma slot is a replicate of the last luma.

chroma_420 (4:4:4 or 4:2:2 -> 4:2:0):
  tagged interleaved beats, word = {tag, A, B}:
      tag 0 -> luma pair {Y_even, Y_odd}   (one beat per column pair)
      tag 1 -> chroma    {Cb, Cr}          (only on odd lines, plus the
                                            last line when H is odd)
  Vertical decimation is FIR [1,2,1]/4 co-sited with the *even* line of
  each two-line group, replicate extension at frame edges.

pix_pack / pix_unpack:
  NS samples of BITS bits grouped into one word of NS*SLOT bits where
  SLOT = max(SLOT, BITS) (SLOT in {0,8,16}; 0 -> tight BITS packing).
  First sample occupies the MSB slot.  A tlast flushes a partial group,
  remaining (LSB) slots are zero.  Unpack emits NS samples per word in
  MSB->LSB order; a flushed word therefore re-expands to NS samples with
  zero samples before tlast.
"""

from fractions import Fraction


def _c(i, n):
    """Replicate-clamp index."""
    return min(max(i, 0), n - 1)


def _mask(bits):
    return (1 << bits) - 1


# ------------------------------------------------------------------ horizontal

def h_decimate_int(line, siting):
    """Horizontal anti-alias decimation by 2 (bit-exact, round-half-up)."""
    w = len(line)
    out = []
    for i in range((w + 1) // 2):
        if siting == 0:
            s = line[_c(2 * i - 1, w)] + 2 * line[_c(2 * i, w)] + line[_c(2 * i + 1, w)]
            out.append((s + 2) >> 2)
        elif siting == 1:
            s = (line[_c(2 * i - 1, w)] + 3 * line[_c(2 * i, w)]
                 + 3 * line[_c(2 * i + 1, w)] + line[_c(2 * i + 2, w)])
            out.append((s + 4) >> 3)
        else:
            raise ValueError('unsupported siting %r' % siting)
    return out


def h_decimate_float(line, siting):
    """Same filters evaluated in exact rationals (no output rounding)."""
    w = len(line)
    out = []
    for i in range((w + 1) // 2):
        if siting == 0:
            s = Fraction(line[_c(2 * i - 1, w)]) + 2 * line[_c(2 * i, w)] \
                + line[_c(2 * i + 1, w)]
            out.append(s / 4)
        elif siting == 1:
            s = (Fraction(line[_c(2 * i - 1, w)]) + 3 * line[_c(2 * i, w)]
                 + 3 * line[_c(2 * i + 1, w)] + line[_c(2 * i + 2, w)])
            out.append(s / 8)
        else:
            raise ValueError('unsupported siting %r' % siting)
    return out


# ------------------------------------------------------------------ 4:2:2 beat

def chroma422_beats(frame, bits, siting):
    """frame[y][x] = (Y, Cb, Cr).  Returns [(word, user, last), ...]."""
    h = len(frame)
    w = len(frame[0])
    ow = (w + 1) // 2
    beats = []
    for y in range(h):
        cbf = h_decimate_int([p[1] for p in frame[y]], siting)
        crf = h_decimate_int([p[2] for p in frame[y]], siting)
        for i in range(ow):
            ye = frame[y][2 * i][0]
            yo = frame[y][_c(2 * i + 1, w)][0]   # replicate pad for odd W
            word = (ye << (3 * bits)) | (cbf[i] << (2 * bits)) \
                | (yo << bits) | crf[i]
            beats.append((word, int(y == 0 and i == 0), int(i == ow - 1)))
    return beats


def chroma422_float_chroma(frame, siting):
    """Float chroma planes (per line): (cb_rows, cr_rows) of Fraction lists."""
    cb_rows = []
    cr_rows = []
    for y in range(len(frame)):
        cb_rows.append(h_decimate_float([p[1] for p in frame[y]], siting))
        cr_rows.append(h_decimate_float([p[2] for p in frame[y]], siting))
    return cb_rows, cr_rows


# ------------------------------------------------------------------ 4:2:0 beat

def chroma420_beats(beats422, ow, height, bits):
    """Tagged 4:2:0 beats from a 4:2:2 pair-word stream.

    beats422: [(word, user, last)] in raster order, ow beats/line.
    word = {Y_even, Cb, Y_odd, Cr} (chroma_422 output format).
    Output word = {tag, A, B}: tag 0 -> {Y_even,Y_odd}, tag 1 -> {Cb,Cr}.
    """
    mask = _mask(bits)
    h = height
    hcb = [[(r[0] >> (2 * bits)) & mask for r in beats422[y * ow:(y + 1) * ow]]
           for y in range(h)]
    hcr = [[r[0] & mask for r in beats422[y * ow:(y + 1) * ow]]
           for y in range(h)]
    out = []
    for y in range(h):
        emit_c = (y & 1) == 1 or y == h - 1     # odd line, or last line (odd H)
        j = y >> 1
        for i in range(ow):
            wv = beats422[y * ow + i][0]
            ye = (wv >> (3 * bits)) & mask
            yo = (wv >> bits) & mask
            out.append(((ye << bits) | yo, int(y == 0 and i == 0),
                        int(i == ow - 1 and not emit_c)))
            if emit_c:
                # vertical [1,2,1]/4 co-sited with even line 2j, edges replicate
                cb = (hcb[_c(2 * j - 1, h)][i] + 2 * hcb[2 * j][i]
                      + hcb[_c(2 * j + 1, h)][i] + 2) >> 2
                cr = (hcr[_c(2 * j - 1, h)][i] + 2 * hcr[2 * j][i]
                      + hcr[_c(2 * j + 1, h)][i] + 2) >> 2
                out.append(((1 << (2 * bits)) | (cb << bits) | cr, 0,
                            int(i == ow - 1)))
    return out


def chroma420_from444(frame, bits, siting):
    """4:4:4 frame -> tagged 4:2:0 beats (horizontal siting selectable)."""
    ow = (len(frame[0]) + 1) // 2
    return chroma420_beats(chroma422_beats(frame, bits, siting), ow,
                           len(frame), bits)


def chroma420_float_chroma(frame, siting):
    """Float 4:2:0 chroma planes: h filter float, then v [1,2,1]/4 float."""
    h = len(frame)
    fcb, fcr = chroma422_float_chroma(frame, siting)
    rows = (h + 1) // 2
    vcb = []
    vcr = []
    for j in range(rows):
        for_plane = []
        for_plane_r = []
        ow = len(fcb[0])
        for i in range(ow):
            a = fcb[_c(2 * j - 1, h)][i]
            b = fcb[2 * j][i]
            c = fcb[_c(2 * j + 1, h)][i]
            for_plane.append((a + 2 * b + c) / 4)
            ar = fcr[_c(2 * j - 1, h)][i]
            br = fcr[2 * j][i]
            cr_ = fcr[_c(2 * j + 1, h)][i]
            for_plane_r.append((ar + 2 * br + cr_) / 4)
        vcb.append(for_plane)
        vcr.append(for_plane_r)
    return vcb, vcr


# ------------------------------------------------------------------ pixel pack

def slot_width(bits, slot):
    if slot not in (0, 8, 16):
        raise ValueError('unsupported SLOT %r' % slot)
    s = slot if slot else bits
    if s < bits:
        raise ValueError('SLOT narrower than BITS')
    return s


def pack_words(samples, ns, bits, slot):
    """samples: [(v,u,l)].  Returns [(word,u,l)].
    First sample in MSB slot; tlast flushes a partial group with zero pad."""
    slt = slot_width(bits, slot)
    if not (1 <= ns <= 8):
        raise ValueError('unsupported NS %r' % ns)
    out = []
    cur = []
    for v, u, l in samples:
        if u and cur:
            raise ValueError('SOF inside unfinished group')
        cur.append((v, u))
        if len(cur) == ns or l:
            word = 0
            for k in range(ns):
                sv = cur[k][0] if k < len(cur) else 0
                word |= sv << ((ns - 1 - k) * slt)
            out.append((word, cur[0][1], int(l)))
            cur = []
    return out


def unpack_samples(words, ns, bits, slot):
    """words: [(word,u,l)].  Returns [(v,u,l)] - always ns samples per word."""
    slt = slot_width(bits, slot)
    mask = _mask(bits)
    out = []
    for w, u, l in words:
        for k in range(ns):
            v = (w >> ((ns - 1 - k) * slt)) & mask
            out.append((v, int(k == 0 and u), int(k == ns - 1 and l)))
    return out


def roundtrip(samples, ns, bits, slot):
    """unpack(pack(samples)) - original stream right-padded with zeros
    up to the group boundary before each tlast."""
    return unpack_samples(pack_words(samples, ns, bits, slot), ns, bits, slot)


# ------------------------------------------------------------------ self test

def _self_test():
    # siting 0 keeps positions on even columns, siting 1 centres between them
    line = [0, 40, 80, 120, 160, 200]
    assert h_decimate_int(line, 0) == [(0 + 0 + 40 + 2) >> 2,
                                       (40 + 160 + 120 + 2) >> 2,
                                       (120 + 320 + 200 + 2) >> 2]
    ramp = list(range(64))
    for s in (0, 1):
        fi = h_decimate_int(ramp, s)
        ff = h_decimate_float(ramp, s)
        assert len(fi) == len(ff) == 32
        assert max(abs(a - float(b)) for a, b in zip(fi, ff)) <= 0.5
    # constant fields are invariant under every filter combination
    flat = [[(7, 100, 200)] * 5 for _ in range(5)]
    for s in (0, 1):
        for wv, u, l in chroma422_beats(flat, 8, s):
            assert (wv >> 24 & 0xff) == 7 and (wv >> 16 & 0xff) == 100
            assert (wv >> 8 & 0xff) == 7 and (wv & 0xff) == 200
        beats420 = chroma420_from444(flat, 8, s)
        for wv, u, l in beats420:
            if wv >> 16:
                assert (wv >> 8 & 0xff) == 100 and (wv & 0xff) == 200
    # pack/unpack round trip
    rng = [(i * 37) & 0xff for i in range(11)]
    samp = [(v, int(i == 0), int(i == 10)) for i, v in enumerate(rng)]
    rt = roundtrip(samp, 4, 8, 0)
    assert [v for v, u, l in rt][:11] == rng and rt[11][0] == 0
    assert [u for v, u, l in rt] == [1] + [0] * 11
    assert rt[-1][2] == 1 and all(l == 0 for v, u, l in rt[:-1])
    words = pack_words(samp, 4, 8, 0)
    assert len(words) == 3 and words[0][0] == (rng[0] << 24) | (rng[1] << 16) \
        | (rng[2] << 8) | rng[3]
    # partial word: 3 samples occupy the 3 MSB slots, LSB slot is zero
    assert words[2][0] == (rng[8] << 24) | (rng[9] << 16) | (rng[10] << 8)
    # float vs int error bound on random frames
    import random
    r = random.Random(7)
    fr = [[(r.randrange(256), r.randrange(256), r.randrange(256))
           for x in range(9)] for y in range(6)]
    for s in (0, 1):
        fcb, _ = chroma422_float_chroma(fr, s)
        icb = [h_decimate_int([p[1] for p in row], s) for row in fr]
        err = max(abs(float(fcb[y][i]) - icb[y][i])
                  for y in range(6) for i in range(5))
        assert err <= 0.5, err
    print('model self-test PASS')


if __name__ == '__main__':
    _self_test()
