"""Cycle-exact RTL verification for the DSP-05 spectrum core family.

For every core a Python oracle reproduces the documented cycle behaviour and
emits a per-cycle fixture (inputs + expected outputs). A generated iverilog
testbench drives inputs on the negedge and compares every output every cycle,
which covers held-output stability automatically. Corrupting an expected
field must make vvp fail (mutation rejection). Each core gets its own
subdirectory under a fresh timestamped evidence dir.
"""
import os, sys, json, random, subprocess, hashlib
from pathlib import Path
from datetime import datetime
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
import reference as R

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
OUT = BASE / 'evidence' / ('rtl_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir(parents=True)
tool = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
env['PATH'] = str(tool / 'bin') + os.pathsep + str(tool / 'lib') + os.pathsep \
    + env['PATH']
RTL = BASE / 'rtl'
rng = random.Random(0x5EC0)


class WinOracle:
    def __init__(self):
        self.rows = []
        self.reset()

    def reset(self):
        self.log2n, self.wt, self.sh = 4, 0, 0
        self.index = 0
        self.up = 0
        self.pipe = [None] * 4
        self.mv, self.md, self.mu = False, 0, 0
        self.cd = self.ce = 0
        self.ram = [0] * 4096
        self.produced = []
        self.accepted = []

    def tick(self, rst=1, cv=0, cl=0, cw=0, cs=0, cov=0, cod=0, sv=0, sd=0,
             mr=1):
        adv = (not self.mv) or bool(mr)
        limit = 1 << self.log2n
        tok = self.wt != 4 or self.up >= limit
        sr = bool(rst and adv and tok and not cv)
        cr = bool(rst and not self.mv and not any(self.pipe))
        cor = bool(rst and not self.mv and not any(self.pipe) and not cv
                   and not (sv and sr) and self.up < limit)
        self.rows.append(
            f'{rst} {cv} {cl} {cw} {cs & 31:x} {cov} {cod & 0x3ffff:x} {sv} '
            f'{sd & 0xffff:x} {mr} {int(cr)} {int(cor)} {int(sr)} '
            f'{int(self.mv)} {self.md & 0xffff:x} {self.mu} {self.cd} {self.ce}')
        self.cd = self.ce = 0
        if not rst:
            self.reset()
            return sr, cr, cor
        if self.mv and mr:
            self.produced.append((self.md, self.mu))
        if adv:
            p4 = self.pipe[3]
            self.mv = p4 is not None
            if p4:
                x, n, wt, sh = p4
                self.md, self.mu = R.window_sample(x, n, self.log2n, wt, sh,
                                                   self.ram)
            new = (sd, self.index, self.wt, self.sh) if (sv and sr) else None
            self.pipe = [new, self.pipe[0], self.pipe[1], self.pipe[2]]
            if sv and sr:
                self.accepted.append(sd)
                self.index = 0 if self.index == limit - 1 else self.index + 1
        if cov and cor:
            self.ram[self.up] = cod
            self.up += 1
        if cv and cr:
            self.cd = 1
            if R.valid_window_cfg(cl, cw, cs):
                self.log2n, self.wt, self.sh = cl, cw, cs
                self.index = 0
                self.up = 0
            else:
                self.ce = 1
        return sr, cr, cor


class MagOracle:
    def __init__(self):
        self.rows = []
        self.reset()

    def reset(self):
        self.sh = 0
        self.pipe = [None] * 3
        self.mv, self.md, self.mu = False, 0, 0
        self.cd = self.ce = 0
        self.produced = []
        self.accepted = []

    def tick(self, rst=1, cv=0, cs=0, sv=0, sd=0, mr=1):
        adv = (not self.mv) or bool(mr)
        sr = bool(rst and adv and not cv)
        cr = bool(rst and not self.mv and not any(self.pipe))
        self.rows.append(
            f'{rst} {cv} {cs:x} {sv} {sd & 0xffffffff:x} {mr} {int(cr)} '
            f'{int(sr)} {int(self.mv)} {self.md:x} {self.mu} {self.cd} '
            f'{self.ce}')
        self.cd = self.ce = 0
        if not rst:
            self.reset()
            return sr, cr
        if self.mv and mr:
            self.produced.append((self.md, self.mu))
        if adv:
            p3 = self.pipe[2]
            self.mv = p3 is not None
            if p3:
                i, q, sh = p3
                self.md, self.mu = R.mag_squared(i, q, sh)
            i, q = sd & 0xffff, (sd >> 16) & 0xffff
            i -= 65536 if i >= 32768 else 0
            q -= 65536 if q >= 32768 else 0
            new = (i, q, self.sh) if (sv and sr) else None
            self.pipe = [new, self.pipe[0], self.pipe[1]]
            if sv and sr:
                self.accepted.append((i, q))
        if cv and cr:
            self.cd = 1
            if R.valid_mag_cfg(cs):
                self.sh = cs
            else:
                self.ce = 1
        return sr, cr


class AccumOracle:
    def __init__(self):
        self.rows = []
        self.reset()

    def reset(self):
        self.log2n = 4
        self.acc = 0
        self.cnt = 0
        self.mv, self.md, self.mu = False, 0, 0
        self.cd = self.ce = 0
        self.produced = []
        self.accepted = []

    def tick(self, rst=1, cv=0, cl=0, sv=0, sd=0, mr=1):
        adv = (not self.mv) or bool(mr)
        sr = bool(rst and adv and not cv)
        cr = bool(rst and not self.mv)
        self.rows.append(
            f'{rst} {cv} {cl:x} {sv} {sd & 0xffff:x} {mr} {int(cr)} {int(sr)} '
            f'{int(self.mv)} {self.md:x} {self.mu} {self.cd} {self.ce}')
        self.cd = self.ce = 0
        if not rst:
            self.reset()
            return sr, cr
        if self.mv and mr:
            self.produced.append((self.md, self.mu))
        if adv:
            fire = sv and sr
            last = self.cnt == (1 << self.log2n) - 1
            self.mv = bool(fire and last)
            if fire:
                nsum = self.acc + sd
                if last:
                    m = R.rne(nsum, 1 << self.log2n)
                    mean = min(32767, max(-32768, m))
                    clip = int(not -32768 <= m <= 32767)
                    self.md = ((nsum & 0xffffffff) << 16) | (mean & 0xffff)
                    self.mu = clip
                    self.acc = 0
                    self.cnt = 0
                else:
                    self.acc = nsum
                    self.cnt += 1
                self.accepted.append(sd)
        if cv and cr:
            self.cd = 1
            if R.valid_accum_cfg(cl):
                self.log2n = cl
                self.acc = 0
                self.cnt = 0
            else:
                self.ce = 1
        return sr, cr


class PeakOracle:
    def __init__(self):
        self.rows = []
        self.reset()

    def reset(self):
        self.log2n = 4
        self.te = 0
        self.thr = 0
        self.maxv = 0
        self.maxi = 0
        self.cnt = 0
        self.mv, self.md, self.mu = False, 0, 0
        self.cd = self.ce = 0
        self.produced = []
        self.accepted = []

    def tick(self, rst=1, cv=0, cl=0, cte=0, cth=0, sv=0, sd=0, mr=1):
        adv = (not self.mv) or bool(mr)
        sr = bool(rst and adv and not cv)
        cr = bool(rst and not self.mv)
        self.rows.append(
            f'{rst} {cv} {cl:x} {cte:x} {cth:x} {sv} {sd & 0xffffffff:x} {mr} '
            f'{int(cr)} {int(sr)} {int(self.mv)} {self.md:x} {self.mu} '
            f'{self.cd} {self.ce}')
        self.cd = self.ce = 0
        if not rst:
            self.reset()
            return sr, cr
        if self.mv and mr:
            self.produced.append((self.md, self.mu))
        if adv:
            fire = sv and sr
            last = self.cnt == (1 << self.log2n) - 1
            self.mv = bool(fire and last)
            if fire:
                better = self.cnt == 0 or sd > self.maxv
                nv, ni = (sd, self.cnt) if better else (self.maxv, self.maxi)
                if last:
                    self.md = (ni << 32) | nv
                    self.mu = int((not self.te) or nv >= self.thr)
                    self.maxv = self.maxi = self.cnt = 0
                else:
                    self.maxv, self.maxi = nv, ni
                    self.cnt += 1
                self.accepted.append(sd)
        if cv and cr:
            self.cd = 1
            if R.valid_peak_cfg(cl, cte):
                self.log2n, self.te, self.thr = cl, cte, cth
                self.maxv = self.maxi = self.cnt = 0
            else:
                self.ce = 1
        return sr, cr


def compile_run(d, rtl_files, log='run.log', expect_fail=False):
    def run(cmd, name):
        p = subprocess.run(cmd, cwd=d, env=env, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (d / name).write_text(p.stdout)
        return p.returncode
    rc = run([str(tool / 'bin/iverilog.exe'), '-g2012', '-Wall', '-s', 'tb',
              '-o', 'test.vvp'] + [str(f) for f in rtl_files] + ['tb.sv'],
             'compile.log')
    if rc:
        raise RuntimeError(f'{d} compile: ' + (d / 'compile.log').read_text())
    rc = run([str(tool / 'bin/vvp.exe'), 'test.vvp'], log)
    if expect_fail:
        if rc == 0:
            raise RuntimeError(f'{d}: mutation accepted')
    elif rc:
        raise RuntimeError(f'{d} run: ' + (d / log).read_text()[-3000:])


def mutate(rows, field, where, transform):
    """Copy rows; alter whitespace-separated field on row `where`."""
    out = rows.copy()
    cells = out[where].split()
    cells[field] = transform(cells[field])
    out[where] = ' '.join(cells)
    return out


flip1 = lambda c: str(int(c) ^ 1)
hexflip = lambda c: f'{int(c, 16) ^ 1:x}'

# =====================================================================
# window_mult
# =====================================================================
d = OUT / 'window_mult'
d.mkdir()
o = WinOracle()
cases = []


def wready(randomize):
    return int(not randomize or (len(o.rows) % 397 >= 51
                                 and rng.random() < .72))


def wcfg(log2n, wt, sh, randomize=False):
    for _ in range(200000):
        _, cr, _ = o.tick(cv=1, cl=log2n, cw=wt, cs=sh, mr=wready(randomize))
        if cr:
            return o.cd, o.ce
    raise AssertionError('window config timeout')


def wfeed(xs, randomize=False):
    for x in xs:
        if randomize:
            for _ in range(rng.randrange(3)):
                o.tick(mr=wready(True))
        for _ in range(200000):
            sr, _, _ = o.tick(sv=1, sd=x, mr=wready(randomize))
            if sr:
                break
        else:
            raise AssertionError('window input timeout')


def wupload(coeffs, randomize=False):
    for c in coeffs:
        if randomize:
            for _ in range(rng.randrange(3)):
                o.tick(mr=wready(True))
        for _ in range(200000):
            _, _, cor = o.tick(cov=1, cod=c, mr=wready(randomize))
            if cor:
                break
        else:
            raise AssertionError('coefficient upload timeout')


def wdrain(n=40):
    for _ in range(n):
        o.tick(mr=1)


def wexpect():
    assert o.produced == R.window_stream(o.accepted, o.log2n, o.wt, o.sh,
                                         o.ram), 'window stream mismatch'


for _ in range(3):
    o.tick(rst=0)
o.tick()
# every window type, several N and shifts, protocol fuzz
for wt, log2n, sh, fuzz in [(0, 4, 0, False), (1, 4, 0, True), (2, 6, 0, True),
                            (3, 8, 0, True), (1, 12, 0, False), (3, 4, -8, True),
                            (1, 5, 7, False), (2, 7, 15, True), (0, 4, -8, True)]:
    o.accepted = []
    o.produced = []
    assert wcfg(log2n, wt, sh) == (1, 0)
    xs = [-32768, 32767, 0, -1, 1] + \
        [rng.randrange(-32768, 32768) for _ in range(2 * (1 << log2n) + 13)]
    wfeed(xs, fuzz)
    wdrain()
    wexpect()
    cases.append({'core': 'window_mult', 'window': wt, 'log2n': log2n,
                  'shift': sh, 'inputs': len(o.accepted),
                  'outputs': len(o.produced)})
# clip coverage: unity window + amplify guarantees saturation
assert any(u for _, u in o.produced), 'expected clip flag coverage'
# custom table path: input is backpressured until N coefficients uploaded
assert wcfg(4, 4, 0) == (1, 0)
o.accepted = []
o.produced = []
for _ in range(6):  # offered input must stall while table incomplete
    sr, _, _ = o.tick(sv=1, sd=1234)
    assert not sr
tab = R.gen_window_table(4, 1)
wupload(tab[:9], randomize=True)
sr, _, _ = o.tick(sv=1, sd=1234)
assert not sr  # still incomplete
wupload(tab[9:], randomize=True)
wfeed([rng.randrange(-32768, 32768) for _ in range(40)], True)
wdrain()
wexpect()
assert o.produced == R.window_stream(o.accepted, 4, 1, 0)
cases.append({'core': 'window_mult', 'window': 'custom_hann_upload',
              'outputs': len(o.produced)})
# upload overflow is pure backpressure, then reconfigure works
_, _, cor = o.tick(cov=1, cod=123)
assert not cor
assert wcfg(4, 0, 0) == (1, 0)
# illegal configs: whole-field reject, prior config and state preserved
o.accepted = []
o.produced = []
wfeed([1000, -2000, 3000])
for bad in [(3, 1, 0), (13, 1, 0), (4, 5, 0), (4, 7, 0), (4, 1, -9),
            (4, 1, 16)]:
    assert wcfg(*bad) == (1, 1), bad
wfeed([rng.randrange(-32768, 32768) for _ in range(33)], True)
wdrain()
wexpect()  # still unity N=16 shift0
cases.append({'core': 'window_mult', 'kind': 'illegal_config_reject',
              'configs': 6})
# mid-stream reset discards in-flight samples and index
o.accepted = []
o.produced = []
wfeed([rng.randrange(-32768, 32768) for _ in range(10)])
for _ in range(2):
    o.tick(rst=0)
o.tick()
assert wcfg(6, 2, 0) == (1, 0)
o.accepted = []
o.produced = []
wfeed([rng.randrange(-32768, 32768) for _ in range(200)], True)
wdrain()
wexpect()
cases.append({'core': 'window_mult', 'kind': 'midstream_reset'})
# long held output: force a stalled valid record and check every cycle
o.accepted = []
o.produced = []
assert wcfg(4, 0, 0) == (1, 0)
wfeed([111, 222])
for _ in range(40):  # output holds while stalled; oracle compares per cycle
    o.tick(mr=0)
for _ in range(60):
    o.tick(mr=1)
wdrain()
wexpect()
fixture = '\n'.join(o.rows) + '\n'
(d / 'vectors.txt').write_text(fixture)
(d / 'tb.sv').write_text('''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,cv=0,cov=0,sv=0,mr=0;reg[3:0]cl=0;reg[2:0]cw=0;
reg signed[4:0]cs=0;reg signed[17:0]cod=0;reg signed[15:0]sd=0;
wire sr,cr,cor,cd,ce,mv,mu;wire signed[15:0]md;
window_mult dut(.clk(clk),.rst_n(rst_n),.s_tdata(sd),.s_tvalid(sv),
 .s_tready(sr),.m_tdata(md),.m_tuser(mu),.m_tvalid(mv),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_log2n(cl),.cfg_window(cw),.cfg_shift(cs),
 .cfg_done(cd),.cfg_error(ce),.coe_tdata(cod),.coe_tvalid(cov),
 .coe_tready(cor));
integer f,n,row,rr,vv,ll,ww,covv,svv,rrr,ecr,ecor,esr,ev,eu,ed,ee;
reg[4:0]srw;reg[17:0]cc;reg[15:0]dd,ex;
initial begin
 f=$fopen("vectors.txt","r");row=0;@(posedge clk);#1;
 while(!$feof(f))begin
  @(negedge clk);
  n=$fscanf(f,"%d %d %d %d %h %d %h %d %h %d %d %d %d %d %h %d %d %d\\n",
   rr,vv,ll,ww,srw,covv,cc,svv,dd,rrr,ecr,ecor,esr,ev,ex,eu,ed,ee);
  if(n!=18)$fatal(1,"fixture row=%0d n=%0d",row,n);
  rst_n=rr;cv=vv;cl=ll;cw=ww;cs=srw;cov=covv;cod=cc;sv=svv;sd=dd;mr=rrr;#1;
  if({cr,cor,sr,mv,cd,ce}!=={ecr[0],ecor[0],esr[0],ev[0],ed[0],ee[0]})
   $fatal(1,"control row=%0d got=%b exp=%b",row,{cr,cor,sr,mv,cd,ce},
          {ecr[0],ecor[0],esr[0],ev[0],ed[0],ee[0]});
  if(mv && {md,mu}!=={ex,eu[0]})
   $fatal(1,"data row=%0d got=%h/%b exp=%h/%b",row,md,mu,ex,eu[0]);
  @(posedge clk);#1;row=row+1;
 end
 $display("PASS rows=%0d",row);$finish;
end
endmodule
''')
compile_run(d, [RTL / 'window_cos_rom.sv', RTL / 'window_mult.sv'])
negatives = []
for field, label, tr in [(14, 'data', hexflip), (13, 'valid', flip1),
                         (12, 'ready', flip1), (15, 'user', flip1),
                         (16, 'cfg_done', flip1)]:
    idx = next(i for i, r in enumerate(o.rows)
               if i > 20 and r.split()[13] == '1')
    (d / 'vectors.txt').write_text(
        '\n'.join(mutate(o.rows, field, idx, tr)) + '\n')
    compile_run(d, [RTL / 'window_cos_rom.sv', RTL / 'window_mult.sv'],
                f'negative_{label}.log', expect_fail=True)
    negatives.append(label)
(d / 'vectors.txt').write_text(fixture)
(d / 'summary.json').write_text(json.dumps(
    {'status': 'PASS', 'cycles': len(o.rows), 'cases': cases,
     'negative_tests': negatives}, indent=2))
win_cycles = len(o.rows)
print('window_mult PASS cycles', win_cycles)

# =====================================================================
# mag_squared
# =====================================================================
d = OUT / 'mag_squared'
d.mkdir()
mo = MagOracle()
cases = []


def mready(randomize):
    return int(not randomize or (len(mo.rows) % 397 >= 51
                                 and rng.random() < .72))


def mcfg(sh, randomize=False):
    for _ in range(200000):
        _, cr = mo.tick(cv=1, cs=sh, mr=mready(randomize))
        if cr:
            return mo.cd, mo.ce
    raise AssertionError('mag config timeout')


def mfeed(vals, randomize=False):
    for v in vals:
        if randomize:
            for _ in range(rng.randrange(3)):
                mo.tick(mr=mready(True))
        for _ in range(200000):
            sr, _ = mo.tick(sv=1, sd=v, mr=mready(randomize))
            if sr:
                break
        else:
            raise AssertionError('mag input timeout')


def pack(i, q):
    return (q & 0xffff) << 16 | (i & 0xffff)


for _ in range(3):
    mo.tick(rst=0)
mo.tick()
for sh, fuzz in [(0, False), (5, True), (15, True), (1, False)]:
    mo.accepted = []
    mo.produced = []
    assert mcfg(sh) == (1, 0)
    vals = [pack(-32768, -32768), pack(32767, 32767), pack(-32768, 32767),
            pack(0, 0), pack(1, 0), pack(3, 0), pack(5, 0)] + \
        [pack(rng.randrange(-32768, 32768), rng.randrange(-32768, 32768))
         for _ in range(500)]
    mfeed(vals, fuzz)
    for _ in range(30):
        mo.tick(mr=1)
    assert mo.produced == [R.mag_squared(i, q, sh)
                           for i, q in mo.accepted]
    if sh == 0:
        assert mo.produced[0][0] == 0x80000000  # i=q=-32768 full scale
    cases.append({'core': 'mag_squared', 'shift': sh,
                  'outputs': len(mo.produced)})
# illegal shift reject keeps old config
mo.accepted = []
mo.produced = []
assert mcfg(16) == (1, 1) and mcfg(31) == (1, 1)
mfeed([pack(3, 4)] * 20)
for _ in range(30):
    mo.tick(mr=1)
assert mo.produced == [R.mag_squared(3, 4, 1)] * 20
cases.append({'core': 'mag_squared', 'kind': 'illegal_config_reject'})
# mid-pipe reset and held output
for _ in range(2):
    mo.tick(rst=0)
mo.tick()
assert mcfg(0) == (1, 0)
mo.accepted = []
mo.produced = []
mfeed([pack(300, -400)])
for _ in range(30):
    mo.tick(mr=0)
for _ in range(30):
    mo.tick(mr=1)
assert mo.produced == [(250000, 0)]
cases.append({'core': 'mag_squared', 'kind': 'midstream_reset_held_output'})
fixture = '\n'.join(mo.rows) + '\n'
(d / 'vectors.txt').write_text(fixture)
(d / 'tb.sv').write_text('''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,cv=0,sv=0,mr=0;reg[4:0]cs=0;reg[31:0]sd=0;
wire sr,cr,cd,ce,mv,mu;wire[31:0]md;
mag_squared dut(.clk(clk),.rst_n(rst_n),.s_tdata(sd),.s_tvalid(sv),
 .s_tready(sr),.m_tdata(md),.m_tuser(mu),.m_tvalid(mv),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_shift(cs),.cfg_done(cd),.cfg_error(ce));
integer f,n,row,rr,vv,svv,rrr,ecr,esr,ev,eu,ed,ee;reg[4:0]srw;reg[31:0]dd,ex;
initial begin
 f=$fopen("vectors.txt","r");row=0;@(posedge clk);#1;
 while(!$feof(f))begin
  @(negedge clk);
  n=$fscanf(f,"%d %d %h %d %h %d %d %d %d %h %d %d %d\\n",
   rr,vv,srw,svv,dd,rrr,ecr,esr,ev,ex,eu,ed,ee);
  if(n!=13)$fatal(1,"fixture row=%0d n=%0d",row,n);
  rst_n=rr;cv=vv;cs=srw;sv=svv;sd=dd;mr=rrr;#1;
  if({cr,sr,mv,cd,ce}!=={ecr[0],esr[0],ev[0],ed[0],ee[0]})
   $fatal(1,"control row=%0d got=%b exp=%b",row,{cr,sr,mv,cd,ce},
          {ecr[0],esr[0],ev[0],ed[0],ee[0]});
  if(mv && {md,mu}!=={ex,eu[0]})
   $fatal(1,"data row=%0d got=%h/%b exp=%h/%b",row,md,mu,ex,eu[0]);
  @(posedge clk);#1;row=row+1;
 end
 $display("PASS rows=%0d",row);$finish;
end
endmodule
''')
compile_run(d, [RTL / 'mag_squared.sv'])
negatives = []
for field, label, tr in [(9, 'data', hexflip), (8, 'valid', flip1),
                         (7, 'ready', flip1), (10, 'user', flip1),
                         (11, 'cfg_done', flip1)]:
    idx = next(i for i, r in enumerate(mo.rows)
               if i > 20 and r.split()[8] == '1')
    (d / 'vectors.txt').write_text(
        '\n'.join(mutate(mo.rows, field, idx, tr)) + '\n')
    compile_run(d, [RTL / 'mag_squared.sv'], f'negative_{label}.log',
                expect_fail=True)
    negatives.append(label)
(d / 'vectors.txt').write_text(fixture)
(d / 'summary.json').write_text(json.dumps(
    {'status': 'PASS', 'cycles': len(mo.rows), 'cases': cases,
     'negative_tests': negatives}, indent=2))
print('mag_squared PASS cycles', len(mo.rows))

# =====================================================================
# block_accum
# =====================================================================
d = OUT / 'block_accum'
d.mkdir()
ao = AccumOracle()
cases = []


def aready(randomize):
    return int(not randomize or (len(ao.rows) % 397 >= 51
                                 and rng.random() < .72))


def acfg(log2n, randomize=False):
    for _ in range(200000):
        _, cr = ao.tick(cv=1, cl=log2n, mr=aready(randomize))
        if cr:
            return ao.cd, ao.ce
    raise AssertionError('accum config timeout')


def afeed(xs, randomize=False):
    for x in xs:
        if randomize:
            for _ in range(rng.randrange(3)):
                ao.tick(mr=aready(True))
        for _ in range(200000):
            sr, _ = ao.tick(sv=1, sd=x, mr=aready(randomize))
            if sr:
                break
        else:
            raise AssertionError('accum input timeout')


for _ in range(3):
    ao.tick(rst=0)
ao.tick()
# rounding ties and extremes at N=16
assert acfg(4) == (1, 0)
blocks = [[8] + [0] * 15, [24] + [0] * 15, [-8] + [0] * 15, [-24] + [0] * 15,
          [40] + [0] * 15, [-40] + [0] * 15, [-32768] * 16, [32767] * 16,
          [1] * 16]
for b in blocks:
    afeed(b, randomize=True)
for _ in range(30):
    ao.tick(mr=1)
exp_means = [0, 2, 0, -2, 2, -2, -32768, 32767, 1]
exp_sums = [8, 24, -8, -24, 40, -40, -524288, 524272, 16]
assert [r[0] for r in ao.produced] == \
    [((s & 0xffffffff) << 16) | (m & 0xffff)
     for s, m in zip(exp_sums, exp_means)]
cases.append({'core': 'block_accum', 'kind': 'rounding_ties_extremes',
              'records': len(ao.produced)})
# larger N, random data, stall across the block boundary
for log2n, fuzz in [(7, True), (12, False)]:
    ao.accepted = []
    ao.produced = []
    assert acfg(log2n) == (1, 0)
    xs = [rng.randrange(-32768, 32768)
          for _ in range(2 * (1 << log2n) + 37)]
    afeed(xs, fuzz)
    for _ in range(30):
        ao.tick(mr=1)
    assert ao.produced == [(((s & 0xffffffff) << 16) | (m & 0xffff), c)
                           for s, m, c in R.accum_records(xs, log2n)]
    cases.append({'core': 'block_accum', 'log2n': log2n,
                  'records': len(ao.produced)})
# partial block dropped by reset and by config
ao.accepted = []
ao.produced = []
assert acfg(4) == (1, 0)
afeed([5] * 9)
assert acfg(5) == (1, 0)          # legal config drops the partial block
afeed([1] * 32)
for _ in range(10):
    ao.tick(mr=1)
assert ao.produced == [((32 << 16) | 1, 0)]
afeed([7] * 20)
for _ in range(2):
    ao.tick(rst=0)
ao.tick()
assert acfg(4) == (1, 0)
ao.produced = []
afeed([2] * 16)
for _ in range(10):
    ao.tick(mr=1)
assert ao.produced == [((32 << 16) | 2, 0)]
cases.append({'core': 'block_accum', 'kind': 'partial_block_drop'})
# illegal configs
assert acfg(3) == (1, 1) and acfg(13) == (1, 1)
cases.append({'core': 'block_accum', 'kind': 'illegal_config_reject'})
# held output across boundary
ao.produced = []
afeed([3] * 15)
afeed([3])   # record produced
for _ in range(25):
    ao.tick(mr=0)
afeed([1] * 16)
for _ in range(20):
    ao.tick(mr=1)
assert ao.produced == [((48 << 16) | 3, 0), ((16 << 16) | 1, 0)]
fixture = '\n'.join(ao.rows) + '\n'
(d / 'vectors.txt').write_text(fixture)
(d / 'tb.sv').write_text('''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,cv=0,sv=0,mr=0;reg[3:0]cl=0;reg signed[15:0]sd=0;
wire sr,cr,cd,ce,mv,mu;wire[47:0]md;
block_accum dut(.clk(clk),.rst_n(rst_n),.s_tdata(sd),.s_tvalid(sv),
 .s_tready(sr),.m_tdata(md),.m_tuser(mu),.m_tvalid(mv),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_log2n(cl),.cfg_done(cd),.cfg_error(ce));
integer f,n,row,rr,vv,ll,svv,rrr,ecr,esr,ev,eu,ed,ee;reg[15:0]dd;reg[47:0]ex;
initial begin
 f=$fopen("vectors.txt","r");row=0;@(posedge clk);#1;
 while(!$feof(f))begin
  @(negedge clk);
  n=$fscanf(f,"%d %d %h %d %h %d %d %d %d %h %d %d %d\\n",
   rr,vv,ll,svv,dd,rrr,ecr,esr,ev,ex,eu,ed,ee);
  if(n!=13)$fatal(1,"fixture row=%0d n=%0d",row,n);
  rst_n=rr;cv=vv;cl=ll;sv=svv;sd=dd;mr=rrr;#1;
  if({cr,sr,mv,cd,ce}!=={ecr[0],esr[0],ev[0],ed[0],ee[0]})
   $fatal(1,"control row=%0d got=%b exp=%b",row,{cr,sr,mv,cd,ce},
          {ecr[0],esr[0],ev[0],ed[0],ee[0]});
  if(mv && {md,mu}!=={ex,eu[0]})
   $fatal(1,"data row=%0d got=%h/%b exp=%h/%b",row,md,mu,ex,eu[0]);
  @(posedge clk);#1;row=row+1;
 end
 $display("PASS rows=%0d",row);$finish;
end
endmodule
''')
compile_run(d, [RTL / 'block_accum.sv'])
negatives = []
for field, label, tr in [(9, 'data', hexflip), (8, 'valid', flip1),
                         (7, 'ready', flip1), (10, 'user', flip1),
                         (11, 'cfg_done', flip1)]:
    idx = next(i for i, r in enumerate(ao.rows)
               if i > 20 and r.split()[8] == '1')
    (d / 'vectors.txt').write_text(
        '\n'.join(mutate(ao.rows, field, idx, tr)) + '\n')
    compile_run(d, [RTL / 'block_accum.sv'], f'negative_{label}.log',
                expect_fail=True)
    negatives.append(label)
(d / 'vectors.txt').write_text(fixture)
(d / 'summary.json').write_text(json.dumps(
    {'status': 'PASS', 'cycles': len(ao.rows), 'cases': cases,
     'negative_tests': negatives}, indent=2))
print('block_accum PASS cycles', len(ao.rows))

# =====================================================================
# peak_search
# =====================================================================
d = OUT / 'peak_search'
d.mkdir()
po = PeakOracle()
cases = []


def pready(randomize):
    return int(not randomize or (len(po.rows) % 397 >= 51
                                 and rng.random() < .72))


def pcfg(log2n, te=0, thr=0, randomize=False):
    for _ in range(200000):
        _, cr = po.tick(cv=1, cl=log2n, cte=te, cth=thr, mr=pready(randomize))
        if cr:
            return po.cd, po.ce
    raise AssertionError('peak config timeout')


def pfeed(vals, randomize=False):
    for v in vals:
        if randomize:
            for _ in range(rng.randrange(3)):
                po.tick(mr=pready(True))
        for _ in range(200000):
            sr, _ = po.tick(sv=1, sd=v, mr=pready(randomize))
            if sr:
                break
        else:
            raise AssertionError('peak input timeout')


for _ in range(3):
    po.tick(rst=0)
po.tick()
assert pcfg(4) == (1, 0)
# max positions: last, first, earliest-of-ties, all-zero, full-scale
blocks = [list(range(16)), list(range(15, -1, -1)),
          [0, 0, 99, 3, 4, 5, 6, 99, 8, 9, 10, 11, 12, 13, 14, 15],
          [0] * 16, [0xffffffff] + [0] * 15,
          [rng.randrange(0, 1 << 32) for _ in range(16)]]
for b in blocks:
    pfeed(b, randomize=True)
for _ in range(30):
    po.tick(mr=1)
exp = R.peak_records([v for b in blocks for v in b], 4)
assert [r[0] for r in po.produced] == [(i << 32) | m for i, m, _ in exp]
assert [r[1] for r in po.produced] == [1] * len(exp)
assert po.produced[1][0] >> 32 == 0      # descending: max at index 0
assert po.produced[2][0] >> 32 == 2      # tie at 2 and 7: earliest wins
assert po.produced[3][0] >> 32 == 0      # all zeros -> index 0
assert (po.produced[4][0] & 0xffffffff) == 0xffffffff
cases.append({'core': 'peak_search', 'kind': 'positions_ties',
              'records': len(po.produced)})
# threshold flag: met at equality, unmet below, disabled -> 1
po.produced = []
assert pcfg(4, 1, 99) == (1, 0)
pfeed(blocks[2])
for _ in range(10):
    po.tick(mr=1)
assert po.produced[0][1] == 1
assert pcfg(4, 1, 100) == (1, 0)
pfeed(blocks[2])
for _ in range(10):
    po.tick(mr=1)
assert po.produced[1][1] == 0 and (po.produced[1][0] & 0xffffffff) == 99
assert pcfg(4, 0, 0) == (1, 0)
pfeed(blocks[2])
for _ in range(10):
    po.tick(mr=1)
assert po.produced[2][1] == 1
cases.append({'core': 'peak_search', 'kind': 'threshold_flag'})
# larger block, random data
po.produced = []
assert pcfg(8) == (1, 0)
vals = [rng.randrange(0, 1 << 32) for _ in range(700)]
pfeed(vals, True)
for _ in range(20):
    po.tick(mr=1)
assert po.produced == [((i << 32) | m, t)
                       for i, m, t in R.peak_records(vals, 8)]
cases.append({'core': 'peak_search', 'log2n': 8,
              'records': len(po.produced)})
# mid-block reset drops partial state; illegal configs rejected
pfeed([9] * 10)
for _ in range(2):
    po.tick(rst=0)
po.tick()
assert pcfg(4) == (1, 0)
po.produced = []
pfeed([1] * 16)
for _ in range(10):
    po.tick(mr=1)
assert po.produced == [(0 << 32 | 1, 1)]
assert pcfg(2) == (1, 1) and pcfg(4, 2) == (1, 1) and pcfg(13) == (1, 1)
cases.append({'core': 'peak_search',
              'kind': 'midblock_reset_illegal_config'})
fixture = '\n'.join(po.rows) + '\n'
(d / 'vectors.txt').write_text(fixture)
(d / 'tb.sv').write_text('''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,cv=0,sv=0,mr=0;reg[3:0]cl=0;reg[1:0]cte=0;reg[31:0]cth=0,sd=0;
wire sr,cr,cd,ce,mv,mu;wire[47:0]md;
peak_search dut(.clk(clk),.rst_n(rst_n),.s_tdata(sd),.s_tvalid(sv),
 .s_tready(sr),.m_tdata(md),.m_tuser(mu),.m_tvalid(mv),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_log2n(cl),.cfg_thr_en(cte),
 .cfg_threshold(cth),.cfg_done(cd),.cfg_error(ce));
integer f,n,row,rr,vv,ll,tte,svv,rrr,ecr,esr,ev,eu,ed,ee;
reg[31:0]tth,dd;reg[47:0]ex;
initial begin
 f=$fopen("vectors.txt","r");row=0;@(posedge clk);#1;
 while(!$feof(f))begin
  @(negedge clk);
  n=$fscanf(f,"%d %d %h %h %h %d %h %d %d %d %d %h %d %d %d\\n",
   rr,vv,ll,tte,tth,svv,dd,rrr,ecr,esr,ev,ex,eu,ed,ee);
  if(n!=15)$fatal(1,"fixture row=%0d n=%0d",row,n);
  rst_n=rr;cv=vv;cl=ll;cte=tte;cth=tth;sv=svv;sd=dd;mr=rrr;#1;
  if({cr,sr,mv,cd,ce}!=={ecr[0],esr[0],ev[0],ed[0],ee[0]})
   $fatal(1,"control row=%0d got=%b exp=%b",row,{cr,sr,mv,cd,ce},
          {ecr[0],esr[0],ev[0],ed[0],ee[0]});
  if(mv && {md,mu}!=={ex,eu[0]})
   $fatal(1,"data row=%0d got=%h/%b exp=%h/%b",row,md,mu,ex,eu[0]);
  @(posedge clk);#1;row=row+1;
 end
 $display("PASS rows=%0d",row);$finish;
end
endmodule
''')
compile_run(d, [RTL / 'peak_search.sv'])
negatives = []
for field, label, tr in [(11, 'data', hexflip), (10, 'valid', flip1),
                         (9, 'ready', flip1), (12, 'user', flip1),
                         (13, 'cfg_done', flip1)]:
    idx = next(i for i, r in enumerate(po.rows)
               if i > 20 and r.split()[10] == '1')
    (d / 'vectors.txt').write_text(
        '\n'.join(mutate(po.rows, field, idx, tr)) + '\n')
    compile_run(d, [RTL / 'peak_search.sv'], f'negative_{label}.log',
                expect_fail=True)
    negatives.append(label)
(d / 'vectors.txt').write_text(fixture)
(d / 'summary.json').write_text(json.dumps(
    {'status': 'PASS', 'cycles': len(po.rows), 'cases': cases,
     'negative_tests': negatives}, indent=2))
print('peak_search PASS cycles', len(po.rows))

summary = {
    'status': 'PASS',
    'cores': ['window_mult', 'mag_squared', 'block_accum', 'peak_search'],
    'rtl_sha256': {f.name: hashlib.sha256(f.read_bytes()).hexdigest()
                   for f in sorted(RTL.glob('*.sv'))},
    'scope': 'isolated stream cores; no P&R/board claim'}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print('PASS all cores')
