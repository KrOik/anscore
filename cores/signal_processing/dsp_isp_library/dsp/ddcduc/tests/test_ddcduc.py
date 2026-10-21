"""DSP-03 DDC/DUC RTL verification driver.

Transaction-level stimulus: each row is one micro-op.
  op=0  control cycle: applies rst/cv/cfg fields/mr for exactly one clock
  op=1  input beat: asserts s_tvalid with (si,sq) and HOLDS the row until
        s_tready is sampled at a clock edge (flow-controlled source, mr=1
        so a stalled input can never deadlock against a held output stall;
        output-stall coverage comes from op=0 idle rows with mr=0)

Row text:  op rst cv inc init rate shift taps coeffs si sq mr
           (inc/init 8h, rate/shift/taps 2h, coeffs 72h, si/sq 4h)

The TB logs once per cycle, evaluated just after negedge (pre-edge values):
  "O <cyc> <i> <q> <clip>"   every m_tvalid && m_tready transfer
  "E <cyc> DONE|ERR"         cfg_done / cfg_error pulses
  "A <cyc>"                  every s_tvalid && s_tready accept
  hold-stability $fatal      if m_* change while valid && !ready
  "CTR <in> <out> <sat> <ovf>" at $finish

Expected outputs are produced BEFORE the sim runs by the bit-exact model in
models/model.py; comparisons are exact (value, order, count) per output
beat plus float-model spectral/gain tolerance checks.  No DUT output is
used to construct expected values.
"""
import os, sys, json, math, random, subprocess, hashlib
from pathlib import Path
from datetime import datetime

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
sys.path.insert(0, str(BASE / 'models'))
import model as M

OUT = BASE / 'evidence' / ('rtl_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir()
TOOL = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
env['PATH'] = (str(TOOL / 'bin') + os.pathsep + str(TOOL / 'lib') + os.pathsep +
               env.get('PATH', ''))

RTLS = [BASE / 'rtl/ddcduc_nco.sv', BASE / 'rtl/ddcduc_iq_fir.sv',
        BASE / 'rtl/ddc_stream.sv', BASE / 'rtl/duc_stream.sv',
        BASE.parents[1] / 'infra/stream/stream_sync_fifo.v']
rng = random.Random(0xDDC03)


# ------------------------------------------------------------ stimulus ---
class Script:
    def __init__(self):
        self.rows = []
        self.ev_done = 0
        self.ev_err = 0
        self.n_in = 0

    @staticmethod
    def _row(op=0, rst=1, cv=0, cfg=None, si=0, sq=0, mr=1):
        c = cfg or {}
        co = M.pack_coeffs(c.get('uc', ()))
        return (f"{op} {rst} {cv} {c.get('inc', 0):08x} {c.get('init', 0):08x} "
                f"{c.get('rate', 0):02x} {c.get('shift', 0):02x} "
                f"{c.get('taps', 0):02x} {co:072x} "
                f"{si & 0xffff:04x} {sq & 0xffff:04x} {mr}")

    def reset(self, n=4):
        for _ in range(n):
            self.rows.append(self._row(rst=0, mr=0))

    def cfg(self, cfg):
        """One commit cycle; returns whether it was legal."""
        legal = M.legal_config(cfg.get('rate', 0), cfg.get('shift', 0),
                               cfg.get('taps', 0))
        self.rows.append(self._row(cv=1, cfg=cfg))
        self.ev_done += 1
        if not legal:
            self.ev_err += 1
        return legal

    def inputs(self, seq, gap=0.0):
        """op=1 beat rows (mr=1) interleaved with op=0 stall rows."""
        for si, sq in seq:
            self.rows.append(self._row(op=1, si=si, sq=sq, mr=1))
            self.n_in += 1
            while rng.random() < gap:
                self.rows.append(self._row(mr=int(rng.random() < 0.5)))

    def idle(self, n, mr=1):
        for _ in range(n):
            self.rows.append(self._row(mr=mr))

    def stall_mix(self, n):
        """n control cycles with randomized m_tready."""
        for _ in range(n):
            self.rows.append(self._row(mr=int(rng.random() < 0.6)))

    def drain(self, n=1500):
        self.idle(n, mr=1)

    def text(self):
        return '\n'.join(self.rows) + '\n'


# --------------------------------------------------------------- TBs -----
TB_COMMON = '''
module tb;
reg clk=0; always #5 clk=~clk;
reg rst_n=0, cv=0, sv=0, mr=0;
reg [31:0] inc=0, init=0; reg [6:0] rate=0; reg [5:0] shift=0, taps=0;
reg [287:0] coeffs=0; reg signed [15:0] si=0, sq=0;
wire sr,cr,mv,mcl; wire signed [15:0] mi,mq;
wire cd,ce; wire [15:0] incnt; wire [31:0] outcnt; wire [15:0] sat;
OVFDECL
DUT_DECL
integer f,o,n,cyc,adv,op,rr,vv,mrv;
integer pend, wasrst; reg signed [15:0] pmi,pmq; reg pcl;
initial begin
 f=$fopen("stim.txt","r"); o=$fopen("out.txt","w");
 cyc=0; adv=1; pend=0; wasrst=0;
 @(posedge clk); #1;
 while(!$feof(f)) begin
  @(negedge clk);
  if(adv) begin
   n=$fscanf(f,"%d %d %d %h %h %h %h %h %h %h %h %d\\n",
             op,rr,vv,inc,init,rate,shift,taps,coeffs,si,sq,mrv);
   if(n!=12) $fatal(1,"fixture parse failed cyc=%0d",cyc);
   rst_n=rr; cv=vv; mr=mrv;
   sv = (op==1);
  end
  #1;
  if(!rst_n) begin
   if(wasrst && mv) $fatal(1,"m_tvalid under reset cyc=%0d",cyc);
   wasrst=1; pend=0;
  end else begin
   wasrst=0;
   if(pend) begin
    if(!(mv && mi===pmi && mq===pmq && mcl===pcl))
     $fatal(1,"held output changed cyc=%0d",cyc);
    pend=0;
   end
   if(mv && !mr) begin pend=1; pmi=mi; pmq=mq; pcl=mcl; end
  end
  if(sv && sr) $fdisplay(o,"A %0d",cyc);
  if(mv && mr) $fdisplay(o,"O %0d %h %h %d",cyc,mi[15:0],mq[15:0],mcl);
  if(cd) $fdisplay(o,"E %0d DONE",cyc);
  if(ce) $fdisplay(o,"E %0d ERR",cyc);
  if(op==1) adv=sr; else adv=1;
  cyc=cyc+1;
  if(cyc>4000000) $fatal(1,"watchdog timeout");
 end
 $fdisplay(o,"CTR %0d %0d %0d %0d",incnt,outcnt,sat,OVFW);
 $display("done rows=%0d",cyc);
 $finish;
end
endmodule
'''

DUT_DDC = '''ddc_stream dut(.clk(clk),.rst_n(rst_n),
 .s_i_tdata(si),.s_q_tdata(sq),.s_tvalid(sv),.s_tready(sr),
 .m_i_tdata(mi),.m_q_tdata(mq),.m_clip(mcl),.m_tvalid(mv),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_phase_inc(inc),.cfg_phase_init(init),
 .cfg_rate(rate),.cfg_shift(shift),.cfg_taps(taps),.cfg_coeffs(coeffs),
 .cfg_done(cd),.cfg_error(ce),.input_count(incnt),.output_count(outcnt),
 .sat_count(sat),.fifo_overflow(ovf));'''

DUT_DUC = '''duc_stream dut(.clk(clk),.rst_n(rst_n),
 .s_i_tdata(si),.s_q_tdata(sq),.s_tvalid(sv),.s_tready(sr),
 .m_i_tdata(mi),.m_q_tdata(mq),.m_clip(mcl),.m_tvalid(mv),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_phase_inc(inc),.cfg_phase_init(init),
 .cfg_rate(rate),.cfg_shift(shift),.cfg_taps(taps),.cfg_coeffs(coeffs),
 .cfg_done(cd),.cfg_error(ce),.input_count(incnt),.output_count(outcnt),
 .sat_count(sat));'''

TB_LOOP = '''
module tb;
reg clk=0; always #5 clk=~clk;
reg rst_n=0, cv=0, sv=0, mr=0;
reg [31:0] inc=0, init=0; reg [6:0] rate=0; reg [5:0] shift=0, taps=0;
reg [287:0] coeffs=0; reg signed [15:0] si=0, sq=0;
wire usr,ucr,dsr,dcr,umv,umcl,dmv,dmcl,dcd,dce,ovf;
wire signed [15:0] dmi,dmq,umi,umq;
wire [15:0] incnt; wire [31:0] outcnt; wire [15:0] sat;
duc_stream u_duc(.clk(clk),.rst_n(rst_n),
 .s_i_tdata(si),.s_q_tdata(sq),.s_tvalid(sv),.s_tready(usr),
 .m_i_tdata(umi),.m_q_tdata(umq),.m_clip(umcl),.m_tvalid(umv),
 .m_tready(dsr),
 .cfg_valid(cv),.cfg_ready(ucr),.cfg_phase_inc(inc),.cfg_phase_init(init),
 .cfg_rate(rate),.cfg_shift(shift),.cfg_taps(taps),.cfg_coeffs(coeffs),
 .cfg_done(),.cfg_error(),.input_count(),.output_count(),.sat_count());
ddc_stream u_ddc(.clk(clk),.rst_n(rst_n),
 .s_i_tdata(umi),.s_q_tdata(umq),.s_tvalid(umv),.s_tready(dsr),
 .m_i_tdata(dmi),.m_q_tdata(dmq),.m_clip(dmcl),.m_tvalid(dmv),
 .m_tready(mr),
 .cfg_valid(cv),.cfg_ready(dcr),.cfg_phase_inc(inc),.cfg_phase_init(init),
 .cfg_rate(rate),.cfg_shift(shift),.cfg_taps(taps),.cfg_coeffs(coeffs),
 .cfg_done(dcd),.cfg_error(dce),.input_count(incnt),.output_count(outcnt),
 .sat_count(sat),.fifo_overflow(ovf));
integer f,o,n,cyc,adv,op,rr,vv,mrv;
integer pend, wasrst; reg signed [15:0] pmi,pmq; reg pcl;
initial begin
 f=$fopen("stim.txt","r"); o=$fopen("out.txt","w");
 cyc=0; adv=1; pend=0; wasrst=0;
 @(posedge clk); #1;
 while(!$feof(f)) begin
  @(negedge clk);
  if(adv) begin
   n=$fscanf(f,"%d %d %d %h %h %h %h %h %h %h %h %d\\n",
             op,rr,vv,inc,init,rate,shift,taps,coeffs,si,sq,mrv);
   if(n!=12) $fatal(1,"fixture parse failed cyc=%0d",cyc);
   rst_n=rr; cv=vv; mr=mrv;
   sv = (op==1);
  end
  #1;
  if(!rst_n) begin
   if(wasrst && dmv) $fatal(1,"m_tvalid under reset cyc=%0d",cyc);
   wasrst=1; pend=0;
  end else begin
   wasrst=0;
   if(pend) begin
    if(!(dmv && dmi===pmi && dmq===pmq && dmcl===pcl))
     $fatal(1,"held output changed cyc=%0d",cyc);
    pend=0;
   end
   if(dmv && !mr) begin pend=1; pmi=dmi; pmq=dmq; pcl=dmcl; end
  end
  if(sv && usr) $fdisplay(o,"A %0d",cyc);
  if(dmv && mr) $fdisplay(o,"O %0d %h %h %d",cyc,dmi[15:0],dmq[15:0],dmcl);
  if(dcd) $fdisplay(o,"E %0d DONE",cyc);
  if(dce) $fdisplay(o,"E %0d ERR",cyc);
  if(op==1) adv=usr; else adv=1;
  cyc=cyc+1;
  if(cyc>8000000) $fatal(1,"watchdog timeout");
 end
 $fdisplay(o,"CTR %0d %0d %0d %0d",incnt,outcnt,sat,ovf);
 $display("done rows=%0d",cyc);
 $finish;
end
endmodule
'''


def compile_run(d, tb_text):
    (d / 'tb.sv').write_text(tb_text)
    comp = subprocess.run(
        [str(TOOL / 'bin/iverilog.exe'), '-g2012', '-Wall', '-s', 'tb',
         '-o', 'test.vvp'] + [str(p) for p in RTLS] + ['tb.sv'],
        cwd=d, env=env, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT)
    (d / 'compile.log').write_text(comp.stdout)
    if comp.returncode:
        raise RuntimeError(f'{d.name} compile failed:\n{comp.stdout}')
    run = subprocess.run([str(TOOL / 'bin/vvp.exe'), 'test.vvp'], cwd=d,
                         env=env, text=True, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, timeout=1800)
    (d / 'run.log').write_text(run.stdout)
    if run.returncode:
        raise RuntimeError(f'{d.name} run failed:\n{run.stdout}')
    return (d / 'out.txt').read_text().splitlines()


def parse_log(lines):
    outs, evs, accepts, ctr = [], [], 0, None
    for line in lines:
        f = line.split()
        if not f:
            continue
        if f[0] == 'O':
            i = int(f[2], 16); q = int(f[3], 16)
            outs.append((int(f[1]),
                         i - 65536 if i >= 32768 else i,
                         q - 65536 if q >= 32768 else q, int(f[4])))
        elif f[0] == 'E':
            evs.append(f[2])
        elif f[0] == 'A':
            accepts += 1
        elif f[0] == 'CTR':
            ctr = tuple(int(x) for x in f[1:])
    return {'outs': outs, 'events': evs, 'accepts': accepts, 'ctr': ctr}


def run_case(tag, sc, dut):
    d = OUT / tag
    d.mkdir()
    (d / 'stim.txt').write_text(sc.text())
    if dut == 'loop':
        return parse_log(compile_run(d, TB_LOOP))
    decl = DUT_DDC if dut == 'ddc' else DUT_DUC
    ovfdecl = 'wire ovf;' if dut == 'ddc' else "wire ovf = 1'b0;"
    tb = TB_COMMON.replace('OVFDECL', ovfdecl).replace('DUT_DECL', decl) \
                  .replace('OVFW', 'ovf')
    return parse_log(compile_run(d, tb))


def check_exact(name, got, want):
    """got: list of (cyc,i,q,clip); want: list of (i,q)."""
    seq = [(i, q) for _, i, q, _ in got]
    if seq != list(want):
        for idx, (a, b) in enumerate(zip(seq, want)):
            if a != b:
                raise AssertionError(
                    f'{name}: mismatch output {idx}: rtl={a} model={b} '
                    f'(len {len(seq)} vs {len(want)})')
        raise AssertionError(f'{name}: length {len(seq)} != {len(want)}')
    return len(seq)


def s16(v):
    return max(-32768, min(32767, int(round(v))))


def tone(n, fc, amp, phase=0.0):
    return [(s16(amp * math.cos(2 * math.pi * fc * k + phase)),
             s16(amp * math.sin(2 * math.pi * fc * k + phase)))
            for k in range(n)]


def add_tones(*sigs):
    n = len(sigs[0])
    return [(s16(sum(s[k][0] for s in sigs)),
             s16(sum(s[k][1] for s in sigs))) for k in range(n)]


def rand_seq(n, lo, hi):
    return [(rng.randrange(lo, hi), rng.randrange(lo, hi))
            for _ in range(n)]


def bin_amp(seq, k):
    i_s = [o[0] for o in seq]
    q_s = [o[1] for o in seq]
    return M.dft_mag(i_s, q_s, k)[0] / len(seq)


report = {'cases': [], 'mutations': [], 'illegal_params': []}

uc15, g15, h15 = M.design_comp(3, 8, 15, fp=0.2)
INC8 = M.inc_for(0.25)
CFG_TONE = {'inc': INC8, 'init': 0, 'rate': 8, 'shift': 9,
            'taps': 15, 'uc': uc15}
# DUC: CIC interpolator inherent gain is R**(N-1) -> normalize >>6 for R8N3
CFG_TONE_UC = {'inc': INC8, 'init': 0, 'rate': 8, 'shift': 6,
               'taps': 15, 'uc': uc15}
CFG_BYP = {'inc': INC8, 'init': 0, 'rate': 8, 'shift': 9, 'taps': 1, 'uc': ()}

# ============================ DDC cases ==================================
# ddc_tone_dc: single tone exactly at NCO frequency -> I/Q DC
sc = Script()
sc.reset()
assert sc.cfg(CFG_TONE)
xin = tone(512, 0.25, 12000)
want = M.ddc_int(xin, INC8, 0, 8, 9, 15, uc15)
sc.inputs(xin, gap=0.10)
sc.drain(900)
res = run_case('ddc_tone_dc', sc, 'ddc')
n = check_exact('ddc_tone_dc', res['outs'], want)
assert n == 64 and res['ctr'][0] == 512 and res['ctr'][1] == 64
assert res['ctr'][3] == 0, 'fifo overflow flag set'
tail = want[-16:]
wi = sum(p[0] for p in tail) / 16
wq = sum(p[1] for p in tail) / 16
fout = M.ddc_float(xin, 0.25, 0.0, 8, 9, 15, [c / 32768 for c in h15])
fi = sum(p[0] for p in fout[-16:]) / 16
fq = sum(p[1] for p in fout[-16:]) / 16
rel = abs(complex(wi - fi, wq - fq)) / max(1.0, abs(complex(fi, fq)))
assert rel < 0.03, f'float-model DC level deviation {rel}'
assert res['ctr'][2] == 0, 'unexpected saturations'
report['cases'].append({'name': 'ddc_tone_dc', 'outputs': n,
                        'iq_mean_int': [round(wi), round(wq)],
                        'iq_mean_float': [round(fi), round(fq)],
                        'rel_err': round(rel, 5)})

# ddc_tone_img: desired baseband tone + image tone rejection
sc = Script()
sc.reset()
assert sc.cfg(CFG_TONE)
xin = add_tones(tone(512, 0.25 + 1 / 64, 12000),
                tone(512, 0.25 + 10 / 64, 16000))
want = M.ddc_int(xin, INC8, 0, 8, 9, 15, uc15)
sc.inputs(xin, gap=0.15)
sc.stall_mix(60)
sc.drain(900)
res = run_case('ddc_tone_img', sc, 'ddc')
n = check_exact('ddc_tone_img', res['outs'], want)
assert n == 64
a8 = bin_amp(want[-48:], 6)         # f_out = 8/64 = 6/48 cycles/sample
a12 = bin_amp(want[-48:], 12)       # aliased image at 0.25 cycles/sample
assert a8 > 4000, a8
assert a12 / a8 < 0.05, f'image ratio {a12 / a8}'
report['cases'].append({'name': 'ddc_tone_img', 'outputs': n,
                        'desired_amp': round(a8, 1),
                        'image_amp': round(a12, 1),
                        'image_ratio_db':
                            round(20 * math.log10(a12 / a8), 1)})

# ddc_rates: rate sweep R in {2,3,5,8,16,64}, random data, bypass FIR
for R, N_IN in [(2, 96), (3, 99), (5, 100), (8, 128), (16, 128), (64, 256)]:
    sh = min(24, round(3 * math.log2(R)))
    cfg = {'inc': M.inc_for(-0.125), 'init': 0x12345678, 'rate': R,
           'shift': sh, 'taps': 1, 'uc': ()}
    sc = Script()
    sc.reset()
    assert sc.cfg(cfg)
    xin = rand_seq(N_IN, -4000, 4000)
    want = M.ddc_int(xin, cfg['inc'], cfg['init'], R, sh, 1, ())
    sc.inputs(xin, gap=0.10)
    sc.stall_mix(40)
    sc.drain(1500)
    res = run_case(f'ddc_rate{R}', sc, 'ddc')
    n = check_exact(f'ddc_rate{R}', res['outs'], want)
    assert n == N_IN // R, (n, N_IN, R)
    assert res['ctr'][0] == N_IN and res['ctr'][1] == n
    report['cases'].append({'name': f'ddc_rate{R}', 'outputs': n,
                            'in': N_IN, 'rate': R})

# ddc_fir_taps: symmetric comp FIR active, R=8, verify MAC chain exactness
sc = Script()
sc.reset()
uc7 = M.design_comp(3, 8, 7, fp=0.25)[0]
cfg = {'inc': INC8, 'init': 0, 'rate': 8, 'shift': 9, 'taps': 7, 'uc': uc7}
assert sc.cfg(cfg)
xin = rand_seq(256, -9000, 9000)
want = M.ddc_int(xin, INC8, 0, 8, 9, 7, uc7)
sc.inputs(xin, gap=0.15)
sc.drain(1200)
res = run_case('ddc_fir_taps', sc, 'ddc')
n = check_exact('ddc_fir_taps', res['outs'], want)
assert n == 32
report['cases'].append({'name': 'ddc_fir_taps', 'outputs': n, 'taps': 7})

# ddc_illegal: illegal commits rejected, running config/state untouched
sc = Script()
sc.reset()
assert sc.cfg(CFG_BYP)
xin = rand_seq(256, -8000, 8000)
sc.inputs(xin, gap=0.10)
sc.idle(20)
for bad in ({'inc': INC8, 'init': 0, 'rate': 1, 'shift': 9, 'taps': 1,
             'uc': ()},
            {'inc': INC8, 'init': 0, 'rate': 65, 'shift': 9, 'taps': 1,
             'uc': ()},
            {'inc': INC8, 'init': 0, 'rate': 8, 'shift': 25, 'taps': 1,
             'uc': ()},
            {'inc': INC8, 'init': 0, 'rate': 8, 'shift': 9, 'taps': 4,
             'uc': ()},
            {'inc': INC8, 'init': 0, 'rate': 8, 'shift': 9, 'taps': 33,
             'uc': ()}):
    assert not sc.cfg(bad)
xin2 = rand_seq(128, -8000, 8000)
sc.inputs(xin2)
sc.drain(900)
want = M.ddc_int(xin + xin2, INC8, 0, 8, 9, 1, ())
res = run_case('ddc_illegal', sc, 'ddc')
n = check_exact('ddc_illegal', res['outs'], want)
assert res['events'].count('ERR') == 5 and res['events'].count('DONE') == 6
assert n == (256 + 128) // 8
report['cases'].append({'name': 'ddc_illegal', 'outputs': n,
                        'illegal_rejected': 5})

# ddc_reconfig_reset: legal mid-stream reconfig + reset recovery
sc = Script()
sc.reset()
assert sc.cfg(CFG_TONE)
xin = rand_seq(200, -6000, 6000)
sc.inputs(xin[:120])
sc.drain(900)
want = M.ddc_int(xin[:120], INC8, 0, 8, 9, 15, uc15)
sc.reset(3)
xin_b = rand_seq(128, -6000, 6000)
cfg_b = {'inc': M.inc_for(0.125), 'init': 0x80000000, 'rate': 4,
         'shift': 6, 'taps': 1, 'uc': ()}
assert sc.cfg(cfg_b)
sc.inputs(xin_b, gap=0.12)
sc.drain(900)
want += M.ddc_int(xin_b, cfg_b['inc'], cfg_b['init'], 4, 6, 1, ())
res = run_case('ddc_reconfig_reset', sc, 'ddc')
n = check_exact('ddc_reconfig_reset', res['outs'], want)
assert n == 120 // 8 + 128 // 4
report['cases'].append({'name': 'ddc_reconfig_reset', 'outputs': n})

# ddc_saturate: full-scale input, model-accurate clipping behaviour
# fc=1/8 hits the c=s=23169 phase diagonal so the mixer genuinely clips
sc = Script()
sc.reset()
cfg_sat = {'inc': M.inc_for(0.125), 'init': 0, 'rate': 8, 'shift': 9,
           'taps': 1, 'uc': ()}
assert sc.cfg(cfg_sat)
xin = [(32767, 32767), (-32768, -32768)] * 64
want = M.ddc_int(xin, cfg_sat['inc'], 0, 8, 9, 1, ())
sc.inputs(xin)
sc.drain(900)
res = run_case('ddc_saturate', sc, 'ddc')
n = check_exact('ddc_saturate', res['outs'], want)
assert res['ctr'][2] > 0, 'expected recorded saturations'
report['cases'].append({'name': 'ddc_saturate', 'outputs': n,
                        'sat_count': res['ctr'][2]})

# ============================ DUC cases ==================================
# duc_tone: low-rate complex tone -> high-rate tone + CIC-limited images
sc = Script()
sc.reset()
assert sc.cfg(CFG_TONE_UC)
xin = tone(64, 1 / 16, 8000)
want = M.duc_int(xin, INC8, 0, 8, 6, 15, uc15)
sc.inputs(xin, gap=0.10)
sc.stall_mix(80)
sc.drain(3000)
res = run_case('duc_tone', sc, 'duc')
n = check_exact('duc_tone', res['outs'], want)
assert n == 512 and res['ctr'][0] == 64 and res['ctr'][1] == 512
ad = bin_amp(want[192:], 82)        # steady-state: f=132/512 = 82.5/320...
# use exact-frequency DFT over the last 256 outputs
ad = bin_amp(want[-256:], 66)       # 132/512 = 66/256
imgs = [bin_amp(want[-256:], (66 + 32 * k) % 256) for k in range(1, 8)]
img = max(imgs)
assert ad > 2500, ad
assert img / ad < 0.12, f'worst image ratio {img / ad}'
report['cases'].append({'name': 'duc_tone', 'outputs': n,
                        'desired_amp': round(ad, 1),
                        'worst_image_amp': round(img, 1),
                        'image_ratio_db':
                            round(20 * math.log10(img / ad), 1)})

# duc_rates: rate sweep {2,4,8,64}, bypass FIR, nonzero phase init
for R, N_IN in [(2, 48), (4, 48), (8, 48), (64, 24)]:
    sh = min(24, round(2 * math.log2(R)))
    cfg = {'inc': INC8, 'init': 0xABCDEF01, 'rate': R, 'shift': sh,
           'taps': 1, 'uc': ()}
    sc = Script()
    sc.reset()
    assert sc.cfg(cfg)
    xin = rand_seq(N_IN, -3000, 3000)
    want = M.duc_int(xin, INC8, cfg['init'], R, sh, 1, ())
    sc.inputs(xin, gap=0.10)
    sc.stall_mix(50)
    sc.drain(max(2000, N_IN * R * 2 + 400))
    res = run_case(f'duc_rate{R}', sc, 'duc')
    n = check_exact(f'duc_rate{R}', res['outs'], want)
    assert n == N_IN * R, (n, N_IN, R)
    assert res['ctr'][0] == N_IN and res['ctr'][1] == n
    report['cases'].append({'name': f'duc_rate{R}', 'outputs': n,
                            'in': N_IN, 'rate': R})

# duc_fir_taps + illegal rejection
sc = Script()
sc.reset()
uc7d = M.design_comp(3, 8, 7, fp=0.25)[0]
cfg = {'inc': INC8, 'init': 0, 'rate': 8, 'shift': 6, 'taps': 7, 'uc': uc7d}
assert sc.cfg(cfg)
xin = rand_seq(40, -5000, 5000)
sc.inputs(xin[:24], gap=0.10)
for bad in ({'inc': INC8, 'init': 0, 'rate': 0, 'shift': 9, 'taps': 7,
             'uc': uc7d},
            {'inc': INC8, 'init': 0, 'rate': 100, 'shift': 9, 'taps': 7,
             'uc': uc7d},
            {'inc': INC8, 'init': 0, 'rate': 8, 'shift': 30, 'taps': 7,
             'uc': uc7d},
            {'inc': INC8, 'init': 0, 'rate': 8, 'shift': 9, 'taps': 2,
             'uc': uc7d}):
    assert not sc.cfg(bad)
sc.inputs(xin[24:])
sc.drain(3000)
want = M.duc_int(xin, INC8, 0, 8, 6, 7, uc7d)
res = run_case('duc_illegal', sc, 'duc')
n = check_exact('duc_illegal', res['outs'], want)
assert res['events'].count('ERR') == 4 and res['events'].count('DONE') == 5
assert n == 320
report['cases'].append({'name': 'duc_illegal', 'outputs': n,
                        'illegal_rejected': 4})

# ============================ loopback ===================================
sc = Script()
sc.reset()
assert sc.cfg(CFG_TONE)
xin = tone(48, 1 / 16, 8000)
up = M.duc_int(xin, INC8, 0, 8, 9, 15, uc15)
want = M.ddc_int(up, INC8, 0, 8, 9, 15, uc15)
sc.inputs(xin, gap=0.08)
sc.stall_mix(100)
sc.drain(6000)
res = run_case('loopback_duc_ddc', sc, 'loop')
n = check_exact('loopback_duc_ddc', res['outs'], want)
assert n == 48
# identity check: documented net gain is 1/8 (DUC shift=9 vs R^(N-1)=64
# in the shared config), so the output tone should track input/8
pk_in = max(abs(complex(*o)) for o in xin[16:])
pk_out = max(abs(complex(i, q)) for _, i, q, _ in res['outs'][16:])
rel = abs(pk_out * 8 - pk_in) / pk_in
assert rel < 0.25, f'loopback amplitude deviation {rel}'
report['cases'].append({'name': 'loopback_duc_ddc', 'outputs': n,
                        'pk_in': round(pk_in, 1), 'pk_out': round(pk_out, 1),
                        'amp_rel_err': round(rel, 4)})

# ============================ mutations ===================================
sc = Script()
sc.reset()
assert sc.cfg(CFG_TONE)
xin = tone(256, 0.25 + 1 / 64, 10000)
xmut = list(xin)
xmut[100] = (-xmut[100][0], -xmut[100][1])
want = M.ddc_int(xmut, INC8, 0, 8, 9, 15, uc15)
sc.inputs(xmut)
sc.drain(900)
res = run_case('ddc_mutation', sc, 'ddc')
check_exact('ddc_mutation', res['outs'], want)
want_orig = M.ddc_int(xin, INC8, 0, 8, 9, 15, uc15)
assert [(i, q) for _, i, q, _ in res['outs']] != want_orig, \
    'mutation had no observable effect'
bad = list(want)
bad[0] = (bad[0][0] ^ 1, bad[0][1])
try:
    check_exact('selfcheck', res['outs'], bad)
    raise SystemExit('comparator failed to reject corrupted golden')
except AssertionError:
    pass
report['mutations'].append({'case': 'ddc_mutation',
                            'mutation_detected': True,
                            'comparator_selfcheck': 'reject_ok'})

# ============================ static params ===============================
for mod, param, val in [('ddc_stream', 'CIC_STAGES', 0),
                        ('ddc_stream', 'CIC_STAGES', 5),
                        ('ddc_stream', 'FIFO_DEPTH', 2),
                        ('duc_stream', 'CIC_STAGES', 0),
                        ('duc_stream', 'CIC_STAGES', 9)]:
    d = OUT / f'illegal_{mod}_{param}_{val}'
    d.mkdir()
    top = (f'module illegal; {mod} #(.{param}({val})) dut('
           ".clk(1'b0),.rst_n(1'b0)); endmodule\n")
    (d / 'illegal.sv').write_text(top)
    comp = subprocess.run(
        [str(TOOL / 'bin/iverilog.exe'), '-g2012', '-Wall', '-s', 'illegal',
         '-o', 'illegal.vvp'] + [str(p) for p in RTLS] + ['illegal.sv'],
        cwd=d, env=env, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT)
    (d / 'compile.log').write_text(comp.stdout)
    if comp.returncode == 0:
        run = subprocess.run([str(TOOL / 'bin/vvp.exe'), 'illegal.vvp'],
                             cwd=d, env=env, text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (d / 'run.log').write_text(run.stdout)
        ok = run.returncode != 0
    else:
        ok = True
    assert ok, f'{mod} {param}={val} not rejected'
    report['illegal_params'].append({'module': mod, 'param': param,
                                     'value': val, 'rejected': True})

report['status'] = 'PASS'
report['rtl_sha256'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                        for p in RTLS}
report['scope'] = ('transaction-level RTL sim, bit-exact vs models/model.py; '
                   'float model for spectral/gain tolerances; '
                   'no timing/P&R/board claim')
(OUT / 'summary.json').write_text(json.dumps(report, indent=2))
print(OUT)
for c in report['cases']:
    print(c)
print('PASS', len(report['cases']), 'cases;',
      len(report['illegal_params']), 'illegal params rejected')
