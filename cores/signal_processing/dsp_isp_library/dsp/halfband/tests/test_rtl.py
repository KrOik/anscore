"""Cycle-level fixture regression for the DSP-10 half-band/CIC-comp cores.

A Python oracle reproduces stream/config/flush timing bit-exactly for each
module; generated testbenches replay every cycle and compare control and
payload fields. Corrupted fixtures and illegal static parameters must be
rejected. Rate contracts are exercised both directions (random input gaps,
random output backpressure, mid-stream reset, drain stalls).
"""
import os, sys, json, random, subprocess, hashlib
from pathlib import Path
from datetime import datetime
BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
sys.path.insert(0, str(BASE / 'models'))
import reference as ref

OUT = BASE / 'evidence' / ('rtl_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir(parents=True)
TOOL = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
# oss-cad-suite: lib first avoids DLL shadowing; external PATH dirs carry
# incompatible mingw DLLs, so only System32 is appended.
env['PATH'] = str(TOOL / 'lib') + os.pathsep + str(TOOL / 'bin') + os.pathsep + \
    os.environ.get('SystemRoot', 'C:\\Windows') + r'\System32'
MAXP, LANES, MAX_IN = 9, 4, 255
CU = (ref.COMP_MAX_TAPS + 1) // 2


def pack(uc, slots):
    v = list(uc) + [0] * (slots - len(uc))
    return sum((c & 0x3ffff) << (18 * i) for i, c in enumerate(v))


def npairs(t):
    return (t - 1) // 4 if t % 4 == 1 else (t + 1) // 4


class Oracle:
    """Shared timing skeleton; subclass supplies result computation."""
    WIDTHS = 9

    def __init__(self, taps, uc):
        self.hq = []
        self.def_taps = taps
        self.def_uc = list(uc)
        self.configure_now(taps, uc)
        self.rows = []
        self.clock = 0

    def configure_now(self, taps, uc):
        raise NotImplementedError

    def legal(self, taps):
        raise NotImplementedError

    def clear(self):
        self.draining = self.done = 0
        self.rnd = 0
        self.used = 0
        self.started = 0
        self.end = 0
        self.fidx = 0
        self.inc = self.outc = self.cap = 0
        self.mv = self.md = self.mu = 0
        self.cd = self.ce = self.fd = 0
        self.xs = []          # every fed sample incl. virtual zeros
        self.pending = None
        self.outputs = []

    def tick(self, rst=1, cfg=None, fv=0, sv=0, x=0, mr=1):
        raise NotImplementedError

    def row(self, rst, cv, ct, packv, fv, sv, x, mr, sr, cr, fr):
        self.rows.append(
            f'{rst} {cv} {ct} {packv:x} {fv} {sv} {x & 0xffff:x} {mr} '
            f'{sr} {cr} {fr} {self.mv} {self.md & 0xffff:x} {self.mu} '
            f'{self.cd} {self.ce} {self.fd} {self.inc} {self.outc} {self.cap}')
        self.clock += 1


class DecimOracle(Oracle):
    def configure_now(self, taps, uc):
        self.taps = taps
        self.pairs = npairs(taps)
        self.uc = list(uc)
        self.h = ref.expand_halfband(taps, uc)
        self.clear()

    def legal(self, taps):
        return isinstance(taps, int) and taps % 2 == 1 and \
            3 <= taps <= 4 * MAXP + 1 and npairs(taps) <= MAXP

    def rounds(self):
        return (self.pairs + LANES - 1) // LANES

    def tick(self, rst=1, cfg=None, fv=0, sv=0, x=0, mr=1):
        cv = int(cfg is not None)
        ct, cc = cfg or (0, ())
        run = not self.done
        sr = int(rst and run and not self.draining and not cv and not fv and
                 self.inc < MAX_IN and (self.fidx & 1 or self.rnd == 0))
        cr = int(rst and (self.done or
                 (run and not self.draining and self.rnd == 0 and not self.mv)))
        fr = int(rst and run and not self.draining and self.rnd == 0 and
                 not self.mv and not cv)
        real_take = sv and sr
        vfeed = int(self.draining and run and self.started < self.end and
                    (self.fidx & 1 or self.rnd == 0))
        feed = real_take or vfeed
        trigger = feed and not (self.fidx & 1)
        adv = (not self.mv) or mr
        # drain-completion uses only pre-edge state (nonblocking semantics)
        fin = self.draining and run and self.started == self.end and \
            self.rnd == 0 and not self.mv
        self.row(rst, cv, ct, pack(cc, MAXP) if cv else 0, fv, sv, x, mr,
                 sr, cr, fr)
        self.cd = self.ce = self.fd = 0
        if not rst:
            self.configure_now(self.def_taps, list(self.def_uc))
            return sr, cr, fr
        if self.mv and mr:
            self.outputs.append((self.md, self.mu))
            self.outc += 1
        if mr:
            self.mv = 0
        if run and not self.draining and not cv and not fv and sv and \
                self.inc == MAX_IN:
            self.cap = 1
        if cv and cr:
            if not self.legal(ct) or len(cc) != MAXP or \
                    any(not -131072 <= c <= 131071 for c in cc):
                self.ce = 1
            else:
                self.configure_now(ct, list(cc)[:npairs(ct)])
            self.cd = 1
        elif fv and fr:
            if self.inc == 0:
                self.done = 1
                self.fd = 1
            else:
                self.draining = 1
                self.end = (self.inc + self.taps - 2) // 2 + 1
        else:
            if self.rnd:
                if self.rnd == 1:
                    if adv:
                        self.md, self.mu = self.pending
                        self.mv = 1
                        self.rnd = 0
                else:
                    self.rnd -= 1
            if run:
                if fin:
                    self.draining = 0
                    self.done = 1
                    self.fd = 1
                elif feed:
                    feedv = 0 if self.draining else (x - 65536
                                                     if x >= 32768 else x)
                    self.xs.append(feedv)
                    if self.used < 4 * MAXP + 1:
                        self.used += 1
                    if real_take:
                        self.inc += 1
                    if trigger:
                        m = self.fidx // 2
                        acc = sum(self.h[k] * self.xs[2 * m - k]
                                  for k in range(self.taps)
                                  if 0 <= 2 * m - k < len(self.xs))
                        wide = ref.rne(acc)
                        self.pending = (ref.sat16(wide),
                                        int(not -32768 <= wide <= 32767))
                        self.rnd = self.rounds()
                        self.started += 1
                    self.fidx += 1
        return sr, cr, fr


class InterpOracle(Oracle):
    OACC, OE1, OE2 = 0, 1, 2

    def configure_now(self, taps, uc):
        self.taps = taps
        self.pairs = npairs(taps)
        self.uc = list(uc)
        self.h = ref.expand_halfband(taps, uc)
        self.clear()
        self.ostate = self.OACC
        self.vfeeds = self.vend = 0
        self.last_feed = 0
        self.dval = self.fval = self.fclip = 0

    def clear(self):
        super().clear()
        if hasattr(self, 'ostate'):
            self.ostate = self.OACC
            self.vfeeds = self.vend = 0
            self.last_feed = 0
            self.dval = self.fval = self.fclip = 0

    def legal(self, taps):
        return isinstance(taps, int) and taps % 2 == 1 and \
            3 <= taps <= 4 * MAXP + 1 and npairs(taps) <= MAXP

    def rounds(self):
        return (self.pairs + LANES - 1) // LANES

    @property
    def first_direct(self):
        return self.taps % 4 == 1

    def tick(self, rst=1, cfg=None, fv=0, sv=0, x=0, mr=1):
        cv = int(cfg is not None)
        ct, cc = cfg or (0, ())
        run = not self.done
        idle = self.ostate == self.OACC and self.rnd == 0
        sr = int(rst and run and not self.draining and not cv and not fv and
                 self.inc < MAX_IN and idle)
        cr = int(rst and (self.done or
                 (run and not self.draining and idle and not self.mv)))
        fr = int(rst and run and not self.draining and idle and
                 not self.mv and not cv)
        real_take = sv and sr
        vfeed = int(self.draining and run and self.vfeeds < self.vend and idle)
        feed = real_take or vfeed
        adv = (not self.mv) or mr
        rnd0 = self.rnd          # emit gates see the pre-edge MAC counter
        fin = self.draining and run and self.vfeeds == self.vend and \
            self.ostate == self.OACC and self.rnd == 0 and not self.mv
        self.row(rst, cv, ct, pack(cc, MAXP) if cv else 0, fv, sv, x, mr,
                 sr, cr, fr)
        self.cd = self.ce = self.fd = 0
        if not rst:
            self.configure_now(self.def_taps, list(self.def_uc))
            return sr, cr, fr
        if self.mv and mr:
            self.outputs.append((self.md, self.mu))
            self.outc += 1
        if mr:
            self.mv = 0
        if run and not self.draining and not cv and not fv and sv and \
                self.inc == MAX_IN:
            self.cap = 1
        if cv and cr:
            if not self.legal(ct) or len(cc) != MAXP or \
                    any(not -131072 <= c <= 131071 for c in cc):
                self.ce = 1
            else:
                self.configure_now(ct, list(cc)[:npairs(ct)])
            self.cd = 1
        elif fv and fr:
            if self.inc == 0:
                self.done = 1
                self.fd = 1
            else:
                self.draining = 1
                self.vfeeds = 0
                self.vend = (self.taps - 1) // 2
        else:
            if self.rnd:
                if self.rnd == 1:
                    self.fval, self.fclip = self.pending
                    self.rnd = 0
                else:
                    self.rnd -= 1
            if run:
                if fin:
                    self.draining = 0
                    self.done = 1
                    self.fd = 1
                else:
                    if self.ostate == self.OE1:
                        if adv and (self.first_direct or rnd0 == 0):
                            self.md = self.dval if self.first_direct \
                                else self.fval
                            self.mu = 0 if self.first_direct else self.fclip
                            self.mv = 1
                            self.ostate = self.OACC if self.last_feed \
                                else self.OE2
                    elif self.ostate == self.OE2:
                        if adv and (rnd0 == 0 if self.first_direct
                                    else True):
                            self.md = self.fval if self.first_direct \
                                else self.dval
                            self.mu = self.fclip if self.first_direct else 0
                            self.mv = 1
                            self.ostate = self.OACC
                    if feed:
                        feedv = 0 if self.draining else (x - 65536
                                                         if x >= 32768 else x)
                        n = len(self.xs)
                        self.xs.append(feedv)
                        if self.used < 2 * MAXP + 1:
                            self.used += 1
                        if real_take:
                            self.inc += 1
                        if vfeed:
                            self.vfeeds += 1
                        self.last_feed = int(vfeed and
                                             self.vfeeds == self.vend)
                        p = self.pairs
                        d = 2 * p - 1
                        ddir = p if self.first_direct else p - 1
                        xq = lambda k: self.xs[n - k] if 0 <= n - k < len(
                            self.xs) else 0
                        self.dval = xq(ddir)
                        acc = sum(self.uc[i] * (xq(i) + xq(d - i))
                                  for i in range(p))
                        wide = ref.rne(acc, 14)
                        self.pending = (ref.sat16(wide),
                                        int(not -32768 <= wide <= 32767))
                        self.rnd = self.rounds()
                        self.ostate = self.OE1
        return sr, cr, fr


class CompOracle(Oracle):
    def configure_now(self, taps, uc):
        self.taps = taps
        self.uniq = (taps + 1) // 2
        self.uc = list(uc)
        self.h = ref.expand_comp(taps, uc)
        self.clear()

    def legal(self, taps):
        return isinstance(taps, int) and taps % 2 == 1 and \
            3 <= taps <= ref.COMP_MAX_TAPS

    def rounds(self):
        return (self.uniq + LANES - 1) // LANES

    def tick(self, rst=1, cfg=None, fv=0, sv=0, x=0, mr=1):
        cv = int(cfg is not None)
        ct, cc = cfg or (0, ())
        run = not self.done
        sr = int(rst and run and not self.draining and not cv and not fv and
                 self.inc < MAX_IN and self.rnd == 0)
        cr = int(rst and (self.done or
                 (run and not self.draining and self.rnd == 0 and
                  not self.mv)))
        fr = int(rst and run and not self.draining and self.rnd == 0 and
                 not self.mv and not cv)
        real_take = sv and sr
        vfeed = int(self.draining and run and self.started < self.end and
                    self.rnd == 0)
        feed = real_take or vfeed
        adv = (not self.mv) or mr
        fin = self.draining and run and self.started == self.end and \
            self.rnd == 0 and not self.mv
        self.row(rst, cv, ct, pack(cc, CU) if cv else 0, fv, sv, x, mr,
                 sr, cr, fr)
        self.cd = self.ce = self.fd = 0
        if not rst:
            self.configure_now(self.def_taps, list(self.def_uc))
            return sr, cr, fr
        if self.mv and mr:
            self.outputs.append((self.md, self.mu))
            self.outc += 1
        if mr:
            self.mv = 0
        if run and not self.draining and not cv and not fv and sv and \
                self.inc == MAX_IN:
            self.cap = 1
        if cv and cr:
            if not self.legal(ct) or len(cc) != CU or \
                    any(not -131072 <= c <= 131071 for c in cc):
                self.ce = 1
            else:
                self.configure_now(ct, list(cc)[:(ct + 1) // 2])
            self.cd = 1
        elif fv and fr:
            if self.inc == 0:
                self.done = 1
                self.fd = 1
            else:
                self.draining = 1
                self.end = self.inc + self.taps - 1
        else:
            if self.rnd:
                if self.rnd == 1:
                    if adv:
                        self.md, self.mu = self.pending
                        self.mv = 1
                        self.rnd = 0
                else:
                    self.rnd -= 1
            if run:
                if fin:
                    self.draining = 0
                    self.done = 1
                    self.fd = 1
                elif feed:
                    feedv = 0 if self.draining else (x - 65536
                                                     if x >= 32768 else x)
                    n = len(self.xs)
                    self.xs.append(feedv)
                    if self.used < ref.COMP_MAX_TAPS:
                        self.used += 1
                    if real_take:
                        self.inc += 1
                    acc = sum(self.h[k] * self.xs[n - k]
                              for k in range(self.taps)
                              if 0 <= n - k)
                    wide = ref.rne(acc)
                    self.pending = (ref.sat16(wide),
                                    int(not -32768 <= wide <= 32767))
                    self.rnd = self.rounds()
                    self.started += 1
                    self.fidx += 1
        return sr, cr, fr



rng = random.Random(0xA1B0)


def drive(o, xs, randomize=True, drain=True, hold_prob=0.3):
    """feed samples then optionally flush; rows accumulate in o.rows."""
    for x in xs:
        if randomize:
            for _ in range(rng.randrange(3)):
                o.tick(mr=int(rng.random() > hold_prob))
        for _ in range(100000):
            s, _, _ = o.tick(sv=1, x=x & 0xffff,
                             mr=int(not randomize or rng.random() > hold_prob))
            if s:
                break
        else:
            raise AssertionError('input timeout')
    if drain:
        for _ in range(100000):
            _, _, fr = o.tick(fv=1,
                              mr=int(not randomize or rng.random() > hold_prob))
            if fr:
                break
        else:
            raise AssertionError('flush request timeout')
        for _ in range(100000):
            if o.done:
                break
            o.tick(mr=int(not randomize or rng.random() > hold_prob))
        else:
            raise AssertionError('flush drain timeout')
        # one extra row so the flush_done pulse lands in the fixture
        o.tick(mr=1)


def cfg(o, taps, uc, slots):
    req = (taps, list(uc) + [0] * (slots - len(uc)))
    for _ in range(100000):
        _, c, _ = o.tick(cfg=req)
        if c:
            return
    raise AssertionError('config timeout')


TB = '''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,cv=0,fv=0,sv=0,mr=0;reg[5:0]ct=0;reg[{CB}:0]cc=0;
reg[15:0]sd=0;
wire sr,cr,fr,cd,ce,fd,mv,mu,cap;wire signed[15:0]md;
wire[15:0]inc;wire[20:0]outc;
{DUT} #(.LANES(4),.MAX_INPUTS(255)) dut(clk,rst_n,sd,sv,sr,md,mu,mv,mr,
 cv,cr,ct,cc,cd,ce,fv,fr,fd,inc,outc,cap);
integer f,n,row,rr,vv,tt,ff,ss,rdy,esr,ecr,efr,ev,eu,ed,ee,efd,ei,eo,ec;
reg[{CB}:0]ccx;reg[15:0]expected,dxx;
initial begin
 f=$fopen("vectors.txt","r");row=0;@(posedge clk);#1;
 while(!$feof(f))begin
  @(negedge clk);
  n=$fscanf(f,"%d %d %d %h %d %d %h %d %d %d %d %d %h %d %d %d %d %d %d %d\\n",
   rr,vv,tt,ccx,ff,ss,dxx,rdy,esr,ecr,efr,ev,expected,eu,ed,ee,efd,ei,eo,ec);
  if(n!=20)$fatal(1,"fixture row=%0d n=%0d",row,n);
  rst_n=rr;cv=vv;ct=tt;cc=ccx;fv=ff;sv=ss;sd=dxx;mr=rdy;#1;
  if({sr,cr,fr,mv,cd,ce,fd,cap}!=={esr[0],ecr[0],efr[0],ev[0],ed[0],ee[0],efd[0],ec[0]})
   $fatal(1,"control row=%0d got=%b exp=%b",row,{sr,cr,fr,mv,cd,ce,fd,cap},
    {esr[0],ecr[0],efr[0],ev[0],ed[0],ee[0],efd[0],ec[0]});
  if(inc!==ei[15:0] || outc!==eo[20:0])
   $fatal(1,"count row=%0d got=%0d/%0d exp=%0d/%0d",row,inc,outc,ei,eo);
  if(mv && {md,mu}!=={expected,eu[0]})
   $fatal(1,"data row=%0d got=%h/%b exp=%h/%b",row,md,mu,expected,eu[0]);
  @(posedge clk);#1;row=row+1;
 end
 $display("PASS rows=%0d",row);$finish;
end
endmodule
'''


def run(cmd, name, cwd, reject=False):
    p = subprocess.run(cmd, cwd=cwd, env=env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (cwd / name).write_text(p.stdout)
    if (not reject and p.returncode) or (reject and not p.returncode):
        raise RuntimeError(name + ': ' + p.stdout[:3000])


def corrupt_rows(rows, field, is_hex, require_flag=None):
    altered = rows.copy()
    for i, r in enumerate(rows):
        if i < 5:
            continue
        cells = r.split()
        if require_flag is not None and cells[require_flag] != '1':
            continue
        v = int(cells[field], 16 if is_hex else 10)
        cells[field] = f'{v ^ 1:x}' if is_hex else str(v ^ 1)
        altered[i] = ' '.join(cells)
        return altered
    raise AssertionError('no row to corrupt')


def swap_output_rows(rows, valid_field, data_field):
    idx = [i for i, r in enumerate(rows)
           if r.split()[valid_field] == '1' and r.split()[7] == '1']
    j = next(j for j in range(len(idx) - 1)
             if rows[idx[j]].split()[data_field]
             != rows[idx[j + 1]].split()[data_field])
    a, b = idx[j:j + 2]
    altered = rows.copy()
    ca, cb = altered[a].split(), altered[b].split()
    ca[data_field], cb[data_field] = cb[data_field], ca[data_field]
    altered[a], altered[b] = ' '.join(ca), ' '.join(cb)
    return altered


def replay_and_negatives(o, rtlname, dutname, subdir):
    d = OUT / subdir
    d.mkdir()
    rows = o.rows
    fixture = '\n'.join(rows) + '\n'
    (d / 'vectors.txt').write_text(fixture)
    cb = CU * 18 - 1 if 'comp' in rtlname else MAXP * 18 - 1
    (d / 'tb.sv').write_text(
        TB.replace('{CB}', str(cb)).replace('{DUT}', dutname))
    rtl = BASE / 'rtl' / rtlname
    run([str(TOOL / 'bin/iverilog.exe'), '-g2012', '-Wall', '-s', 'tb',
         '-o', 'test.vvp', str(rtl), 'tb.sv'], 'compile.log', d)
    run([str(TOOL / 'bin/vvp.exe'), 'test.vvp'], 'run.log', d)
    negs = []
    for field, label, is_hex, req in [
            (12, 'data', True, 11), (11, 'valid', False, None),
            (8, 'ready', False, None), (13, 'clip', False, 11),
            (16, 'flush_done', False, None), (18, 'output_count', False, None),
            (14, 'cfg_done', False, 14)]:
        try:
            altered = corrupt_rows(rows, field, is_hex, req)
        except AssertionError:
            continue
        (d / 'vectors.txt').write_text('\n'.join(altered) + '\n')
        run([str(TOOL / 'bin/vvp.exe'), 'test.vvp'],
            'negative_' + label + '.log', d, reject=True)
        negs.append(label)
    (d / 'vectors.txt').write_text(fixture)
    try:
        altered = swap_output_rows(rows, 11, 12)
        (d / 'vectors.txt').write_text('\n'.join(altered) + '\n')
        run([str(TOOL / 'bin/vvp.exe'), 'test.vvp'],
            'negative_output_order.log', d, reject=True)
        negs.append('output_order')
    except (AssertionError, StopIteration):
        pass
    (d / 'vectors.txt').write_text(fixture)
    return d, negs


import math
summaries = {}
neg_all = {}
rtls = {}

# ================= decimator =================
o_d = DecimOracle(31, list(ref.design_halfband(31)[0]))
cases_d = []
for taps in range(3, 4 * MAXP + 2, 2):
    uc = list(ref.design_halfband(taps)[0])
    o_d.tick(rst=0)
    cfg(o_d, taps, uc, MAXP)
    xs = [-32768, 32767, 0, -1, 30000] + \
        [rng.randrange(-20000, 20001) for _ in range(13)]
    drive(o_d, xs, randomize=(taps % 3 == 0))
    exp = ref.decim_int(xs, taps, uc)
    assert o_d.outputs[-len(exp):] == exp, ('decim', taps)
    assert o_d.outc == ref.decim_total_count(len(xs), taps)
    cases_d.append({'taps': taps, 'inputs': len(xs), 'outputs': o_d.outc})
# saturating coefficients, held outputs, mid-stream reset, capacity
cfg(o_d, 37, [131071] * npairs(37), MAXP)
xs = [-32768, 32767] * 30
drive(o_d, xs, True)
exp = ref.decim_int(xs, 37, [131071] * npairs(37))
assert o_d.outputs[-len(exp):] == exp
assert any(c for _, c in o_d.outputs[-len(exp):])
cfg(o_d, 31, list(ref.design_halfband(31)[0]), MAXP)
drive(o_d, [round(9000 * math.sin(2 * math.pi * 0.07 * k))
            for k in range(64)], True)
o_d.tick(rst=0); o_d.tick(rst=0)
cfg(o_d, 15, list(ref.design_halfband(15)[0]), MAXP)
drive(o_d, [rng.randrange(-30000, 30001) for _ in range(20)], True)
o_d.tick(rst=0)
cfg(o_d, 31, list(ref.design_halfband(31)[0]), MAXP)
drive(o_d, [rng.randrange(-32768, 32768) for _ in range(33)], True)
before = (o_d.taps, o_d.uc)
for bad in (0, 2, 4, 1, 39, 41, 4 * MAXP + 3):
    for _ in range(100000):
        _, c, _ = o_d.tick(cfg=(bad, [0] * MAXP))
        if c:
            break
    assert o_d.ce == 1 and (o_d.taps, o_d.uc) == before, bad
cfg(o_d, 11, list(ref.design_halfband(11)[0]), MAXP)
drive(o_d, [5, -7, 100, -100], False)
cfg(o_d, 7, list(ref.design_halfband(7)[0]), MAXP)
drive(o_d, [], False)
assert o_d.outc == 0 and o_d.done
cfg(o_d, 31, list(ref.design_halfband(31)[0]), MAXP)
drive(o_d, list(range(MAX_IN)), False, drain=False)
for _ in range(30):
    o_d.tick(sv=1, x=123, mr=1)
assert o_d.cap and o_d.inc == MAX_IN
drive(o_d, [], False)
assert o_d.done
summaries['decim'] = {'cases': len(cases_d), 'cycles': len(o_d.rows),
                      'total_outputs': o_d.outc}
d, neg_all['decim'] = replay_and_negatives(
    o_d, 'halfband_decim.sv', 'halfband_decim', 'decim')
rtls['halfband_decim.sv'] = BASE / 'rtl/halfband_decim.sv'

# ================= interpolator ===
# ================= interpolator =================
o_i = InterpOracle(31, list(ref.design_halfband(31)[0]))
cases_i = []
for taps in range(3, 4 * MAXP + 2, 2):
    uc = list(ref.design_halfband(taps)[0])
    o_i.tick(rst=0)
    cfg(o_i, taps, uc, MAXP)
    xs = [-32768, 32767, 0, -1, 12345] +         [rng.randrange(-20000, 20001) for _ in range(11)]
    drive(o_i, xs, randomize=(taps % 3 == 1))
    exp = ref.interp_int(xs, taps, uc)
    assert o_i.outputs[-len(exp):] == exp, ('interp', taps)
    assert o_i.outc == 2 * len(xs) + taps - 2
    cases_i.append({'taps': taps, 'inputs': len(xs), 'outputs': o_i.outc})
cfg(o_i, 37, [131071] * npairs(37), MAXP)
drive(o_i, [-32768, 32767] * 25, True)
assert any(c for _, c in o_i.outputs[-50:])
o_i.tick(rst=0)
cfg(o_i, 5, list(ref.design_halfband(5)[0]), MAXP)
xs = [32767, -32768, 16383, -16384, 1, -1, 3, -3]
drive(o_i, xs, False)
exp = ref.interp_int(xs, 5, list(ref.design_halfband(5)[0]))
assert o_i.outputs[-len(exp):] == exp
cfg(o_i, 31, list(ref.design_halfband(31)[0]), MAXP)
drive(o_i, [rng.randrange(-25000, 25001) for _ in range(40)], True)
o_i.tick(rst=0)
cfg(o_i, 31, list(ref.design_halfband(31)[0]), MAXP)
drive(o_i, [rng.randrange(-32768, 32768) for _ in range(29)], True)
before = (o_i.taps, o_i.uc)
for bad in (0, 2, 38, 4 * MAXP + 3):
    for _ in range(100000):
        _, c, _ = o_i.tick(cfg=(bad, [0] * MAXP))
        if c:
            break
    assert o_i.ce == 1 and (o_i.taps, o_i.uc) == before, bad
summaries['interp'] = {'cases': len(cases_i), 'cycles': len(o_i.rows),
                       'total_outputs': o_i.outc}
d, neg_all['interp'] = replay_and_negatives(
    o_i, 'halfband_interp.sv', 'halfband_interp', 'interp')
rtls['halfband_interp.sv'] = BASE / 'rtl/halfband_interp.sv'

# ================= comp FIR =================
o_c = CompOracle(15, list(ref.design_ciccomp(4, 8, 15, 0.15, 0.4)[0]))
cases_c = []
for taps in (3, 5, 9, 15, 21, 31):
    uc = list(ref.design_ciccomp(4, 8, taps, 0.15, 0.4)[0])
    o_c.tick(rst=0)
    cfg(o_c, taps, uc, CU)
    xs = [-32768, 32767, 0, 8192] +         [rng.randrange(-20000, 20001) for _ in range(14)]
    drive(o_c, xs, randomize=(taps % 4 == 1))
    exp = ref.comp_int(xs, taps, uc)
    assert o_c.outputs[-len(exp):] == exp, ('comp', taps)
    assert o_c.outc == len(xs) + taps - 1
    cases_c.append({'taps': taps, 'inputs': len(xs), 'outputs': o_c.outc})
cfg(o_c, 31, [131071] * CU, CU)
drive(o_c, [-32768, 32767] * 25, True)
assert any(c for _, c in o_c.outputs[-50:])
o_c.tick(rst=0)
cfg(o_c, 15, list(ref.design_ciccomp(3, 8, 15, 0.2, 0.35)[0]), CU)
drive(o_c, [rng.randrange(-32768, 32768) for _ in range(31)], True)
before = (o_c.taps, o_c.uc)
for bad in (0, 2, 33, 63):
    for _ in range(100000):
        _, c, _ = o_c.tick(cfg=(bad, [0] * CU))
        if c:
            break
    assert o_c.ce == 1 and (o_c.taps, o_c.uc) == before, bad
summaries['comp'] = {'cases': len(cases_c), 'cycles': len(o_c.rows),
                     'total_outputs': o_c.outc}
d, neg_all['comp'] = replay_and_negatives(
    o_c, 'cic_comp_fir.sv', 'cic_comp_fir', 'comp')
rtls['cic_comp_fir.sv'] = BASE / 'rtl/cic_comp_fir.sv'

# illegal static parameters must fail elaboration
for name, params in [
        ('halfband_decim', [('MAX_PAIRS', 0), ('MAX_PAIRS', 16),
                            ('LANES', 0), ('LANES', 5),
                            ('MAX_INPUTS', 0), ('DEFAULT_TAPS', 4)]),
        ('halfband_interp', [('MAX_PAIRS', 0), ('LANES', 5),
                             ('DEFAULT_TAPS', 2)]),
        ('cic_comp_fir', [('MAX_TAPS', 2), ('MAX_TAPS', 64),
                          ('LANES', 0), ('DEFAULT_TAPS', 33)])]:
    for param, value in params:
        d = OUT / 'illegal_static'
        d.mkdir(exist_ok=True)
        (d / 'illegal.sv').write_text(
            'module illegal;%s #(.%s(%d))d(.clk(0),.rst_n(0),.s_tdata(0),'
            '.s_tvalid(0),.m_tready(0),.cfg_valid(0),.cfg_taps(0),'
            '.cfg_coeffs(0),.flush_valid(0));endmodule\n'
            % (name, param, value))
        run([str(TOOL / 'bin/iverilog.exe'), '-g2012', '-s', 'illegal', '-o',
             'illegal.vvp', str(BASE / 'rtl' / (name + '.sv')),
             'illegal.sv'], f'static_{name}_{param}_{value}_compile.log', d)
        run([str(TOOL / 'bin/vvp.exe'), 'illegal.vvp'],
            f'static_{name}_{param}_{value}_run.log', d, reject=True)
        neg_all.setdefault('static', []).append(f'{name}_{param}_{value}')

summary = {'status': 'PASS',
           'cycles': {k: v['cycles'] for k, v in summaries.items()},
           'cases': {k: v['cases'] for k, v in summaries.items()},
           'total_outputs': {k: v['total_outputs']
                             for k, v in summaries.items()},
           'negative_tests': neg_all,
           'rtl_sha256': {n: hashlib.sha256(p.read_bytes()).hexdigest()
                          for n, p in rtls.items()},
           'scope': 'cycle-level RTL simulation only; serialized shared-MAC '
                    'rate contract (no II1); no routed timing or board claim'}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print(json.dumps(summary, indent=2))
