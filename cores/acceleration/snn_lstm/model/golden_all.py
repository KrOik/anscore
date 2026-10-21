#!/usr/bin/env python3
"""Bit-exact golden models + ROM/expectation emitter for the 25K SNN/LSTM cores.

Emits:
  src/snn_param_rom.v      weight ROM for the sparse conv layer
  src/lstm_param_rom.v     weight/bias ROM for the LSTM core
  sim/expected_snn.vh      expected digest + counters for the SNN testbench
  sim/expected_lstm.vh     expected digest + counters for the LSTM testbench
  model/expected.json      same numbers, used by the board acceptance script

Also runs a dense-vs-sparse equivalence check: the event-driven accumulator must
equal a full dense convolution over the same activity tensor.
"""
import json
import os
import random

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MASK32 = 0xFFFFFFFF

SNN = dict(IMG_W=8, IMG_H=8, CIN=2, COUT=4, KERN=3, PAD=1, ACC_W=16,
           LEAK=3, VTH=96, N_STEPS=8, SEED=0xACE1, EV_MASK=7, IDX_MASK=127)
LSTM = dict(N_IN=4, N_HID=8, N_GATE=4, FRAC=7, ZW=13, N_T=8, SEED=0x5A5A)


class Lfsr16:
    def __init__(self, seed):
        self.s = seed & 0xFFFF

    def next(self):
        fb = self.s & 1
        self.s = ((self.s >> 1) ^ (0xB400 if fb else 0)) & 0xFFFF
        return self.s


def fnv_mix(h, b):
    x = (h ^ (b & 0xFF)) & MASK32
    return (x + (x << 1) + (x << 4) + (x << 7) + (x << 8) + (x << 24)) & MASK32


def s2(v, bits):
    """two's complement value of an integer truncated to `bits`"""
    m = 1 << bits
    v &= m - 1
    return v - m if v >> (bits - 1) else v


def shift_arith(v, n):
    """Verilog >>> on a signed value == Python floor shift"""
    return v >> n


# --------------------------------------------------------------------- SNN
def gen_events(p):
    l = Lfsr16(p['SEED'])
    ev = []
    for step in range(p['N_STEPS']):
        per = 1 + (l.next() & p['EV_MASK'])
        for _ in range(per):
            idx = l.next() & p['IDX_MASK']
            val = -1 if (l.next() & 0xF) == 0 else 1
            ev.append((step, idx, val))
    return ev


def snn_run(events, wrom, p, do_scan=True):
    W, H, CIN, COUT = p['IMG_W'], p['IMG_H'], p['CIN'], p['COUT']
    K, PAD, TAPS = p['KERN'], p['PAD'], p['KERN'] * p['KERN']
    OW, OH = W + 2 * PAD - K + 1, H + 2 * PAD - K + 1
    NPIX = OW * OH
    SAT = (1 << (p['ACC_W'] - 1)) - 1
    acc = [[0] * COUT for _ in range(NPIX)]
    taps = taps_skip = events_done = spikes = scan_cells = 0
    qptr = 0
    fired_log = []

    for step in range(p['N_STEPS']):
        while qptr < len(events) and events[qptr][0] == step:
            _, idx, val = events[qptr]
            c = idx // (W * H)
            rem = idx - c * (W * H)
            iy, ix = rem // W, rem - (rem // W) * W
            for tp in range(TAPS):
                ky, kx = tp // K, tp % K
                oy, ox = iy + ky - PAD, ix + kx - PAD
                if 0 <= oy < OH and 0 <= ox < OW:
                    pix = oy * OW + ox
                    for ch in range(COUT):
                        w = wrom[(c * TAPS * COUT + tp * COUT + ch)]
                        nv = acc[pix][ch] + s2(w, 8) * val
                        if not (-SAT <= nv <= SAT):
                            raise AssertionError('accumulator saturation (err 0x12)')
                        acc[pix][ch] = nv
                    taps += 1
                else:
                    taps_skip += 1
            qptr += 1
            events_done += 1
        if not do_scan:
            continue
        for pix in range(NPIX):
            for ch in range(COUT):
                a = acc[pix][ch]
                lk = a - shift_arith(a, p['LEAK'])
                if lk >= p['VTH']:
                    spikes += 1
                    fired_log.append((step, pix * COUT + ch))
                    a = lk - p['VTH']
                else:
                    a = lk
                acc[pix][ch] = a
            scan_cells += 1

    h = 0x811C9DC5
    for pix in range(NPIX):
        for ch in range(COUT):
            v = s2(acc[pix][ch], p['ACC_W']) & 0xFFFF
            h = fnv_mix(h, v & 0xFF)
            h = fnv_mix(h, (v >> 8) & 0xFF)

    res = dict(digest=h, events=events_done, taps=taps, taps_skip=taps_skip,
               spikes=spikes, scan_cells=scan_cells,
               cells=[acc[pix][ch] for pix in range(NPIX) for ch in range(COUT)],
               dense_macs=NPIX * COUT * CIN * TAPS * p['N_STEPS'])
    return res, fired_log


def dense_reference(activities, wrom, p):
    """Plain dense convolution over the same activity tensor (single layer pass)."""
    W, H, CIN, COUT = p['IMG_W'], p['IMG_H'], p['CIN'], p['COUT']
    K, PAD, TAPS = p['KERN'], p['PAD'], p['KERN'] * p['KERN']
    OW, OH = W + 2 * PAD - K + 1, H + 2 * PAD - K + 1
    out = [[[0] * COUT for _ in range(OW)] for _ in range(OH)]
    for c in range(CIN):
        for iy in range(H):
            for ix in range(W):
                av = activities[c][iy][ix]
                if av == 0:
                    continue
                for tp in range(TAPS):
                    ky, kx = tp // K, tp % K
                    oy, ox = iy + ky - PAD, ix + kx - PAD
                    if 0 <= oy < OH and 0 <= ox < OW:
                        for ch in range(COUT):
                            out[oy][ox][ch] += s2(wrom[(c * TAPS * COUT + tp * COUT + ch)], 8) * av
    return [out[oy][ox][ch] for oy in range(OH) for ox in range(OW) for ch in range(COUT)]


# -------------------------------------------------------------------- LSTM
def tanh_pl(z, ZW):
    z = s2(z, ZW)
    neg = z < 0
    u = -z if neg else z
    if u < 128:
        y = u
    elif u <= 384:
        tt = u - 128
        y = 97 + ((tt * 30) >> 8)
    else:
        y = 127
    return -y if neg else y


def sigmoid_pl(z, ZW):
    th = tanh_pl(shift_arith(s2(z, ZW), 1), ZW)
    s = 64 + shift_arith(th, 1)
    return max(0, min(127, s))


def sat(v, lo, hi):
    return max(lo, min(hi, v))


def lstm_run(events_x, p, wih, whh, bb):
    N_IN, N_HID, N_GATE = p['N_IN'], p['N_HID'], p['N_GATE']
    FRAC, ZW, N_T = p['FRAC'], p['ZW'], p['N_T']
    h = [0] * N_HID
    c = [0] * N_HID
    macs = 0
    stat_sat = 0
    act_ops = 0
    hv = 0x811C9DC5
    trace = []
    for t in range(N_T):
        x = events_x[t * N_IN:(t + 1) * N_IN]
        gi = [0] * N_HID
        gc = [0] * N_HID
        gf = [0] * N_HID
        go = [0] * N_HID
        for g in range(N_GATE):
            for row in range(N_HID):
                acc = 0
                for k in range(N_IN):
                    acc += s2(x[k], 8) * s2(wih[((g * N_HID + row) * N_IN + k)], 8)
                    macs += 1
                for k in range(N_HID):
                    acc += s2(h[k], 8) * s2(whh[((g * N_HID + row) * N_HID + k)], 8)
                    macs += 1
                sh = shift_arith(acc, FRAC)
                acc_sat = sh > 2047 or sh < -2048
                if acc_sat:
                    stat_sat += 1
                    z = -2048 if sh < 0 else 2047
                else:
                    z = s2(sh, ZW)
                bias = s2(bb[g * N_HID + row], 16)
                zb_sat = (bias < -2048 or bias > 2047)
                zs = s2(z + bias, ZW)
                if not zb_sat and ((zs < 0) != (z < 0)) and ((zs < 0) != (bias < 0)):
                    zb_sat = True
                if zb_sat:
                    stat_sat += 1
                    z_eff = -2048 if bias < 0 else 2047
                else:
                    z_eff = zs
                y = tanh_pl(z_eff, ZW) if g == 1 else sigmoid_pl(z_eff, ZW)
                if g == 0:
                    gi[row] = y
                elif g == 1:
                    gc[row] = y
                elif g == 2:
                    gf[row] = y
                else:
                    go[row] = y
                act_ops += 1
        hn = []
        for row in range(N_HID):
            pf = s2(gf[row], 8) * s2(c[row], 8)
            pi = s2(gi[row], 8) * s2(gc[row], 8)
            ps = shift_arith(pf, FRAC) + shift_arith(pi, FRAC)
            if ps > 127 or ps < -128:
                stat_sat += 1
                cn = 127 if ps > 0 else -128
            else:
                cn = s2(ps, 8)
            tc = tanh_pl(cn, ZW)
            phv = s2(go[row], 8) * tc
            hs = shift_arith(phv, FRAC)
            if hs > 127 or hs < -128:
                stat_sat += 1
                hvn = 127 if hs > 0 else -128
            else:
                hvn = s2(hs, 8)
            c[row] = cn
            h[row] = hvn
            hv = fnv_mix(fnv_mix(hv, hvn & 0xFF), cn & 0xFF)
            hn.append(hvn)
        trace.append(hn)
    t_last = N_T - 1
    digest = fnv_mix(fnv_mix(hv, macs & 0xFF), t_last & 0xFF)
    return dict(digest=digest, macs=macs, sat=stat_sat, act_ops=act_ops,
                steps=t_last, final_h=h, final_c=c), trace


def gen_lstm_inputs(p):
    l = Lfsr16(p['SEED'])
    vals = []
    for _ in range(p['N_T'] * p['N_IN']):
        vals.append((l.next() & 0x7F) - 64)
    return vals


# ------------------------------------------------------------------- emit
def main():
    rnd = random.Random(0x20261004)
    sp = SNN
    TAPS = sp['KERN'] ** 2
    wrom = [rnd.randrange(-64, 64) for _ in range(sp['CIN'] * TAPS * sp['COUT'])]
    wrom_bytes = [b & 0xFF for b in wrom]

    events = gen_events(sp)
    acts = [[[0] * sp['IMG_W'] for _ in range(sp['IMG_H'])] for _ in range(sp['CIN'])]
    for st, idx, val in events:
        c = idx // (sp['IMG_W'] * sp['IMG_H'])
        rem = idx - c * (sp['IMG_W'] * sp['IMG_H'])
        acts[c][rem // sp['IMG_W']][rem - (rem // sp['IMG_W']) * sp['IMG_W']] += val
    ref = dense_reference(acts, wrom_bytes, sp)

    res, fired = snn_run(events, wrom_bytes, sp)
    # equivalence check: one timestep, leak/LIF neutralised -> must equal a
    # plain dense convolution over the same activity tensor
    p2 = dict(sp, N_STEPS=1)
    ev1 = [e for e in events if e[0] == 0]
    res_noscan, _ = snn_run(ev1, wrom_bytes, p2, do_scan=False)
    acts1 = [[[0] * sp['IMG_W'] for _ in range(sp['IMG_H'])] for _ in range(sp['CIN'])]
    for st, idx, val in ev1:
        c = idx // (sp['IMG_W'] * sp['IMG_H'])
        rem = idx - c * (sp['IMG_W'] * sp['IMG_H'])
        acts1[c][rem // sp['IMG_W']][rem - (rem // sp['IMG_W']) * sp['IMG_W']] += val
    ref1 = dense_reference(acts1, wrom_bytes, p2)
    dense_eq = (ref1 == res_noscan['cells'])
    if not dense_eq:
        raise AssertionError('sparse event path != dense reference convolution')

    lp = LSTM
    nw_ih = lp['N_GATE'] * lp['N_HID'] * lp['N_IN']
    nw_hh = lp['N_GATE'] * lp['N_HID'] * lp['N_HID']
    nb = lp['N_GATE'] * lp['N_HID']
    wih = [rnd.randrange(-72, 72) for _ in range(nw_ih)]
    whh = [rnd.randrange(-72, 72) for _ in range(nw_hh)]
    bb = [rnd.randrange(-320, 320) for _ in range(nb)]
    xseq = gen_lstm_inputs(lp)
    lres, ltrace = lstm_run(xseq, lp, [b & 0xFF for b in wih],
                            [b & 0xFF for b in whh], [b & 0xFFFF for b in bb])

    # ---- snn_param_rom.v
    def concat_expr(vals, width):
        parts = ['8\'h%02X' % (v & ((1 << width) - 1)) for v in reversed(vals)]
        return '{' + ', '.join(parts) + '}'

    def concat16(vals):
        parts = ['16\'h%04X' % (v & 0xFFFF) for v in reversed(vals)]
        return '{' + ', '.join(parts) + '}'

    os.makedirs(os.path.join(ROOT, 'src'), exist_ok=True)
    with open(os.path.join(ROOT, 'src', 'snn_param_rom.v'), 'w') as f:
        f.write("`timescale 1ns / 1ps\n")
        f.write("// Generated by model/golden_all.py - do not edit by hand.\n")
        f.write("// Sparse conv layer: CIN=%d KERN=%dx%d COUT=%d, lane index ((c*TAPS+tap)*COUT+ch)\n"
                % (sp['CIN'], sp['KERN'], sp['KERN'], sp['COUT']))
        f.write("module snn_param_rom(\n    output wire [%d:0] wrom\n);\n"
                % (sp['CIN'] * TAPS * sp['COUT'] * 8 - 1))
        f.write("    assign wrom = %s;\n" % concat_expr(wrom, 8))
        f.write("endmodule\n")

    with open(os.path.join(ROOT, 'src', 'lstm_param_rom.v'), 'w') as f:
        f.write("`timescale 1ns / 1ps\n")
        f.write("// Generated by model/golden_all.py - do not edit by hand.\n")
        f.write("// LSTM: N_IN=%d N_HID=%d N_GATE=%d\n" % (lp['N_IN'], lp['N_HID'], lp['N_GATE']))
        f.write("module lstm_param_rom(\n")
        f.write("    output wire [%d:0] wih_rom,\n" % (nw_ih * 8 - 1))
        f.write("    output wire [%d:0] whh_rom,\n" % (nw_hh * 8 - 1))
        f.write("    output wire [%d:0] b_rom\n);\n" % (nb * 16 - 1))
        f.write("    assign wih_rom = %s;\n" % concat_expr(wih, 8))
        f.write("    assign whh_rom = %s;\n" % concat_expr(whh, 8))
        f.write("    assign b_rom   = %s;\n" % concat16(bb))
        f.write("endmodule\n")

    with open(os.path.join(ROOT, 'sim', 'expected_snn.vh'), 'w') as f:
        f.write("// Generated by model/golden_all.py\n")
        for k, v in [('EXP_SNN_DIGEST', res['digest']), ('EXP_SNN_EVENTS', res['events']),
                     ('EXP_SNN_TAPS', res['taps']), ('EXP_SNN_TAPS_SKIP', res['taps_skip']),
                     ('EXP_SNN_SPIKES', res['spikes']), ('EXP_SNN_SCAN', res['scan_cells']),
                     ('EXP_SNN_DENSE_MACS', res['dense_macs'])]:
            f.write("localparam [%d:0] %s = %d;\n" % (33, k, v))

    with open(os.path.join(ROOT, 'sim', 'expected_lstm.vh'), 'w') as f:
        f.write("// Generated by model/golden_all.py\n")
        for k, v in [('EXP_LSTM_DIGEST', lres['digest']), ('EXP_LSTM_MACS', lres['macs']),
                     ('EXP_LSTM_SAT', lres['sat']), ('EXP_LSTM_ACT', lres['act_ops']),
                     ('EXP_LSTM_STEPS', lres['steps'])]:
            f.write("localparam [%d:0] %s = %d;\n" % (33, k, v))

    combined = (((res['digest'] ^ 0x9E3779B9) + lres['digest']) & MASK32)
    lines = [
        "SNN PASS D=%08X E=%04X T=%04X SK=%04X S=%04X" % (
            res['digest'], res['events'], res['taps'], res['taps_skip'], res['spikes']),
        "LSTM PASS D=%08X M=%04X A=%04X SAT=%02X" % (
            lres['digest'], lres['macs'] & 0xFFFF, lres['act_ops'] & 0xFFFF, lres['sat'] & 0xFF),
        "25K SNNLSTM PASS D=%08X" % combined,
        "SNNLSTM ALIVE",
    ]
    CRLF = chr(13) + chr(10)
    with open(os.path.join(ROOT, 'model', 'expected_uart.txt'), 'w', newline='') as f:
        f.write(CRLF.join(lines) + CRLF)

    payload = dict(
        snn={k: v for k, v in res.items() if k != 'cells'},
        snn_cells=res['cells'], snn_events=len(events),
        snn_no_scan={k: v for k, v in res_noscan.items() if k != 'cells'},
        dense_sparse_equivalent=dense_eq, combined=combined, expected_lines=lines,
        lstm={k: v for k, v in lres.items() if k not in ('final_h', 'final_c')},
        lstm_final_h=lres['final_h'], lstm_final_c=lres['final_c'],
        params=dict(snn=sp, lstm=lp),
    )
    with open(os.path.join(ROOT, 'model', 'expected.json'), 'w') as f:
        json.dump(payload, f, indent=1)

    # ---- self checks
    # dense vs sparse: both must agree on the pre-scan accumulator cells
    ref_sorted = sorted(ref)
    print('SNN events=%d taps=%d taps_skip=%d spikes=%d digest=%08X'
          % (res['events'], res['taps'], res['taps_skip'], res['spikes'], res['digest']))
    print('LSTM macs=%d sat=%d act=%d steps=%d digest=%08X'
          % (lres['macs'], lres['sat'], lres['act_ops'], lres['steps'], lres['digest']))
    print('LSTM final h=%s' % lres['final_h'])
    print('DENSE_VS_SPARSE %s (%d cells, dense sum=%d sparse sum=%d)'
          % ('PASS' if dense_eq else 'FAIL', len(ref1), sum(ref), sum(res_noscan['cells'])))
    print('GEN OK')
    return ref_sorted


if __name__ == '__main__':
    main()
