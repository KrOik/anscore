"""DSP-16 PFB channelizer RTL verification (iverilog -g2012 -Wall).

A cycle-accurate Python oracle (models/model.py.Oracle) emits one fixture row
per clock; the generated tb.sv drives inputs at negedge and compares every
control output, payload field and counter each cycle.  Negative tests mutate
expected fields or drive illegal static parameters and require failure.

Run:  python tests/test_pfb.py            (default M=8 P=8 full suite)
      python tests/test_pfb.py --quick    (adds M=4/P=8 and M=16/P=4 smoke)
"""
import os, sys, json, math, random, subprocess, hashlib
from pathlib import Path
from datetime import datetime

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
from model import Oracle, prototype, quantize, emit_vh, log2m, s16

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
TOOL = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
RTL = BASE / 'rtl/pfb_stream.sv'

ENV = os.environ.copy()
ENV['PATH'] = (str(TOOL / 'bin') + os.pathsep + str(TOOL / 'lib')
               + os.pathsep + ENV['PATH'])

TB_TEMPLATE = '''`timescale 1ns/1ps
module tb;
parameter integer M=%(M)d, P=%(P)d;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,cv=0,sv=0,mr=0;
reg [4:0]caddr=0;reg signed[17:0]cgain=0;reg[31:0]sd=0;
wire sr,cr,mv,mlast,busy,cd,ce,clip;
wire[31:0]md;wire[3:0]mtid;wire[7:0]muser;
wire[19:0]inc,outc;wire[15:0]frames;
pfb_stream #(.M(M),.P(P)) dut(
 .clk(clk),.rst_n(rst_n),.s_tdata(sd),.s_tvalid(sv),.s_tready(sr),
 .m_tdata(md),.m_tid(mtid),.m_tuser(muser),.m_tlast(mlast),
 .m_tvalid(mv),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_addr(caddr),.cfg_gain(cgain),
 .cfg_done(cd),.cfg_error(ce),.busy(busy),
 .cnt_in(inc),.cnt_frames(frames),.cnt_out(outc),.clip_sticky(clip));
integer f,row,nn;
integer rr,vv,ss,rdy,esr,ecr,ev,elast,ebusy,ecd,ece,eclip;
integer einc,eframes,eoutc;
reg[4:0]ca;reg[17:0]cg;reg[31:0]dd,emd;reg[3:0]etid;reg[7:0]euser;
initial begin
 f=$fopen("vectors.txt","r");row=0;@(posedge clk);#1;
 while(!$feof(f))begin
  @(negedge clk);
  nn=$fscanf(f,"%%d %%d %%h %%h %%d %%h %%d %%d %%d %%d %%h %%h %%h %%d %%d %%d %%d %%d %%d %%d %%d\\n",
   rr,vv,ca,cg,ss,dd,rdy,esr,ecr,ev,emd,etid,euser,elast,ebusy,ecd,ece,
   einc,eframes,eoutc,eclip);
  if(nn!=21)$fatal(1,"fixture row=%%0d n=%%0d",row,nn);
  rst_n=rr;cv=vv;caddr=ca;cgain=cg;sv=ss;sd=dd;mr=rdy;#1;
  if({sr,cr,mv,mlast,busy,cd,ce,clip}!=={esr[0],ecr[0],ev[0],elast[0],
     ebusy[0],ecd[0],ece[0],eclip[0]})
   $fatal(1,"ctrl row=%%0d got=%%b exp=%%b",row,
    {sr,cr,mv,mlast,busy,cd,ce,clip},
    {esr[0],ecr[0],ev[0],elast[0],ebusy[0],ecd[0],ece[0],eclip[0]});
  if(md!==emd||mtid!==etid||muser!==euser)
   $fatal(1,"data row=%%0d got=%%h/%%h/%%h exp=%%h/%%h/%%h",
    row,md,mtid,muser,emd,etid,euser);
  if(inc!==einc[19:0]||frames!==eframes[15:0]||outc!==eoutc[19:0])
   $fatal(1,"count row=%%0d got=%%0d/%%0d/%%0d exp=%%0d/%%0d/%%0d",
    row,inc,frames,outc,einc,eframes,eoutc);
  @(posedge clk);#1;row=row+1;
 end
 $display("PASS rows=%%0d",row);$finish;
end
endmodule
'''


def run(cmd, name, outdir, reject=False):
    p = subprocess.run(cmd, cwd=outdir, env=ENV, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (outdir / name).write_text(p.stdout)
    ok = (p.returncode != 0) if reject else (p.returncode == 0)
    if not ok:
        raise RuntimeError('%s rc=%d\n%s' % (name, p.returncode, p.stdout))
    return p.stdout


class Drive:
    """Scenario driver on top of the cycle oracle."""

    def __init__(self, M, P, coef, seed):
        self.o = Oracle(M, P, coef)
        self.M, self.P = M, P
        self.rng = random.Random(seed)

    def tick(self, n=1, **kw):
        for _ in range(n):
            self.o.tick(**kw)

    def reset(self):
        self.tick(6, rst=0)
        self.tick(4)

    def set_gain(self, addr, gain, expect_err=False):
        for _ in range(20000):
            self.o.tick(cv=1, caddr=addr, cgain=gain)
            if self.o.cd or self.o.ce:
                assert (self.o.ce == 1) == expect_err, \
                    'cfg addr=%d cd=%d ce=%d' % (addr, self.o.cd, self.o.ce)
                self.tick(2)
                return not expect_err
        raise AssertionError('cfg timeout addr=%d' % addr)

    def feed(self, xs, gap_rate=0.0, stall_rate=0.0):
        """xs = iterable of (re,im); optional random input gaps/stalls."""
        for re, im in xs:
            while self.rng.random() < gap_rate:
                self.o.tick(mr=int(self.rng.random() >= stall_rate))
            for _ in range(20000):
                before = self.o.cnt_in
                self.o.tick(sv=1, sre=re, sim=im,
                            mr=int(self.rng.random() >= stall_rate))
                if self.o.cnt_in == before + 1:
                    break
            else:
                raise AssertionError('input timeout')

    def drain(self, extra=0):
        for _ in range(20000):
            if not self.o.draining and not self.o.mvalid \
               and self.o.st == self.o.CAP and self.o.rpos == 0:
                break
            self.o.tick()
        self.tick(extra)

    def bursts(self):
        bs = self.o.frame_bursts()
        for b in bs:
            tids = [x[0] for x in b]
            users = {x[1] for x in b}
            lasts = [x[2] for x in b]
            assert len(b) == self.M and tids == list(range(self.M)), \
                'bad burst tids %s' % tids
            assert len(users) == 1, 'tuser not constant in frame'
            assert lasts[:-1] == [0] * (self.M - 1) and lasts[-1], \
                'bad tlast pattern'
        return bs


def tone(k, M, n_frames, amp=12000, frac=0.0):
    """Complex tone at normalized frequency (k+frac)/M cycles/sample."""
    return [(s16(round(amp * math.cos(2 * math.pi * (k + frac) * n / M))),
             s16(round(amp * math.sin(2 * math.pi * (k + frac) * n / M))))
            for n in range(M * n_frames)]


def run_clip():
    """Saturation coverage: coefficients crafted so a constant full-scale
    input clips both the FIR (two max taps in branch 0) and the gain path
    (gain ~2.0 on bin 0 with all-equal v).  Oracle is coefficient-generic."""
    M, P = 8, 8
    outdir = BASE / 'evidence' / ('rtl_%s_clip' %
                                datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    outdir.mkdir(parents=True)
    coef = [0] * (M * P)
    for m in range(M):
        coef[0 * M + m] = 131071          # v[m] = x[(f)M+m]
    coef[1 * M + 0] = 131071              # second max tap -> v[0] clips
    emit_vh(outdir / 'pfb_coeffs.vh', coef)
    (outdir / 'tb.sv').write_text(TB_TEMPLATE % {'M': M, 'P': P})
    d = Drive(M, P, coef, seed=0xC11F)
    o = d.o
    d.reset()
    d.set_gain(0, 131071)                 # ~x2.0 on bin 0
    d.feed([(32767, 0)] * (M * 6))
    d.drain(extra=4)
    assert o.clip == 1, 'expected clip_sticky'
    bursts = d.bursts()
    assert bursts and len(bursts[-1]) == M
    metrics = {'m': M, 'p': P, 'clip_sticky': o.clip,
               'cycles': len(o.rows),
               'cnt_out': o.cnt_out, 'status': 'PASS',
               'rtl_sha256': hashlib.sha256(RTL.read_bytes()).hexdigest(),
               'scope': 'saturated coefficient LUT; clip-path coverage'}
    fixture = '\n'.join(o.rows) + '\n'
    (outdir / 'vectors.txt').write_text(fixture)
    run([str(TOOL / 'bin/iverilog.exe'), '-g2012', '-Wall', '-I', '.',
         '-s', 'tb', '-o', 'test.vvp', str(RTL), 'tb.sv'],
        'compile.log', outdir)
    run([str(TOOL / 'bin/vvp.exe'), 'test.vvp'], 'run.log', outdir)
    (outdir / 'summary.json').write_text(json.dumps(metrics, indent=2))
    print('%s PASS clip rows=%d' % (outdir.name, len(o.rows)))
    return metrics


def run_config(M, P, tag):
    outdir = BASE / 'evidence' / ('rtl_%s_%s' % (
        datetime.now().strftime('%Y%m%d_%H%M%S_%f'), tag))
    outdir.mkdir(parents=True)
    coef = quantize(prototype(M, P))
    emit_vh(outdir / 'pfb_coeffs.vh', coef)
    (outdir / 'tb.sv').write_text(TB_TEMPLATE % {'M': M, 'P': P})

    d = Drive(M, P, coef, seed=0x9FB0 + M * 16 + P)
    o = d.o
    metrics = {'m': M, 'p': P}

    # ---- reset + illegal/edge configuration --------------------------------
    d.reset()
    d.set_gain(M, 65536, expect_err=True)          # addr == M illegal
    d.set_gain(31, 65536, expect_err=True)         # addr > M illegal
    d.set_gain(0, 65536)                            # legal boundary write
    metrics['illegal_cfg_rejected'] = True

    # ---- per-channel isolation: full-rate complex tone per channel ---------
    iso_db = {}
    n_fr = P + 6
    out_start = len(o.outputs)
    for k in range(M):
        d.feed(tone(k, M, n_fr))
    d.drain()
    bursts = d.bursts()
    for k in range(M):
        b = bursts[(k + 1) * n_fr - 1]            # last (settled) burst per tone
        mags = [abs(complex(*x[3])) for x in b]
        peak = mags[k]
        leak = max(m for i, m in enumerate(mags) if i != k)
        iso_db[k] = 20 * math.log10(peak / max(leak, 1e-9))
    metrics['isolation_db'] = iso_db
    metrics['min_isolation_db'] = min(iso_db.values())
    assert min(iso_db.values()) >= 25.0, \
        'channel isolation %.1f dB < 25 dB' % min(iso_db.values())

    # ---- aliasing: tone between channel centres ----------------------------
    before = len(o.outputs)
    d.feed(tone(1, M, n_fr, frac=0.5))
    d.drain()
    b = d.bursts()[-1]
    mags = [abs(complex(*x[3])) for x in b]
    top = sorted(range(M), key=lambda i: -mags[i])
    metrics['alias_midchannel_mags'] = mags
    metrics['alias_top_bins'] = top[:3]
    assert set(top[:2]) == {1, 2}, 'mid-channel tone must split ch1/ch2'

    # ---- gain path: 1.5x on channel 3 --------------------------------------
    d.set_gain(3, 98304)
    before = len(o.outputs)
    d.feed(tone(3, M, n_fr))
    d.drain()
    b = d.bursts()[-1]
    g_mag = abs(complex(*b[3][3]))
    metrics['gain_check_ch3_mag'] = g_mag
    g_exp = 12000.0 / M * 1.5                     # A/M scale, then x1.5 gain
    assert 0.9 * g_exp < g_mag < 1.1 * g_exp, \
        'gain 1.5 expected ~%.0f, got %s' % (g_exp, g_mag)
    d.set_gain(3, 65536)

    # ---- randomized stream, gaps, backpressure -----------------------------
    rng = random.Random(0xC1A0 + M)
    xs = [(rng.randrange(-20000, 20001), rng.randrange(-20000, 20001))
          for _ in range(M * 30)]
    d.feed(xs, gap_rate=0.35, stall_rate=0.45)
    d.drain(extra=10)
    metrics['random_frames'] = o.cnt_frames

    # ---- frame alignment summary over every accepted burst -----------------
    metrics['bursts_checked'] = len(d.bursts())

    # ---- sustained throughput: full-rate run -------------------------------
    before_c = len(o.rows)
    before_in = o.cnt_in
    d.feed([(1234, -5678)] * (M * 24))
    d.drain()
    cyc = len(o.rows) - before_c
    metrics['sustained_cycles_per_frame'] = cyc / 24.0
    metrics['sustained_samples_per_cycle'] = (o.cnt_in - before_in) / cyc
    bound = M + (3 * M * P + 2 * M) + 4 * (M // 2) * log2m(M) + 1
    metrics['t_frame_bound'] = bound
    assert cyc / 24.0 <= bound + 1, 'frame period %.1f exceeds bound %d' % (
        cyc / 24.0, bound)

    # ---- mid-FIR reset and recovery ----------------------------------------
    d.feed(tone(2, M, 3))
    d.tick(M * P // 2)
    d.reset()
    assert o.ndepth == 0
    d.feed(tone(2, M, n_fr))
    d.drain(extra=5)
    b = d.bursts()[-1]
    mags = [abs(complex(*x[3])) for x in b]
    assert max(range(M), key=lambda i: mags[i]) == 2

    metrics['cycles'] = len(o.rows)
    metrics['cnt_in'] = o.cnt_in
    metrics['cnt_out'] = o.cnt_out
    metrics['cnt_frames'] = o.cnt_frames
    metrics['clip_sticky'] = o.clip

    # ---- write fixture, compile, run ---------------------------------------
    fixture = '\n'.join(o.rows) + '\n'
    (outdir / 'vectors.txt').write_text(fixture)
    run([str(TOOL / 'bin/iverilog.exe'), '-g2012', '-Wall', '-I', '.',
         '-s', 'tb', '-o', 'test.vvp', str(RTL), 'tb.sv'],
        'compile.log', outdir)
    run([str(TOOL / 'bin/vvp.exe'), 'test.vvp'], 'run.log', outdir)

    # ---- mutation negatives --------------------------------------------------
    negatives = []
    # fixture columns: 7 sr,8 cr,9 mv,10 md(h),11 tid(h),12 user(h),13 last,
    #                  14 busy,15 cd,16 ce,17 inc(d),18 fr(d),19 outc(d),20 clip
    fields = {'data': (10, 'h'), 'tid': (11, 'h'), 'user': (12, 'h'),
              'last': (13, 'd'), 'sready': (7, 'd'), 'busy': (14, 'd'),
              'cnt_out': (19, 'd'), 'clip': (20, 'd')}
    for label, (fi, fmt) in fields.items():
        alt = o.rows[:]
        idx = next(i for i, r in enumerate(alt)
                   if i > 20 and r.split()[9] == '1')
        cells = alt[idx].split()
        cells[fi] = ('%x' % (int(cells[fi], 16) ^ 1) if fmt == 'h'
                     else str(int(cells[fi]) ^ 1))
        alt[idx] = ' '.join(cells)
        (outdir / 'vectors.txt').write_text('\n'.join(alt) + '\n')
        run([str(TOOL / 'bin/vvp.exe'), 'test.vvp'],
            'negative_%s.log' % label, outdir, reject=True)
        negatives.append(label)
    (outdir / 'vectors.txt').write_text(fixture)
    metrics['negative_tests'] = negatives
    metrics['status'] = 'PASS'
    metrics['rtl_sha256'] = hashlib.sha256(RTL.read_bytes()).hexdigest()
    metrics['coef_sha256'] = hashlib.sha256(
        (outdir / 'pfb_coeffs.vh').read_bytes()).hexdigest()
    metrics['scope'] = ('serialized PFB sim evidence; cycle-exact vs oracle; '
                        'no P&R/board claim')
    (outdir / 'summary.json').write_text(json.dumps(metrics, indent=2))
    print('%s PASS rows=%d min_iso=%.1fdB frame=%.1fcyc'
          % (outdir.name, len(o.rows), metrics['min_isolation_db'],
             metrics['sustained_cycles_per_frame']))
    return metrics


def static_param_rejects(outdir):
    """Illegal static parameters must be rejected at elaboration/run."""
    rejects = []
    for m, p, label in [(3, 8, 'M_3'), (32, 8, 'M_32'), (8, 0, 'P_0'),
                        (8, 17, 'P_17'), (16, 17, 'MP_272')]:
        src = ('module illegal; pfb_stream #(.M(%d),.P(%d)) dut('
               '.clk(0),.rst_n(0),.s_tdata(0),.s_tvalid(0),.m_tready(0),'
               '.cfg_valid(0),.cfg_addr(0),.cfg_gain(0)); endmodule\n' % (m, p))
        (outdir / 'illegal.sv').write_text(src)
        try:
            # compile-time rejection (bad decl bounds) also counts
            run([str(TOOL / 'bin/iverilog.exe'), '-g2012', '-I', '.',
                 '-s', 'illegal', '-o', 'illegal.vvp', str(RTL), 'illegal.sv'],
                'static_%s_compile.log' % label, outdir)
        except RuntimeError:
            rejects.append(label + '_compile')
            continue
        run([str(TOOL / 'bin/vvp.exe'), 'illegal.vvp'],
            'static_%s_run.log' % label, outdir, reject=True)
        rejects.append(label)
    return rejects


def main():
    quick = '--quick' in sys.argv
    results = []
    results.append(run_config(8, 8, 'm8p8'))
    results.append(run_clip())
    if quick:
        results.append(run_config(4, 8, 'm4p8'))
        results.append(run_config(16, 4, 'm16p4'))
    neg_dir = BASE / 'evidence' / 'static_params'
    neg_dir.mkdir(parents=True, exist_ok=True)
    emit_vh(neg_dir / 'pfb_coeffs.vh', quantize(prototype(8, 8)))
    results.append({'static_param_rejects': static_param_rejects(neg_dir)})
    top = BASE / 'evidence' / 'summary.json'
    top.write_text(json.dumps({'status': 'PASS', 'runs': results}, indent=2))
    print('ALL PASS')


if __name__ == '__main__':
    main()
