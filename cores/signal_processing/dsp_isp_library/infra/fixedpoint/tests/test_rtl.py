"""Cycle-accurate RTL verification for INFRA-05 fixed-point cores.

Each module gets an independent Python oracle replicating the externally
visible contract cycle by cycle (s_tready, m_tvalid, m_tdata, m_tuser). The
generated fixture drives rst_n/valid/data/last/ready; the testbench checks
every output every cycle. Expected valid/data/flag rows hold constant while
stalled, so held-output stability is verified implicitly and explicitly by a
full-speed region for the pipelined variants. Runs cover extreme/zero/one/
max/min/random vectors, random valid/ready fuzz, long stalls, mid-stream
reset, and checker mutation tests proving corrupted expected streams are
rejected. Illegal static parameters must fail simulation.
Pure stdlib + repository OSS CAD Suite iverilog/vvp.
"""
import os, sys, json, random, shutil, subprocess, hashlib
from pathlib import Path
from datetime import datetime

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
from reference import (rne, sat, sat_round_model, div_model, sqrt_model,
                       log2_model, exp2_model)

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
OUT = BASE / 'evidence' / ('rtl_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir()
TOOL = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
env['PATH'] = str(TOOL / 'bin') + os.pathsep + str(TOOL / 'lib') + os.pathsep + env['PATH']


def tool(name):
    p = TOOL / 'bin' / f'{name}.exe'
    return str(p) if p.exists() else shutil.which(name) or name


RTL = {
    'sat_round': BASE / 'rtl/sat_round.sv',
    'cplx_mac': BASE / 'rtl/cplx_mac.sv',
    'cplx_mac_a34': BASE / 'rtl/cplx_mac.sv',
    'div_iter': BASE / 'rtl/recip_div.sv',
    'div_pipe': BASE / 'rtl/recip_div.sv',
    'sqrt_iter': BASE / 'rtl/sqrt_unit.sv',
    'sqrt_pipe': BASE / 'rtl/sqrt_unit.sv',
    'log2_iter': BASE / 'rtl/log2exp2.sv',
    'log2_iter_s': BASE / 'rtl/log2exp2.sv',
    'exp2_iter': BASE / 'rtl/log2exp2.sv',
}


def clamp(v, w):
    lo, hi = -(1 << (w - 1)), (1 << (w - 1)) - 1
    return (min(hi, max(lo, v)), int(not lo <= v <= hi))


# ------------------------------------------------------------------ oracles
# tick(rst,sv,sd,last,mr) -> (sr,mv,md,mu) expected during that cycle, then
# the oracle applies the rising-edge update. mv/md/mu describe the output
# registers currently driven; they hold while mv && !mr.

class SatRound:
    IW, OW, SH, SG = 32, 16, 15, 1

    def __init__(s):
        s.mv = 0; s.md = s.mu = 0

    def tick(s, rst, sv, sd, last, mr):
        sr = int(rst and (not s.mv or mr))
        out = (sr, s.mv, s.md, s.mu)
        if not rst:
            s.mv = 0
        elif sr:
            s.mv = sv
            if sv:
                y, (cl, ix) = sat_round_model(sd, s.IW, s.SH, s.OW, s.SG)
                s.md = y & ((1 << s.OW) - 1); s.mu = (ix << 1) | cl
        return out


class CplxMac:
    DW, OW, SH = 16, 32, 0

    def __init__(s, aw=48):
        s.AW = aw
        s.v0 = s.l0 = s.v1 = s.l1 = 0; s.r0 = (0, 0, 0, 0); s.pp = (0, 0, 0, 0)
        s.ar = s.ai = 0; s.accv = 0; s.rovf = 0
        s.rv = 0; s.rr = s.ri = s.ro = 0; s.mv = 0; s.md = s.mu = 0

    def _pack(s, vr, vi, ovf):
        orr, c1 = sat(rne(vr, s.SH), s.OW)
        ori, c2 = sat(rne(vi, s.SH), s.OW)
        m = (1 << s.OW) - 1
        return ((ori & m) << s.OW) | (orr & m), (ovf << 1) | (c1 | c2)

    def tick(s, rst, sv, sd, last, mr):
        adv = not (s.rv and s.mv and not mr)
        sr = int(rst and adv)
        out = (sr, s.mv, s.md, s.mu)
        if not rst:
            s.v0 = s.l0 = s.v1 = s.l1 = s.accv = s.rovf = s.rv = s.mv = 0
            return out
        mf = not s.mv or mr              # m_free on pre-edge registers
        old_rv = s.rv
        old_v1, old_l1, old_pp = s.v1, s.l1, s.pp
        if mr:
            s.mv = 0
        if old_rv and mf:
            s.md, s.mu = s._pack(s.rr, s.ri, s.ro); s.mv = 1; s.rv = 0
        if adv:
            if s.v0:  # stage1 products consume stage0 operand registers
                a_re, a_im, b_re, b_im = s.r0
                s.pp = (a_re * b_re, a_im * b_im,
                        a_re * b_im, a_im * b_re)
            s.v1, s.l1 = s.v0, s.l0
            s.v0, s.l0 = sv, last
            if sv:
                m = (1 << s.DW) - 1
                sg = lambda v: v - (1 << s.DW) if v >= (1 << (s.DW - 1)) else v
                s.r0 = (sg(sd & m), sg((sd >> s.DW) & m),
                        sg((sd >> 2 * s.DW) & m), sg((sd >> 3 * s.DW) & m))
            if old_v1:
                p1, p2, p3, p4 = old_pp
                tr, ti = p1 - p2, p3 + p4
                br = s.ar if s.accv else 0
                bi = s.ai if s.accv else 0
                nr, o1 = clamp(br + tr, s.AW)
                ni, o2 = clamp(bi + ti, s.AW)
                if old_l1:
                    s.accv = 0
                    flags = s.rovf | o1 | o2
                    s.rovf = 0
                    if old_rv or not mf:
                        s.rv = 1; s.rr, s.ri, s.ro = nr, ni, flags
                    else:
                        s.md, s.mu = s._pack(nr, ni, flags); s.mv = 1
                else:
                    s.ar, s.ai, s.accv = nr, ni, 1
                    s.rovf |= o1 | o2
        return out


class DivIter:
    AWW, BWW, FB, OW = 16, 16, 15, 18
    N = AWW + FB

    def __init__(s):
        s.st = 0; s.cnt = 0; s.av = s.bv = 0; s.mv = 0; s.md = s.mu = 0

    def _emit(s):
        q, (d0, cl) = div_model(s.av, s.bv, s.AWW, s.BWW, s.FB, s.OW)
        return q & ((1 << s.OW) - 1), (d0 << 1) | cl

    def tick(s, rst, sv, sd, last, mr):
        sr = int(rst and s.st == 0)
        out = (sr, s.mv, s.md, s.mu)
        if not rst:
            s.st = 0; s.cnt = 0; s.mv = 0; return out
        if mr:
            s.mv = 0
        mf = not s.mv or mr
        if s.st == 0:
            if sv:
                s.av = sd & ((1 << s.AWW) - 1)
                s.bv = (sd >> s.AWW) & ((1 << s.BWW) - 1)
                s.st = 1; s.cnt = 0
        elif s.st == 1:
            it = 1 if s.bv == 0 else s.N
            s.cnt += 1
            if s.cnt >= it:
                if mf:
                    s.md, s.mu = s._emit(); s.mv = 1; s.st = 0
                else:
                    s.st = 2
        else:
            if mf:
                s.md, s.mu = s._emit(); s.mv = 1; s.st = 0
        return out


class PipeBase:
    N = 1

    def __init__(s):
        s.items = []; s.mv = 0; s.md = s.mu = 0

    def calc(self, sd):
        raise NotImplementedError

    def tick(s, rst, sv, sd, last, mr):
        adv = not s.mv or mr
        sr = int(rst and adv)
        out = (sr, s.mv, s.md, s.mu)
        if not rst:
            s.items = []; s.mv = 0; return out
        if adv:
            hit = [i for i in s.items if i['pos'] == s.N - 1]
            s.items = [i for i in s.items if i['pos'] < s.N - 1]
            s.mv = int(bool(hit))
            if hit:
                s.md, s.mu = s.calc(hit[0]['sd'])
            for i in s.items:
                i['pos'] += 1
            if sv:
                s.items.append({'sd': sd, 'pos': 0})
        return out


class DivPipe(PipeBase):
    AWW, BWW, FB, OW = 16, 16, 15, 18
    N = AWW + FB

    def calc(s, sd):
        q, (d0, cl) = div_model(sd & 0xFFFF, (sd >> 16) & 0xFFFF,
                                s.AWW, s.BWW, s.FB, s.OW)
        return q & ((1 << s.OW) - 1), (d0 << 1) | cl


class SqrtIter:
    IW, FB = 32, 8
    N = (IW + 2 * FB + 1) // 2

    def __init__(s):
        s.st = 0; s.cnt = 0; s.x = 0; s.mv = 0; s.md = s.mu = 0

    def _emit(s):
        r, (z, ex) = sqrt_model(s.x, s.IW, s.FB)
        return r, (ex << 1) | z

    def tick(s, rst, sv, sd, last, mr):
        sr = int(rst and s.st == 0)
        out = (sr, s.mv, s.md, s.mu)
        if not rst:
            s.st = 0; s.cnt = 0; s.mv = 0; return out
        if mr:
            s.mv = 0
        mf = not s.mv or mr
        if s.st == 0:
            if sv:
                s.x = sd; s.st = 1; s.cnt = 0
        elif s.st == 1:
            s.cnt += 1
            if s.cnt >= s.N:
                if mf:
                    s.md, s.mu = s._emit(); s.mv = 1; s.st = 0
                else:
                    s.st = 2
        else:
            if mf:
                s.md, s.mu = s._emit(); s.mv = 1; s.st = 0
        return out


class SqrtPipe(PipeBase):
    IW, FB = 32, 8
    N = (IW + 2 * FB + 1) // 2

    def calc(s, sd):
        r, (z, ex) = sqrt_model(sd, s.IW, s.FB)
        return r, (ex << 1) | z


class Log2Iter:
    IW, FB, G = 16, 12, 6
    N = FB + G + 3  # RUN edges: steps j=1..FB+G+2 then the finalize edge
    OW = FB + 4 + 1  # FB + clog2(16) + 1

    def __init__(s, signed_in=0):
        s.SG = signed_in
        s.st = 0; s.cnt = 0; s.x = 0; s.abn = 0; s.mv = 0; s.md = s.mu = 0

    def _emit(s):
        y, ab = log2_model(s.x, s.IW, s.FB, s.G, s.SG)
        return y & ((1 << s.OW) - 1), ab

    def tick(s, rst, sv, sd, last, mr):
        sr = int(rst and s.st == 0)
        out = (sr, s.mv, s.md, s.mu)
        if not rst:
            s.st = 0; s.cnt = 0; s.mv = 0; return out
        if mr:
            s.mv = 0
        mf = not s.mv or mr
        if s.st == 0:
            if sv:
                s.x = sd
                s.abn = int(sd == 0) if not s.SG else \
                    int((sd - (1 << s.IW) if sd >= (1 << (s.IW - 1)) else sd) <= 0)
                s.st = 1; s.cnt = 0
        elif s.st == 1:
            it = 1 if s.abn else s.N
            s.cnt += 1
            if s.cnt >= it:
                if mf:
                    s.md, s.mu = s._emit(); s.mv = 1; s.st = 0
                else:
                    s.st = 2
        else:
            if mf:
                s.md, s.mu = s._emit(); s.mv = 1; s.st = 0
        return out


class Exp2Iter:
    IW, FB, G, OW, FO = 16, 12, 6, 13, 6
    N = FB + G + 3

    def __init__(s):
        s.st = 0; s.cnt = 0; s.x = 0; s.mv = 0; s.md = s.mu = 0

    def _emit(s):
        q, (cl, un) = exp2_model(s.x, s.IW, s.FB, s.G, s.OW, s.FO)
        return q, (un << 1) | cl

    def tick(s, rst, sv, sd, last, mr):
        sr = int(rst and s.st == 0)
        out = (sr, s.mv, s.md, s.mu)
        if not rst:
            s.st = 0; s.cnt = 0; s.mv = 0; return out
        if mr:
            s.mv = 0
        mf = not s.mv or mr
        if s.st == 0:
            if sv:
                s.x = sd; s.st = 1; s.cnt = 0
        elif s.st == 1:
            s.cnt += 1
            if s.cnt >= s.N:
                if mf:
                    s.md, s.mu = s._emit(); s.mv = 1; s.st = 0
                else:
                    s.st = 2
        else:
            if mf:
                s.md, s.mu = s._emit(); s.mv = 1; s.st = 0
        return out


# -------------------------------------------------------------- generators --
rng = random.Random(0xF1E9)


def rand_ready(p=0.7):
    return int(rng.random() < p)


def drive_iter(oracle, values, cycles_extra):
    """Feed values one at a time with random gaps, stalls and a mid reset."""
    rows = []

    def tick(rst, sv, sd, mr):
        e = oracle.tick(rst, sv, sd, 0, mr)
        rows.append((rst, sv, sd, 0, mr) + e)
        return e[0]

    tick(0, 0, 0, 0); tick(0, 0, 0, 0)
    accepted = 0
    i = 0
    held = None
    steps = 0
    while i < len(values) and steps < cycles_extra:
        steps += 1
        rst = int(steps not in (cycles_extra // 3, cycles_extra // 3 + 1))
        if not rst:
            held = None
        mr = 1 if steps % 5 else rand_ready(0.55)  # periodic guaranteed drain
        if steps % 37 < 4:
            mr = 0  # long stall region
        if held is None and rst and rng.random() < 0.75:
            held = values[i]; i += 1
        sr = tick(rst, int(held is not None), held or 0, mr)
        if sr and held is not None:
            held = None; accepted += 1
    for _ in range(120):
        tick(1, 0, 0, 1)
    return rows


def drive_pipe(oracle, values):
    rows = []

    def tick(rst, sv, sd, last, mr):
        e = oracle.tick(rst, sv, sd, last, mr)
        rows.append((rst, sv, sd, last, mr) + e)
        return e[0]

    tick(0, 0, 0, 0, 0); tick(0, 0, 0, 0, 0)
    i = 0; held = None
    n = len(values)
    for c in range(n + 80):
        rst = int(c not in (n // 2, n // 2 + 1))
        if not rst:
            held = None
        mr = rand_ready(0.75) if c % 9 else 1
        if c % 41 < 4:
            mr = 0
        if held is None and i < n and rst:
            held = values[i]; i += 1
        last = 0
        sr = tick(rst, int(held is not None), held or 0, last, mr)
        if sr and held is not None:
            held = None
    for _ in range(60):
        tick(1, 0, 0, 0, 1)
    return rows


def drive_fullspeed(oracle, values):
    """No gaps, no stalls: proves II=1."""
    rows = []

    def tick(rst, sv, sd, last, mr):
        e = oracle.tick(rst, sv, sd, last, mr)
        rows.append((rst, sv, sd, last, mr) + e)
        return e[0]

    tick(0, 0, 0, 0, 0); tick(0, 0, 0, 0, 0)
    for v in values:
        tick(1, 1, v, 0, 1)
    for _ in range(70):
        tick(1, 0, 0, 0, 1)
    return rows


def drive_cplx(aw=48):
    o = CplxMac(aw)
    rows = []

    def tick(rst, sv, sd, last, mr):
        e = o.tick(rst, sv, sd, last, mr)
        rows.append((rst, sv, sd, last, mr) + e)
        return e[0]

    tick(0, 0, 0, 0, 0); tick(0, 0, 0, 0, 0)
    m = (1 << 16) - 1

    def beat(a_re, a_im, b_re, b_im):
        return ((a_im & m) << 48) | ((a_re & m) << 32) | \
               ((b_im & m) << 16) | (b_re & m)

    runs = []
    # directed: single beat, extremes, mixed signs, forced saturation run
    runs.append([beat(1000, -500, 300, 700)])
    runs.append([beat(32767, 32767, 32767, 32767),
                 beat(-32768, -32768, -32768, -32768)])
    # acc saturation: needs only ~5 beats at ACC_W=34, ~65k at ACC_W=48
    sat_n = 40 if aw <= 34 else 0
    if sat_n:
        runs.append([beat(32767, 32767, 32767, 32767)] * sat_n)
    for _ in range(8):
        runs.append([beat(rng.randrange(-32768, 32768),
                          rng.randrange(-32768, 32768),
                          rng.randrange(-32768, 32768),
                          rng.randrange(-32768, 32768))
                     for _ in range(rng.randrange(1, 40))])
    step = 0
    for run in runs:
        for k, b in enumerate(run):
            last = int(k == len(run) - 1)
            while True:
                step += 1
                rst = 1
                mr = rand_ready(0.8) if step % 7 else 1
                if step % 23 < 3:
                    mr = 0
                sr = tick(rst, 1, b, last, mr)
                if sr:
                    break
            # occasional idle gaps between runs
        for _ in range(rng.randrange(0, 4)):
            tick(1, 0, 0, 0, rand_ready(0.8))
        if rng.random() < 0.3:
            tick(0, 0, 0, 0, 0)  # mid-stream reset between runs
            tick(0, 0, 0, 0, 0)
    for _ in range(40):
        tick(1, 0, 0, 0, 1)
    return rows


def fmt_rows(rows):
    return '\n'.join(f'{r} {sv} {sd:x} {lt} {mr} {sr} {mv} {md:x} {mu}'
                     for r, sv, sd, lt, mr, sr, mv, md, mu in rows) + '\n'


# ------------------------------------------------------------- test vectors
VEC = {}

o = SatRound()
VEC['sat_round'] = drive_iter(
    o, [0, 1, 0x7FFFFFFF, 0x80000000, 0x00008000, 0x00007FFF, 0xFFFF8000,
        0x00004000, 0x12345678, 0x87654321] +
       [rng.getrandbits(32) for _ in range(50)], 4000)

VEC['cplx_mac'] = drive_cplx()
VEC['cplx_mac_a34'] = drive_cplx(34)

divvals = [(b << 16) | (a & 0xFFFF) for a, b in
           [(0, 0), (5, 0), (-5 & 0xFFFF, 0), (1, 1), (100, 7), (-300 & 0xFFFF, 9),
            (32767, 1), (0x8000, 1), (0x8000, 0xFFFF), (1, 32767), (3, 32), (5, 32)]]
divvals += [(rng.randrange(-32768, 32768) & 0xFFFF) |
            ((rng.randrange(-32768, 32768) & 0xFFFF) << 16) for _ in range(40)]
o = DivIter()
VEC['div_iter'] = drive_iter(o, divvals, 4000)
o = DivPipe()
VEC['div_pipe'] = drive_pipe(o, divvals)
o = DivPipe()
VEC['div_pipe_fs'] = drive_fullspeed(o, divvals[:24])

sqrtvals = [0, 1, 2, 3, 4, 0xFFFF, 0x10000, 0xFFFFFFFF, 0x40000000,
            999999937, 65535 * 65535, 65535 * 65535 - 1, 65535 * 65535 + 1]
sqrtvals += [rng.getrandbits(32) for _ in range(40)]
o = SqrtIter()
VEC['sqrt_iter'] = drive_iter(o, sqrtvals, 4000)
o = SqrtPipe()
VEC['sqrt_pipe'] = drive_pipe(o, sqrtvals)
o = SqrtPipe()
VEC['sqrt_pipe_fs'] = drive_fullspeed(o, sqrtvals[:24])

logvals = [0, 1, 2, 3, 4, 255, 256, 257, 1024, 32767, 32768, 65535,
           0x8000, 0x4000, 0x0001]
logvals += [rng.randrange(1, 65536) for _ in range(40)]
o = Log2Iter()
VEC['log2_iter'] = drive_iter(o, logvals, 4000)
# signed-input variant: nonpositive values must flag abnormal
logsvals = [0, 1, 32767, 2, 1024, -1 & 0xFFFF, -32768 & 0xFFFF, 0x8000]
logsvals += [rng.randrange(-32768, 32768) & 0xFFFF for _ in range(40)]
o = Log2Iter(signed_in=1)
VEC['log2_iter_s'] = drive_iter(o, logsvals, 4000)

expvals = [0, 1, -1 & 0xFFFF, 4096, -4096 & 0xFFFF, 28672, 28673, -28672 & 0xFFFF,
           -28673 & 0xFFFF, 32767, 0x8000, 2048, -2048 & 0xFFFF]
expvals += [rng.randrange(-32768, 32768) & 0xFFFF for _ in range(40)]
o = Exp2Iter()
VEC['exp2_iter'] = drive_iter(o, expvals, 4000)

# ---------------------------------------------------------------- testbench
TB = '''`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,sv=0,last=0,mr=0;reg[SDW-1:0]sd=0;
wire sr,mv;wire[MDW-1:0]md;wire[1:0]mu;
DUT dut(.clk(clk),.rst_n(rst_n),.s_tdata(sd),.s_tvalid(sv),.s_tready(sr),LASTPORT
 .m_tdata(md),.m_tuser(mu),.m_tvalid(mv),.m_tready(mr));
integer f,n,row,rr,vv,ll,mm,esr,emv,eu;reg[SDW-1:0]dd;reg[MDW-1:0]ed;
initial begin
 f=$fopen("vectors.txt","r");row=0;@(posedge clk);#1;
 while(!$feof(f))begin
  @(negedge clk);
  n=$fscanf(f,"%d %d %h %d %d %d %d %h %d\\n",rr,vv,dd,ll,mm,esr,emv,ed,eu);
  if(n!=9)$fatal(1,"fixture row=%0d n=%0d",row,n);
  rst_n=rr;sv=vv;sd=dd;last=ll;mr=mm;#1;
  if({sr,mv}!=={esr[0],emv[0]})$fatal(1,"ctrl row=%0d got=%b%b exp=%b%b",row,sr,mv,esr[0],emv[0]);
  if(emv && {md,mu}!=={ed,eu[1:0]})$fatal(1,"data row=%0d got=%h/%b exp=%h/%b",row,md,mu,ed,eu);
  @(posedge clk);#1;row=row+1;
 end
 $display("PASS rows=%0d",row);$finish;
end
endmodule
'''

MODULES = {
    'sat_round': dict(dut='sat_round', inst='sat_round #(.IN_W(32),.OUT_W(16),.SHIFT(15),.SIGNED_IN(1))',
                      sdw=32, mdw=16, last=False),
    'cplx_mac': dict(dut='cplx_mac', inst='cplx_mac #(.DATA_W(16),.ACC_W(48),.OUT_W(32),.SHIFT(0))',
                     sdw=64, mdw=64, last=True),
    'cplx_mac_a34': dict(dut='cplx_mac', inst='cplx_mac #(.DATA_W(16),.ACC_W(34),.OUT_W(32),.SHIFT(0))',
                         sdw=64, mdw=64, last=True),
    'div_iter': dict(dut='fp_div_iter', inst='fp_div_iter #(.AW(16),.BW(16),.FB(15),.OUT_W(18))',
                     sdw=32, mdw=18, last=False),
    'div_pipe': dict(dut='fp_div_pipe', inst='fp_div_pipe #(.AW(16),.BW(16),.FB(15),.OUT_W(18))',
                     sdw=32, mdw=18, last=False),
    'sqrt_iter': dict(dut='fp_sqrt_iter', inst='fp_sqrt_iter #(.IN_W(32),.FB(8))',
                      sdw=32, mdw=25, last=False),
    'sqrt_pipe': dict(dut='fp_sqrt_pipe', inst='fp_sqrt_pipe #(.IN_W(32),.FB(8))',
                      sdw=32, mdw=25, last=False),
    'log2_iter': dict(dut='fp_log2_iter', inst='fp_log2_iter #(.IN_W(16),.FB(12),.G(6),.SIGNED_IN(0))',
                      sdw=16, mdw=17, last=False),
    'log2_iter_s': dict(dut='fp_log2_iter', inst='fp_log2_iter #(.IN_W(16),.FB(12),.G(6),.SIGNED_IN(1))',
                        sdw=16, mdw=17, last=False),
    'exp2_iter': dict(dut='fp_exp2_iter', inst='fp_exp2_iter #(.IW(16),.FB(12),.G(6),.OUT_W(13),.FRACO(6))',
                      sdw=16, mdw=13, last=False),
}


def run(cmd, name, cwd, reject=False):
    p = subprocess.run(cmd, cwd=cwd, env=env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (cwd / name).write_text('$ ' + ' '.join(map(str, cmd)) + '\n' + p.stdout)
    if (not reject and p.returncode) or (reject and not p.returncode):
        raise RuntimeError(f'{name}: {p.stdout[-2000:]}')
    return p.stdout


FIXTURES = {n: [n] for n in MODULES}
FIXTURES['div_pipe'] = ['div_pipe', 'div_pipe_fs']
FIXTURES['sqrt_pipe'] = ['sqrt_pipe', 'sqrt_pipe_fs']

results = {}
for name, spec in MODULES.items():
    vecs = [VEC[k] for k in FIXTURES[name]]
    vec = [r for v in vecs for r in v]
    work = OUT / name
    work.mkdir()
    (work / 'vectors.txt').write_text(fmt_rows(vec))
    tb = TB.replace('DUT', spec['inst']).replace('SDW', str(spec['sdw'])) \
           .replace('MDW', str(spec['mdw']))
    tb = tb.replace('LASTPORT', '.s_tlast(last),' if spec['last'] else '')
    (work / 'tb.sv').write_text(tb)
    run([tool('iverilog'), '-g2012', '-Wall', '-s', 'tb', '-o', 'test.vvp',
         str(RTL[name]), 'tb.sv'], 'compile.log', work)
    log = run([tool('vvp'), 'test.vvp'], 'run.log', work)
    assert 'PASS' in log
    # mutation tests: corrupt expected data, flags, control, ordering, count
    muts = []
    valid_idx = [i for i, r in enumerate(vec) if r[6] == 1]
    for field, label in [(7, 'data'), (8, 'user'), (6, 'valid'), (5, 'ready')]:
        idx = valid_idx[len(valid_idx) // 2]
        alt = list(vec)
        row = list(alt[idx])
        row[field] = row[field] + 1 if field != 6 else 0
        alt[idx] = tuple(row)
        (work / 'vectors.txt').write_text(fmt_rows(alt))
        run([tool('vvp'), 'test.vvp'], f'neg_{label}.log', work, reject=True)
        muts.append(label)
    # order corruption: swap two distinct valid outputs
    if len(valid_idx) >= 2:
        a, b = valid_idx[len(valid_idx) // 3], valid_idx[2 * len(valid_idx) // 3]
        alt = list(vec)
        ra, rb = list(alt[a]), list(alt[b])
        if ra[7] != rb[7]:
            ra[7], rb[7] = rb[7], ra[7]
            alt[a], alt[b] = tuple(ra), tuple(rb)
            (work / 'vectors.txt').write_text(fmt_rows(alt))
            run([tool('vvp'), 'test.vvp'], 'neg_order.log', work, reject=True)
            muts.append('order')
    # count corruption: drop one expected beat by deleting a valid row's flag
    idx = valid_idx[len(valid_idx) // 2]
    alt = list(vec)
    row = list(alt[idx]); row[6] = 0; row[7] = 0
    alt[idx] = tuple(row)
    (work / 'vectors.txt').write_text(fmt_rows(alt))
    run([tool('vvp'), 'test.vvp'], 'neg_count.log', work, reject=True)
    muts.append('count')
    (work / 'vectors.txt').write_text(fmt_rows(vec))
    results[name] = {'rows': len(vec), 'outputs': len(valid_idx),
                     'mutations': muts}

# illegal static parameter checks must fail simulation
ILLEGAL = [
    ('sat_round', 'sat_round #(.IN_W(4),.OUT_W(8),.SHIFT(1))', 'outw_gt_inw'),
    ('sat_round', 'sat_round #(.IN_W(16),.OUT_W(16),.SHIFT(20))', 'shift_gt_inw'),
    ('cplx_mac', 'cplx_mac #(.DATA_W(16),.ACC_W(20),.OUT_W(32))', 'acc_too_small'),
    ('div_iter', 'fp_div_iter #(.AW(16),.BW(16),.FB(30),.OUT_W(18))', 'div_fb_too_big'),
    ('div_pipe', 'fp_div_pipe #(.AW(1),.BW(16),.FB(15),.OUT_W(18))', 'aw_too_small'),
    ('sqrt_iter', 'fp_sqrt_iter #(.IN_W(32),.FB(40))', 'sqrt_fb_too_big'),
    ('sqrt_pipe', 'fp_sqrt_pipe #(.IN_W(1),.FB(0))', 'inw_too_small'),
    ('log2_iter', 'fp_log2_iter #(.IN_W(16),.FB(12),.G(1))', 'p_lt_inw'),
    ('exp2_iter', 'fp_exp2_iter #(.IW(16),.FB(12),.G(6),.OUT_W(13),.FRACO(1))', 'range_bad'),
]
for modkey, inst, label in ILLEGAL:
    work = OUT / ('illegal_' + label)
    work.mkdir()
    (work / 'illegal.sv').write_text(
        f'module tb_illegal; {inst} dut(); endmodule\n')
    # rejection may happen at elaboration (illegal generate/replication) or at
    # time 0 via the $fatal static check; either is a valid rejection
    p = subprocess.run([tool('iverilog'), '-g2012', '-s', 'tb_illegal',
                        '-o', 'illegal.vvp', str(RTL[modkey]), 'illegal.sv'],
                       cwd=work, env=env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (work / 'compile.log').write_text(p.stdout)
    if p.returncode:
        results[f'illegal_{label}'] = 'rejected_elaboration'
    else:
        run([tool('vvp'), 'illegal.vvp'], 'run.log', work, reject=True)
        results[f'illegal_{label}'] = 'rejected_simulation'

summary = {
    'status': 'PASS',
    'modules': results,
    'rtl_sha256': {k: hashlib.sha256(v.read_bytes()).hexdigest()
                   for k, v in RTL.items()},
    'scope': 'isolated module verification vs bit-exact model; no P&R/board'
}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print(json.dumps(results, indent=2)[:3000])
