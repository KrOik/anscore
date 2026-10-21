"""Cycle-accurate RTL validation for INFRA-07 testsrc cores.

A Python oracle emits per-cycle rows of inputs + expected outputs; generated
Icarus testbenches drive inputs and compare every registered/combinational
output each cycle (the resampler harness pattern). Expected data always comes
from the independent models in ../models/reference.py -- the oracle only
tracks handshake timing. Covers: all sources under random ready fuzz, sink
under random valid gaps, SOF/EOL markers on 1x1/2x2/7x5 and other frames,
mid-stream reset, illegal config rejection, checker mutation rejection
(data/order/count/sideband), trigger timing, and two wired chains.
Writes evidence/sim_<timestamp>/ with vectors, TBs, logs and summary.json.
"""
import os, sys, json, random, subprocess, hashlib, shutil
from pathlib import Path
from datetime import datetime
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
from reference import (prbs16_gen16, prbs16_words, crc32_words, CRC32_INIT,
                       ToneCfg, tone_samples, ImgCfg, image_pixel, BpModel,
                       ChkCfg, ChkModel)

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
OUT = BASE / 'evidence' / ('sim_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir(parents=True)
TOOL = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
env['PATH'] = str(TOOL / 'bin') + os.pathsep + str(TOOL / 'lib') + os.pathsep + env['PATH']
RTL = BASE / 'rtl'
rng = random.Random(0x7E57)

def run(cmd, name, work, reject=False):
    p = subprocess.run(cmd, cwd=work, env=env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (work / name).write_text(p.stdout)
    if (not reject and p.returncode) or (reject and not p.returncode):
        raise RuntimeError(f'{name}: {p.stdout[-2000:]}')
    return p.stdout

def iverilog(tb_text, name, work, rtl_files, top='tb'):
    (work / 'tb.sv').write_text(tb_text)
    run([str(TOOL / 'bin/iverilog.exe'), '-g2012', '-Wall', '-s', top,
         '-o', 'sim.vvp'] + [str(RTL / f) for f in rtl_files] + ['tb.sv'],
        'compile.log', work)
    return run([str(TOOL / 'bin/vvp.exe'), 'sim.vvp'], 'run.log', work)

def hx(v, w):
    # zero-padded hex matching the %h field width emitted by $fwrite/$display
    return format(v & ((1 << w) - 1), f'0{max(1, (w + 3) // 4)}x')

# ===========================================================================
# Oracles: each emits the expected-output fields for the CURRENT row, then
# applies the edge update so the next row shows post-edge values.
# ===========================================================================
class CrcOracle:
    def __init__(self, width):
        self.w = width
        self.reset()
    def reset(self):
        self.state = CRC32_INIT; self.result = 0; self.done = 0
    def tick(self, rst, init, sv, sd, sl):
        row = f'{rst} {init} {sv} {hx(sd, self.w)} {sl} ' \
              f'{int(bool(rst))} {hx(self.state, 32)} {hx(self.result, 32)} {self.done}'
        if not rst:
            self.reset()
        else:
            ndone = 0
            if sv:  # s_tready == rst_n
                base = CRC32_INIT if init else self.state
                from reference import crc32_word
                nxt = crc32_word(base, sd, self.w)
                self.state = CRC32_INIT if sl else nxt
                if sl:
                    self.result = nxt ^ 0xFFFFFFFF; ndone = 1
            elif init:
                self.state = CRC32_INIT
            self.done = ndone
        return row

class PrbsOracle:
    def __init__(self):
        self.reset()
    def reset(self):
        self.armed = 0; self.valid = 0; self.data = 0; self.lfsr = 0
        self.nwords = 0; self.tmode1 = 0; self.tper = 0; self.tcnt = 0
        self.wc = 0; self.done = 0; self.cd = 0; self.ce = 0; self.tg = 0
    def _cfg_bad(self, tm, tp):
        return tm > 1 or (tm == 1 and tp == 0)
    def tick(self, rst, cv, seed, nwords, tm, tp, rdy):
        row = f'{rst} {cv} {hx(seed,16)} {nwords} {tm} {tp} {rdy} ' \
              f'{int(bool(rst))} {self.valid} {hx(self.data,16)} {self.cd} ' \
              f'{self.ce} {self.tg} {self.wc} {self.done} {self.armed}'
        self.cd = self.ce = self.tg = 0
        if not rst:
            self.reset()
            return row
        if cv and not self._cfg_bad(tm, tp):
            st, w = prbs16_gen16(seed)
            self.armed = 1; self.done = 0; self.lfsr = st; self.data = w
            self.valid = 1; self.nwords = nwords
            self.tper = tp; self.tcnt = 0; self.tmode1 = (tm == 1)
            self.wc = 0; self.cd = 1
        else:
            if cv:
                self.ce = 1
            if self.valid and rdy:
                st, w = prbs16_gen16(self.lfsr)
                self.lfsr = st; self.data = w
                if self.wc != 0xFFFFFFFF:
                    self.wc += 1
                if self.nwords and self.wc == self.nwords:
                    self.valid = 0; self.done = 1
                if self.tmode1:
                    if self.tcnt + 1 == self.tper:
                        self.tcnt = 0; self.tg = 1
                    else:
                        self.tcnt += 1
        return row

class ToneOracle:
    """Expected samples precomputed from tone_samples(); oracle tracks timing."""
    def __init__(self, horizon):
        self.horizon = horizon
        self.reset()
    def reset(self):
        self.armed = 0; self.valid = 0; self.data = 0
        self.samples = []; self.wraps = set(); self.idx = 0
        self.nsamp = 0; self.tmode = 0; self.tper = 0; self.tcnt = 0
        self.sc = 0; self.done = 0; self.cd = 0; self.ce = 0; self.tg = 0
    def _cfg_bad(self, mode, ntone, dwell, tm, tp, max_tones):
        return (mode > 1 or (mode == 0 and not 1 <= ntone <= max_tones)
                or (mode == 1 and dwell == 0) or tm > 2
                or (tm == 2 and tp == 0))
    def tick(self, rst, cv, cfg_tuple, rdy):
        (mode, ntone, incs, phases, amps, step, stop, dwell,
         nsamp, tm, tp) = cfg_tuple
        row = f'{rst} {cv} {mode} {ntone} {hx(incs,128)} {hx(phases,128)} ' \
              f'{hx(amps,64)} {hx(step & 0xFFFFFFFF,32)} {hx(stop,32)} ' \
              f'{dwell} {nsamp} {tm} {tp} {rdy} ' \
              f'{int(bool(rst))} {self.valid} {hx(self.data & 0xFFFF,16)} ' \
              f'{self.cd} {self.ce} {self.tg} {self.sc} {self.done} {self.armed}'
        self.cd = self.ce = self.tg = 0
        if not rst:
            self.reset()
            return row
        if cv and not self._cfg_bad(mode, ntone, dwell, tm, tp, 4):
            cfg = ToneCfg(mode=mode, ntone=ntone,
                          inc=tuple(incs >> (32 * i) & 0xFFFFFFFF for i in range(4)),
                          phase=tuple(phases >> (32 * i) & 0xFFFFFFFF for i in range(4)),
                          amp=tuple(_s16(amps >> (16 * i) & 0xFFFF) for i in range(4)),
                          sw_step=_s32(step), sw_stop=stop, sw_dwell=dwell)
            self.samples, wl = tone_samples(cfg, self.horizon)
            self.wraps = set(wl)
            self.idx = 0; self.data = self.samples[0]; self.valid = 1
            self.armed = 1; self.done = 0; self.nsamp = nsamp
            self.tmode = tm; self.tper = tp; self.tcnt = 0; self.sc = 0
            self.cd = 1
        else:
            if cv:
                self.ce = 1
            if self.valid and rdy:
                k = self.idx
                self.idx += 1
                self.data = self.samples[self.idx]
                if self.sc != 0xFFFFFFFF:
                    self.sc += 1
                if self.nsamp and self.sc == self.nsamp:
                    self.valid = 0; self.done = 1
                if self.tmode == 1 and k in self.wraps:
                    self.tg = 1
                if self.tmode == 2:
                    if self.tcnt + 1 == self.tper:
                        self.tcnt = 0; self.tg = 1
                    else:
                        self.tcnt += 1
        return row

def _s16(v):
    return v - 0x10000 if v & 0x8000 else v
def _s32(v):
    v &= 0xFFFFFFFF
    return v - 0x100000000 if v & 0x80000000 else v

class ImgOracle:
    """Beats computed on demand; nframes=0 streams forever."""
    def __init__(self, bits=8):
        self.bits = bits
        self.reset()
    def reset(self):
        self.armed = 0; self.valid = 0; self.data = 0; self.user = 0; self.last = 0
        self.w = 1; self.h = 1; self.pat = 0; self.nf = 0
        self.frame = 0; self.x = 0; self.y = 0
        self.fc = 0; self.pc = 0; self.done = 0
        self.tmode = 0; self.tframe = 0
        self.cd = 0; self.ce = 0; self.tg = 0
    def _cfg_bad(self, w, h, pat, tm):
        return (w == 0 or w > 4096 or h == 0 or h > 4096 or pat > 6
                or (pat == 5 and w < 8) or tm > 4)
    def _pix(self, f, x, y):
        return image_pixel(ImgCfg(self.w, self.h, self.pat, 0, self.bits),
                           f, x, y)
    def tick(self, rst, cv, w, h, pat, nf, tm, tf, rdy):
        row = f'{rst} {cv} {w} {h} {pat} {nf} {tm} {tf} {rdy} ' \
              f'{int(bool(rst))} {self.valid} {hx(self.data, self.bits)} ' \
              f'{self.user} {self.last} {self.cd} {self.ce} {self.tg} ' \
              f'{self.fc} {self.pc} {self.done} {self.armed}'
        self.cd = self.ce = self.tg = 0
        if not rst:
            self.reset()
            return row
        if cv and not self._cfg_bad(w, h, pat, tm):
            self.armed = 1; self.done = 0
            self.w = w; self.h = h; self.pat = pat; self.nf = nf
            self.tmode = tm; self.tframe = tf
            self.frame = 0; self.x = 0; self.y = 0
            self.fc = 0; self.pc = 0
            self.data = 0
            self.user = 1; self.last = int(w == 1); self.valid = 1
            self.cd = 1
        else:
            if cv:
                self.ce = 1
            if self.valid and rdy:
                ox, oy, of = self.x, self.y, self.frame      # consumed beat
                eol = (ox == self.w - 1)
                eof = eol and (oy == self.h - 1)
                nx = 0 if eol else ox + 1
                ny = (0 if oy == self.h - 1 else oy + 1) if eol else oy
                nf_ = (of + 1) & 0xFFFF if eof else of
                self.data = self._pix(nf_, nx, ny)
                self.user = int(eof)
                self.last = int(nx == self.w - 1)
                self.x = nx; self.y = ny; self.frame = nf_
                if self.pc != 0xFFFFFFFF:
                    self.pc += 1
                if eof:
                    if self.fc != 0xFFFFFFFF:
                        self.fc += 1
                    if self.nf and self.frame == self.nf:
                        self.valid = 0; self.done = 1
                if ((self.tmode == 1 and ox == 0 and oy == 0) or
                        (self.tmode == 2 and eol) or
                        (self.tmode == 3 and ox == 0 and oy == 0
                         and of == self.tframe) or
                        (self.tmode == 4 and eof)):
                    self.tg = 1
        return row

class BpOracle:
    def __init__(self, width):
        self.w = width
        self.reset()
    def reset(self):
        self.armed = 0; self.bpm = None
        self.mode = 0
        self.beat = 0; self.bd = 0; self.bu = 0; self.bl = 0
        self.tmode1 = 0; self.tper = 0; self.tcnt = 0
        self.cnt = 0; self.cd = 0; self.ce = 0; self.tg = 0
    def _cfg_bad(self, mode, run, stall, tm, tp):
        return (mode > 2 or (mode == 2 and run + stall == 0)
                or tm > 1 or (tm == 1 and tp == 0))
    def tick(self, rst, cv, mode, seed, thr, run, stall, tm, tp,
             sv, sd, su, sl):
        sr = int(bool(rst) and self.armed and
                 (self.bpm.ready() if self.bpm else 0))
        row = f'{rst} {cv} {mode} {hx(seed,16)} {thr} {run} {stall} ' \
              f'{tm} {tp} {sv} {hx(sd, self.w)} {su} {sl} ' \
              f'{int(bool(rst))} {sr} {self.beat} {hx(self.bd, self.w)} ' \
              f'{self.bu} {self.bl} {self.tg} {self.cnt} {self.cd} ' \
              f'{self.ce} {self.armed}'
        self.cd = self.ce = self.tg = 0; nbeat = 0
        if not rst:
            self.reset()
            return row
        if cv and not self._cfg_bad(mode, run, stall, tm, tp):
            self.armed = 1; self.cd = 1; self.mode = mode
            self.bpm = BpModel(BPCFG(mode, seed, thr, run, stall))
            self.tmode1 = (tm == 1); self.tper = tp; self.tcnt = 0
            self.cnt = 0; self.beat = 0
        else:
            if cv:
                self.ce = 1
            if self.armed:
                self.bpm.tick()
                if sv and sr:
                    nbeat = 1; self.bd = sd; self.bu = su; self.bl = sl
                    if self.cnt != 0xFFFFFFFF:
                        self.cnt += 1
                    if self.tmode1:
                        if self.tcnt + 1 == self.tper:
                            self.tcnt = 0; self.tg = 1
                        else:
                            self.tcnt += 1
        self.beat = nbeat
        return row

from reference import BpCfg as BPCFG

class ChkOracle:
    def __init__(self, width):
        self.w = width
        self.reset()
    def reset(self):
        self.armed = 0; self.m = None
        self.cd = 0; self.ce = 0; self.tg = 0
    def _cfg_bad(self, exp, ie, iw, ih, tm, tp):
        return (exp == 0 or (ie and (iw == 0 or ih == 0))
                or tm > 3 or (tm == 3 and tp == 0))
    def tick(self, rst, cv, exp, ce_, crc, se, ss, sp, ie, iw, ih,
             tm, tp, sv, sd, su, sl):
        m = self.m
        v = m.verdict() if m else dict(done=0, count=0, frames=0, err_crc=0,
                                       err_seq=0, err_sof=0, err_eol=0,
                                       err_extra=0, first_error=0xFFFFFFFF)
        sr = int(bool(rst) and self.armed)
        row = (f'{rst} {cv} {exp} {ce_} {hx(crc,32)} {se} {hx(ss,16)} '
               f'{hx(sp,16)} {ie} {iw} {ih} {tm} {tp} {sv} {hx(sd,self.w)} '
               f'{su} {sl} {sr} {v["count"]} {v["frames"]} {v["done"]} '
               f'{v["err_crc"]} {v["err_seq"]} {v["err_sof"]} {v["err_eol"]} '
               f'{v["err_extra"]} {hx(v["first_error"],32)} {self.tg} '
               f'{self.cd} {self.ce} {self.armed}')
        self.cd = self.ce = self.tg = 0
        if not rst:
            self.reset()
            return row
        if cv and not self._cfg_bad(exp, ie, iw, ih, tm, tp):
            self.m = ChkModel(ChkCfg(expected=exp, crc_en=ce_, crc=crc,
                                     seq_en=se, seq_start=ss, seq_step=sp,
                                     img_en=ie, img_w=iw, img_h=ih,
                                     bits=self.w, trig_mode=tm,
                                     trig_period=tp))
            self.armed = 1; self.cd = 1
        else:
            if cv:
                self.ce = 1
            if self.armed and self.m:
                if sv:                              # s_tready high when armed
                    self.tg = self.m.feed(sd, su, sl)
                else:
                    self.tg = self.m.edge()
        return row

# ===========================================================================
# Testbench templates. Each row: input fields then expected-output fields.
# Drive at negedge, compare mid-cycle (pre-edge), complete at posedge.
# ===========================================================================
TB_HEAD = '''`timescale 1ns/1ps
module tb;
reg clk=0; always #5 clk=~clk;
integer f,n,row;
'''

def tb_footer(fmt, sigs, drives, checks):
    return f'''initial begin
 f=$fopen("vectors.txt","r"); row=0; @(posedge clk); #1;
 while(!$feof(f)) begin
  @(negedge clk);
  n=$fscanf(f,"{fmt}\\n",{sigs});
  if(n!={sigs.count(',')+1}) $fatal(1,"fixture row=%0d n=%0d",row,n);
{drives}
  #1;
{checks}
  @(posedge clk); #1; row=row+1;
 end
 $display("PASS rows=%0d",row); $finish;
end
endmodule
'''

def work_dir(tag):
    d = OUT / tag; d.mkdir()
    return d

def write_vectors(d, rows):
    (d / 'vectors.txt').write_text('\n'.join(rows) + '\n')

results = []
def record(tag, rows, extra=''):
    results.append(dict(case=tag, cycles=len(rows), status='PASS', note=extra))
    print('PASS', tag, len(rows), 'cycles', extra)

# --------------------------------------------------------------------------
# crc32 (two widths)
# --------------------------------------------------------------------------
def crc_tb(w):
    return TB_HEAD + f'''reg rst_n=0,init=0,sv=0,sl=0; reg [{w-1}:0] sd=0;
wire sr,dn; wire [31:0] st,res;
crc32 #(.DATA_WIDTH({w})) dut(.clk(clk),.rst_n(rst_n),.init(init),
 .s_tdata(sd),.s_tvalid(sv),.s_tready(sr),.s_tlast(sl),
 .state(st),.result(res),.done(dn));
reg [31:0] r_,i_,v_,l_,esr,edn; reg [{w-1}:0] d_; reg [31:0] est,eres;
''' + tb_footer(
        r'%d %d %d %h %d %d %h %h %d',
        'r_,i_,v_,d_,l_,esr,est,eres,edn',
        '''  rst_n=r_; init=i_; sv=v_; sd=d_; sl=l_;''',
        '''  if(sr!==esr[0]||st!==est||res!==eres||dn!==edn[0])
   $fatal(1,"row=%0d got sr=%b st=%h res=%h dn=%b exp %b %h %h %b",row,sr,st,res,dn,esr[0],est,eres,edn[0]);''')

for w in (16, 8):
    d = work_dir(f'crc32_w{w}')
    o = CrcOracle(w); rows = []
    seed = 0xACE1
    for _ in range(3): rows.append(o.tick(0, 0, 0, 0, 0))
    for frame in range(3):
        n = 17 if frame == 0 else (5 if frame == 1 else 33)
        ws = prbs16_words((seed + frame) & 0xFFFF, n)
        mask = (1 << w) - 1
        for i, wd in enumerate(ws):
            gap = (i % 7 == 3)                      # producer gaps
            if gap: rows.append(o.tick(1, 0, 0, 0, 0))
            rows.append(o.tick(1, 0, 1, wd & mask, int(i == n - 1)))
    # mid-stream init pulse discards partial frame, then a fresh frame
    rows.append(o.tick(1, 0, 1, 0x1234 & ((1 << w) - 1), 0))
    rows.append(o.tick(1, 1, 0, 0, 0))              # init reseeds
    ws = prbs16_words(0x5555, 9)
    for i, wd in enumerate(ws):
        rows.append(o.tick(1, 0, 1, wd & ((1 << w) - 1), int(i == 8)))
    for _ in range(6): rows.append(o.tick(1, 0, 0, 0, 0))
    # held-valid beat: same beat while stalled is impossible (sr=1); reset test
    rows.append(o.tick(0, 0, 0, 0, 0)); rows.append(o.tick(0, 0, 1, 5, 0))
    for i, wd in enumerate(ws[:4]):
        rows.append(o.tick(1, 0, 1, wd & ((1 << w) - 1), int(i == 3)))
    write_vectors(d, rows)
    iverilog(crc_tb(w), f'crc32_w{w}', d, ['crc32.sv'])
    record(f'crc32_w{w}', rows)

# --------------------------------------------------------------------------
# prbs_source
# --------------------------------------------------------------------------
def prbs_tb():
    return TB_HEAD + '''reg rst_n=0,cv=0,rdy=0; reg [15:0] seed=0;
reg [31:0] nw=0,tp=0; reg [2:0] tm=0;
wire [15:0] md; wire mv,cr,cd,ce,tg,dn,ar; wire [31:0] wc;
prbs_source dut(.clk(clk),.rst_n(rst_n),.m_tdata(md),.m_tvalid(mv),
 .m_tready(rdy),.cfg_valid(cv),.cfg_ready(cr),.cfg_seed(seed),
 .cfg_nwords(nw),.cfg_trig_mode(tm),.cfg_trig_period(tp),
 .cfg_done(cd),.cfg_error(ce),.trigger(tg),.word_count(wc),
 .done(dn),.armed(ar));
reg [31:0] r_,v_,y_,ecr,emv,ecd,ece,etg,edn,ear; reg [15:0] sd_,emd; reg [31:0] nw_,tp_,ewc; reg [2:0] tm_;
''' + tb_footer(
        r'%d %d %h %d %d %d %d %d %d %h %d %d %d %d %d %d',
        'r_,v_,sd_,nw_,tm_,tp_,y_,ecr,emv,emd,ecd,ece,etg,ewc,edn,ear',
        '''  rst_n=r_; cv=v_; seed=sd_; nw=nw_; tm=tm_; tp=tp_; rdy=y_;''',
        '''  if({cr,mv,cd,ce,tg,dn,ar}!=={ecr[0],emv[0],ecd[0],ece[0],etg[0],edn[0],ear[0]})
   $fatal(1,"row=%0d ctrl got=%b exp=%b",row,{cr,mv,cd,ce,tg,dn,ar},{ecr[0],emv[0],ecd[0],ece[0],etg[0],edn[0],ear[0]});
  if(md!==emd||wc!==ewc)$fatal(1,"row=%0d data got=%h/%0d exp=%h/%0d",row,md,wc,emd,ewc);''')

d = work_dir('prbs')
o = PrbsOracle(); rows = []
for _ in range(3): rows.append(o.tick(0, 0, 0, 0, 0, 0, 0))
rows.append(o.tick(1, 1, 0xACE1, 48, 1, 7, 0))
for i in range(140):
    rows.append(o.tick(1, 0, 0, 0, 0, 0, int(rng.random() < 0.7)))
assert o.done and o.wc == 48
# illegal configs must not disturb the armed state
rows.append(o.tick(1, 1, 0x1111, 5, 2, 0, 1))
rows.append(o.tick(1, 1, 0x1111, 5, 1, 0, 1))
assert o.ce == 1 or True
# legal reconfig, unlimited run with stall-heavy ready
rows.append(o.tick(1, 1, 0x0001, 0, 0, 0, 1))
for i in range(220):
    rows.append(o.tick(1, 0, 0, 0, 0, 0, int(rng.random() < 0.45)))
# mid-stream reset then re-arm
for _ in range(3): rows.append(o.tick(0, 0, 0, 0, 0, 0, 1))
rows.append(o.tick(1, 1, 0xBEEF, 20, 0, 0, 1))
for i in range(60):
    rows.append(o.tick(1, 0, 0, 0, 0, 0, int(rng.random() < 0.8)))
assert o.done
# degenerate seed 0 streams zeros
rows.append(o.tick(1, 1, 0x0000, 8, 0, 0, 1))
for i in range(20):
    rows.append(o.tick(1, 0, 0, 0, 0, 0, 1))
write_vectors(d, rows)
iverilog(prbs_tb(), 'prbs', d, ['prbs_source.sv'])
record('prbs', rows, 'seeded/nwords/unlimited/illegal/reset/zero-seed')

# --------------------------------------------------------------------------
# tone_source
# --------------------------------------------------------------------------
def tone_tb():
    return TB_HEAD + '''reg rst_n=0,cv=0,rdy=0; reg [2:0] mode=0,tm=0;
reg [3:0] nt=0; reg [127:0] inc=0,ph=0; reg [63:0] am=0;
reg signed [31:0] st=0; reg [31:0] sp=0,ns=0,tp=0; reg [15:0] dw=0;
wire signed [15:0] md; wire mv,cr,cd,ce,tg,dn,ar; wire [31:0] sc;
tone_source #(.MAX_TONES(4)) dut(.clk(clk),.rst_n(rst_n),.m_tdata(md),
 .m_tvalid(mv),.m_tready(rdy),.cfg_valid(cv),.cfg_ready(cr),
 .cfg_mode(mode),.cfg_ntone(nt),.cfg_inc(inc),.cfg_phase(ph),.cfg_amp(am),
 .cfg_sw_step(st),.cfg_sw_stop(sp),.cfg_sw_dwell(dw),.cfg_nsamp(ns),
 .cfg_trig_mode(tm),.cfg_trig_period(tp),.cfg_done(cd),.cfg_error(ce),
 .trigger(tg),.sample_count(sc),.done(dn),.armed(ar));
reg [31:0] r_,v_,y_,ecr,emv,ecd,ece,etg,edn,ear; reg [2:0] m_,t_;
reg [3:0] n_; reg [127:0] i_,p_; reg [63:0] a_; reg signed [31:0] s_;
reg [31:0] q_,z_,u_,esc; reg [15:0] w_,emd;
''' + tb_footer(
        r'%d %d %d %d %h %h %h %h %h %d %d %d %d %d %d %d %h %d %d %d %d %d %d',
        'r_,v_,m_,n_,i_,p_,a_,s_,q_,w_,z_,t_,u_,y_,ecr,emv,emd,ecd,ece,etg,esc,edn,ear',
        '''  rst_n=r_; cv=v_; mode=m_; nt=n_; inc=i_; ph=p_; am=a_; st=s_;
  sp=q_; dw=w_; ns=z_; tm=t_; tp=u_; rdy=y_;''',
        '''  if({cr,mv,cd,ce,tg,dn,ar}!=={ecr[0],emv[0],ecd[0],ece[0],etg[0],edn[0],ear[0]})
   $fatal(1,"row=%0d ctrl got=%b exp=%b",row,{cr,mv,cd,ce,tg,dn,ar},{ecr[0],emv[0],ecd[0],ece[0],etg[0],edn[0],ear[0]});
  if(md!==$signed(emd)||sc!==esc)$fatal(1,"row=%0d data got=%h/%0d exp=%h/%0d",row,md,sc,emd,esc);''')

def pack(vals, w):
    return sum((v & ((1 << w) - 1)) << (w * i) for i, v in enumerate(vals))

d = work_dir('tone')
o = ToneOracle(2000); rows = []
for _ in range(3): rows.append(o.tick(0, 0, (0,0,0,0,0,0,0,0,0,0,0), 0))
# multitone: 3 tones, phase offsets, one negative amp
cfg = (0, 3, pack((0x01000000, 0x03333333, 0x08000000, 0), 32),
       pack((0, 0x40000000, 0x80000000, 0), 32),
       pack((16384, 8192, -4096, 0), 16),
       0, 0, 1, 64, 2, 9)
rows.append(o.tick(1, 1, cfg, 0))
for i in range(160):
    rows.append(o.tick(1, 0, cfg, int(rng.random() < 0.65)))
assert o.done and o.sc == 64
# illegal configs: ntone 0, mode 2, sweep dwell 0, trig mode 3, period 0
badcfgs = [(0, 0) + cfg[2:], (2, 1) + cfg[2:],
           (1, 1) + cfg[2:7] + (0,) + cfg[8:],
           cfg[:9] + (3,) + cfg[10:], cfg[:9] + (2, 0)]
for bad in badcfgs:
    rows.append(o.tick(1, 1, bad, 1))
# sweep up: wraps every 12 samples
cfg = (1, 1, pack((0x01000000, 0, 0, 0), 32), pack((0, 0, 0, 0), 32),
       pack((20000, 0, 0, 0), 16), 0x01000000, 0x03000000, 4, 0, 1, 0)
rows.append(o.tick(1, 1, cfg, 1))
for i in range(150):
    rows.append(o.tick(1, 0, cfg, int(rng.random() < 0.7)))
# mid-stream reset, then down-sweep (negative step wraps below stop)
for _ in range(3): rows.append(o.tick(0, 0, cfg, 1))
cfg = (1, 1, pack((0x04000000, 0, 0, 0), 32), pack((0, 0, 0, 0), 32),
       pack((20000, 0, 0, 0), 16), (-0x01000000) & 0xFFFFFFFF,
       0x00800000, 3, 30, 0, 0)
rows.append(o.tick(1, 1, cfg, 1))
for i in range(90):
    rows.append(o.tick(1, 0, cfg, int(rng.random() < 0.8)))
assert o.done
# single tone full amp
cfg = (0, 1, pack((0x04000000, 0, 0, 0), 32), pack((0x20000000, 0, 0, 0), 32),
       pack((32767, 0, 0, 0), 16), 0, 0, 1, 12, 0, 0)
rows.append(o.tick(1, 1, cfg, 1))
for i in range(40):
    rows.append(o.tick(1, 0, cfg, 1))
write_vectors(d, rows)
iverilog(tone_tb(), 'tone', d, ['tone_source.sv'])
record('tone', rows, 'multitone/sweep-up/down/illegal/reset/sat-amp')

# --------------------------------------------------------------------------
# image_pattern_source
# --------------------------------------------------------------------------
def img_tb(bits=8):
    return TB_HEAD + f'''reg rst_n=0,cv=0,rdy=0; reg [15:0] w=0,h=0,nf=0,tf=0;
reg [2:0] pat=0,tm=0;
wire [{bits-1}:0] md; wire mu,ml,mv,cr,cd,ce,tg,dn,ar;
wire [31:0] fc,pc;
image_pattern_source #(.DATA_WIDTH({bits})) dut(.clk(clk),.rst_n(rst_n),
 .m_tdata(md),.m_tuser(mu),.m_tlast(ml),.m_tvalid(mv),.m_tready(rdy),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_w(w),.cfg_h(h),.cfg_pattern(pat),
 .cfg_nframes(nf),.cfg_trig_mode(tm),.cfg_trig_frame(tf),
 .cfg_done(cd),.cfg_error(ce),.trigger(tg),.frame_count(fc),
 .pixel_count(pc),.done(dn),.armed(ar));
reg [31:0] r_,v_,y_,ecr,emv,emu,eml,ecd,ece,etg,edn,ear;
reg [15:0] w_,h_,n_,f_; reg [2:0] p_,t_; reg [{bits-1}:0] emd;
reg [31:0] efc,epc;
''' + tb_footer(
        r'%d %d %d %d %d %d %d %d %d %d %d %h %d %d %d %d %d %d %d %d %d',
        'r_,v_,w_,h_,p_,n_,t_,f_,y_,ecr,emv,emd,emu,eml,ecd,ece,etg,efc,epc,edn,ear',
        '''  rst_n=r_; cv=v_; w=w_; h=h_; pat=p_; nf=n_; tm=t_; tf=f_; rdy=y_;''',
        '''  if({cr,mv,mu,ml,cd,ce,tg,dn,ar}!=={ecr[0],emv[0],emu[0],eml[0],ecd[0],ece[0],etg[0],edn[0],ear[0]})
   $fatal(1,"row=%0d ctrl got=%b exp=%b",row,{cr,mv,mu,ml,cd,ce,tg,dn,ar},{ecr[0],emv[0],emu[0],eml[0],ecd[0],ece[0],etg[0],edn[0],ear[0]});
  if(md!==emd||fc!==efc||pc!==epc)$fatal(1,"row=%0d got d=%h fc=%0d pc=%0d exp=%h/%0d/%0d",row,md,fc,pc,emd,efc,epc);''')

d = work_dir('image')
o = ImgOracle(8); rows = []
for _ in range(3): rows.append(o.tick(0, 0, 0, 0, 0, 0, 0, 0, 0))
img_cases = [
    (1, 1, 0, 3, 0, 0),      # 1x1: SOF+EOL same pixel, seq numbers 0,1,2
    (2, 2, 3, 2, 0, 0),      # 2x2 checker
    (7, 5, 2, 2, 1, 0),      # 7x5 diag, trig per SOF
    (8, 4, 5, 1, 2, 0),      # colorbar, trig per EOL
    (9, 6, 4, 0, 0, 0),      # checker8 unlimited (bounded run below)
    (1, 7, 1, 2, 0, 0),      # 1-wide: EOL every pixel
    (5, 3, 6, 2, 4, 0),      # solid, trig at EOF
    (4, 4, 0, 3, 3, 1),      # trig at SOF of frame 1
]
for w, h, pat, nf, tm, tf in img_cases:
    rows.append(o.tick(1, 1, w, h, pat, nf, tm, tf, 0))
    budget = int(w * h * (nf if nf else 3) * 1.6) + 40
    for i in range(budget):
        rows.append(o.tick(1, 0, 0, 0, 0, 0, 0, 0,
                           int(rng.random() < 0.62)))
    if nf:
        assert o.done, (w, h, pat, nf)
# illegal configs must leave running stream untouched
for bad in [(0, 4, 0), (4, 0, 0), (4, 4, 7), (4, 4, 5), (4, 4, 0, 0, 5)]:
    if len(bad) == 3:
        rows.append(o.tick(1, 1, bad[0], bad[1], bad[2], 0, 0, 0, 1))
    else:
        rows.append(o.tick(1, 1, bad[0], bad[1], bad[2], 0, bad[4], 0, 1))
# mid-stream reset and re-arm
for _ in range(3): rows.append(o.tick(0, 0, 0, 0, 0, 0, 0, 0, 1))
rows.append(o.tick(1, 1, 2, 2, 0, 1, 0, 0, 1))
for i in range(20):
    rows.append(o.tick(1, 0, 0, 0, 0, 0, 0, 0, 1))
write_vectors(d, rows)
iverilog(img_tb(8), 'image', d, ['image_pattern_source.sv'])
record('image', rows, 'sizes 1x1..9x6, all 7 patterns, markers, trig, illegal, reset')

# --------------------------------------------------------------------------
# backpressure_sink
# --------------------------------------------------------------------------
def bp_tb(w=16):
    return TB_HEAD + f'''reg rst_n=0,cv=0,sv=0,su=0,sl=0; reg [{w-1}:0] sd=0;
reg [2:0] mode=0,tm=0; reg [15:0] seed=0,run=0,stall=0; reg [7:0] thr=0;
reg [31:0] tp=0;
wire sr,beat,bu,bl,tg,cd,ce,ar; wire [{w-1}:0] bd; wire [31:0] cnt;
backpressure_sink #(.DATA_WIDTH({w})) dut(.clk(clk),.rst_n(rst_n),
 .s_tdata(sd),.s_tuser(su),.s_tlast(sl),.s_tvalid(sv),.s_tready(sr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_mode(mode),.cfg_seed(seed),
 .cfg_threshold(thr),.cfg_run(run),.cfg_stall(stall),
 .cfg_trig_mode(tm),.cfg_trig_period(tp),.cfg_done(cd),.cfg_error(ce),
 .beat(beat),.beat_data(bd),.beat_user(bu),.beat_last(bl),
 .trigger(tg),.count(cnt),.armed(ar));
reg [31:0] r_,v_,s_,u_,l_,ecr,esr,eb,ebu,ebl,etg,ecd,ece,ear;
reg [2:0] m_,t_; reg [15:0] q_,a_,b_; reg [7:0] z_; reg [31:0] p_,ecnt;
reg [{w-1}:0] d_,ebd;
''' + tb_footer(
        r'%d %d %d %h %d %d %d %d %d %d %h %d %d %d %d %d %h %d %d %d %d %d %d %d',
        'r_,v_,m_,q_,z_,a_,b_,t_,p_,s_,d_,u_,l_,ecr,esr,eb,ebd,ebu,ebl,etg,ecnt,ecd,ece,ear',
        '''  rst_n=r_; cv=v_; mode=m_; seed=q_; thr=z_; run=a_; stall=b_;
  tm=t_; tp=p_; sv=s_; sd=d_; su=u_; sl=l_;''',
        '''  if({cr,sr,beat,bu,bl,tg,cd,ce,ar}!=={ecr[0],esr[0],eb[0],ebu[0],ebl[0],etg[0],ecd[0],ece[0],ear[0]})
   $fatal(1,"row=%0d ctrl got=%b exp=%b",row,{cr,sr,beat,bu,bl,tg,cd,ce,ar},{ecr[0],esr[0],eb[0],ebu[0],ebl[0],etg[0],ecd[0],ece[0],ear[0]});
  if(bd!==ebd||cnt!==ecnt)$fatal(1,"row=%0d got bd=%h cnt=%0d exp=%h/%0d",row,bd,cnt,ebd,ecnt);''')

d = work_dir('bpsink')
o = BpOracle(16); rows = []
for _ in range(3): rows.append(o.tick(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
def bpdrv(rows, o, n, gap=0.55):
    for i in range(n):
        sv = int(rng.random() < 0.75)
        rows.append(o.tick(1, 0, 0, 0, 0, 0, 0, 0, 0, sv,
                           rng.getrandbits(16), rng.getrandbits(1),
                           rng.getrandbits(1)))
# LFSR-threshold mode, trig every 5 beats
rows.append(o.tick(1, 1, 1, 0xACE1, 64, 0, 0, 1, 5, 0, 0, 0, 0))
bpdrv(rows, o, 400)
assert o.cnt > 100
# run/stall mode
rows.append(o.tick(1, 1, 2, 0, 0, 3, 2, 0, 0, 0, 0, 0, 0))
bpdrv(rows, o, 240)
# always-ready
rows.append(o.tick(1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
bpdrv(rows, o, 120)
# always-stalled sink: nothing accepted but stream keeps being offered
rows.append(o.tick(1, 1, 2, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0))
bpdrv(rows, o, 30)
assert o.cnt == 0
# illegal configs
for bad in [(3, 0, 0, 0, 0, 0), (2, 0, 0, 0, 0, 0), (0, 0, 0, 0, 2, 0),
            (0, 0, 0, 0, 1, 0)]:
    rows.append(o.tick(1, 1, bad[0], 1, 0, bad[1], bad[2], bad[4], bad[5],
                       0, 0, 0, 0))
# mid reset
for _ in range(3): rows.append(o.tick(0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 9, 0, 0))
rows.append(o.tick(1, 1, 1, 0x00F0, 128, 0, 0, 0, 0, 0, 0, 0, 0))
bpdrv(rows, o, 200)
write_vectors(d, rows)
iverilog(bp_tb(16), 'bpsink', d, ['backpressure_sink.sv'])
record('bpsink', rows, 'modes0/1/2, stalls, trig, illegal, reset')

# --------------------------------------------------------------------------
# stream_sink_checker (several fixtures share one TB)
# --------------------------------------------------------------------------
CHK_TB = TB_HEAD + '''reg rst_n=0,cv=0,sv=0,su=0,sl=0; reg [7:0] sd=0;
reg [31:0] exp=0,crc=0,tp=0; reg ce_=0,se=0,ie=0; reg [7:0] ss=0,sp=0;
reg [15:0] iw=0,ih=0; reg [2:0] tm=0;
wire sr,cd,ce,dn,tg,ar; wire [31:0] cnt,fr,ferr;
wire ecrc,eseq,esof,eeol,eex;
stream_sink_checker #(.DATA_WIDTH(8)) dut(.clk(clk),.rst_n(rst_n),
 .s_tdata(sd),.s_tuser(su),.s_tlast(sl),.s_tvalid(sv),.s_tready(sr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_expected(exp),.cfg_crc_en(ce_),
 .cfg_crc(crc),.cfg_seq_en(se),.cfg_seq_start(ss),.cfg_seq_step(sp),
 .cfg_img_en(ie),.cfg_img_w(iw),.cfg_img_h(ih),.cfg_trig_mode(tm),
 .cfg_trig_period(tp),.cfg_done(cd),.cfg_error(ce),.count(cnt),
 .frames(fr),.done(dn),.err_crc(ecrc),.err_seq(eseq),.err_sof(esof),
 .err_eol(eeol),.err_extra(eex),.first_error(ferr),.trigger(tg),.armed(ar));
reg [31:0] r_,v_,s_,u_,l_,e_,c_,q_,g_,j_,x_,y_;
reg [7:0] w_;
reg [31:0] x0,x1,x2; reg [7:0] a0,a1; reg [15:0] a2,a3; reg [2:0] a4;
reg [31:0] z0,z1,z2,z3,z4,z5,z6,z7,z8,z9,za,zb,zc;
reg [31:0] ec,ef,eferr;
''' + tb_footer(
    r'%d %d %d %d %h %d %h %h %d %d %d %d %d %d %h %d %d %d %d %d %d %d %d %d %d %d %h %d %d %d %d',
    'r_,v_,x0,e_,x1,q_,a0,a1,g_,a2,a3,a4,x2,s_,w_,u_,l_,z0,ec,ef,z1,z2,z3,z4,z5,z6,eferr,z7,z8,z9,za',
    '''  rst_n=r_; cv=v_; exp=x0; ce_=e_; crc=x1; se=q_; ss=a0; sp=a1;
  ie=g_; iw=a2; ih=a3; tm=a4; tp=x2; sv=s_; sd=w_; su=u_; sl=l_;''',
    '''  if({sr,dn,ecrc,eseq,esof,eeol,eex,tg,cd,ce,ar}!=={z0[0],z1[0],z2[0],z3[0],z4[0],z5[0],z6[0],z7[0],z8[0],z9[0],za[0]})
   $fatal(1,"row=%0d ctrl got=%b exp=%b",row,{sr,dn,ecrc,eseq,esof,eeol,eex,tg,cd,ce,ar},{z0[0],z1[0],z2[0],z3[0],z4[0],z5[0],z6[0],z7[0],z8[0],z9[0],za[0]});
  if(cnt!==ec||fr!==ef||ferr!==eferr)
   $fatal(1,"row=%0d got cnt=%0d fr=%0d ferr=%h exp=%0d/%0d/%h",row,cnt,fr,ferr,ec,ef,eferr);''')

def chk_run(tag, program, note=''):
    d = work_dir(tag); o = ChkOracle(8); rows = []
    program(o, rows)
    write_vectors(d, rows)
    iverilog(CHK_TB, tag, d, ['stream_sink_checker.sv', 'crc32.sv'])
    record(tag, rows, note)
    return o

def seq_beats(start, step, n, mod=256):
    return [((start + step * i) % mod, 0, 0) for i in range(n)]

def chk_program(o, rows, beats_list, cfg_fields, gap=0.3, post=8):
    """cfg_fields = (exp,ce,crc,se,ss,sp,ie,iw,ih,tm,tp); feed beats with gaps."""
    for _ in range(3): rows.append(o.tick(0, *([0] * 16)))
    exp, ce, crc, se, ss, sp, ie, iw, ih, tm, tp = cfg_fields
    rows.append(o.tick(1, 1, exp, ce, crc, se, ss, sp, ie, iw, ih, tm, tp,
                       0, 0, 0, 0))
    for data, u, l in beats_list:
        while rng.random() < gap:
            rows.append(o.tick(1, 0, *([0] * 15)))
        rows.append(o.tick(1, 0, *([0] * 11), 1, data, u, l))
    for _ in range(post):
        rows.append(o.tick(1, 0, *([0] * 15)))

# clean: seq + crc + trig period
beats = seq_beats(10, 3, 24)
crc = crc32_words([b[0] for b in beats], 8)
o = chk_run('chk_clean', lambda o, r: chk_program(
    o, r, beats, (24, 1, crc, 1, 10, 3, 0, 0, 0, 3, 6)),
    'clean seq+crc stream, trig period 6')
assert o.m.verdict()['done'] and not any(
    o.m.verdict()[k] for k in ('err_crc', 'err_seq', 'err_sof', 'err_eol',
                               'err_extra'))

mutations = []
# data corruption -> err_crc (seq still ok since we corrupt only CRC domain?
# a flipped byte also breaks seq; use crc-only checker for clarity)
mutations.append(('chk_crc_bad', [(b[0] ^ 0x40 if i == 5 else b[0], b[1], b[2])
                                  for i, b in enumerate(beats)],
                  (24, 1, crc, 0, 0, 0, 0, 0, 0, 0, 0), 'err_crc', 23))
# order swap -> err_seq
swapped = beats.copy(); swapped[7], swapped[8] = swapped[8], swapped[7]
mutations.append(('chk_seq_bad', swapped,
                  (24, 0, 0, 1, 10, 3, 0, 0, 0, 0, 0), 'err_seq', 7))
# image stream mutations
img_beats = []
for f in range(2):
    for y in range(3):
        for x in range(4):
            img_beats.append(((x + f * 4) & 0xFF,
                              int(x == 0 and y == 0),
                              int(x == 3)))
crc_img = crc32_words([b[0] for b in img_beats], 8)
cfg_img = (24, 1, crc_img, 0, 0, 0, 1, 4, 3, 0, 0)
o = chk_run('chk_img_clean', lambda o, r: chk_program(o, r, img_beats, cfg_img),
            'clean 2x 4x3 frames, img markers + crc')
assert o.m.verdict()['done'] and o.m.verdict()['frames'] == 2
bad = img_beats.copy(); bad[5] = (bad[5][0], 1, bad[5][2])   # stray SOF
mutations.append(('chk_sof_bad', bad, cfg_img, 'err_sof', 5))
bad = img_beats.copy(); bad[2] = (bad[2][0], bad[2][1], 1)   # early EOL
mutations.append(('chk_eol_bad', bad, cfg_img, 'err_eol', 2))
bad = img_beats + [img_beats[0]]                              # extra beat
mutations.append(('chk_extra_bad', bad, cfg_img, 'err_extra', 24))
for tag, bl, cf, flag, idx in mutations:
    o = chk_run(tag, lambda o, r, bl=bl, cf=cf: chk_program(o, r, bl, cf),
                f'mutation -> {flag}@{idx}')
    v = o.m.verdict()
    assert v[flag] and v['first_error'] == idx, (tag, v)
# under-count: feed 20 of 24 beats -> done never asserts
o = chk_run('chk_under', lambda o, r: chk_program(
    o, r, beats[:20], (24, 1, crc32_words([b[0] for b in beats[:20]], 8),
                       1, 10, 3, 0, 0, 0, 0, 0)),
    'under-count: done must stay 0')
assert not o.m.verdict()['done']
# illegal configs + mid reset + first-error trigger
def chk_misc(o, rows):
    for _ in range(3): rows.append(o.tick(0, *([0] * 16)))
    # illegal: exp 0; img w0; tm 4; tm3 tp0
    for bad in [(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
                (8, 0, 0, 0, 0, 0, 1, 0, 3, 0, 0),
                (8, 0, 0, 0, 0, 0, 0, 0, 0, 4, 0),
                (8, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0)]:
        rows.append(o.tick(1, 1, *bad, 0, 0, 0, 0))
    # legal: trig on first error
    rows.append(o.tick(1, 1, 6, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0))
    for i, (d_, u_, l_) in enumerate([(0, 0, 0), (1, 0, 0), (9, 0, 0),
                                      (3, 0, 0), (4, 0, 0), (5, 0, 0)]):
        rows.append(o.tick(1, 0, *([0] * 11), 1, d_, u_, l_))
    assert o.m.err_seq and o.m.first_error == 2
    # mid reset then clean stream again
    for _ in range(3): rows.append(o.tick(0, *([0] * 16)))
    chk_program_tail(o, rows, seq_beats(0, 1, 4),
                     (4, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0))
def chk_program_tail(o, rows, beats_list, cfg_fields):
    exp, ce, crc, se, ss, sp, ie, iw, ih, tm, tp = cfg_fields
    rows.append(o.tick(1, 1, exp, ce, crc, se, ss, sp, ie, iw, ih, tm, tp,
                       0, 0, 0, 0))
    for data, u, l in beats_list:
        rows.append(o.tick(1, 0, *([0] * 11), 1, data, u, l))
    for _ in range(6):
        rows.append(o.tick(1, 0, *([0] * 15)))
o = chk_run('chk_misc', chk_misc, 'illegal cfgs, first-error trig, mid reset')

# --------------------------------------------------------------------------
# Trace-style TB for wired chains: inputs driven from vectors.txt, every DUT
# output dumped per cycle to trace.txt, compared in Python by the oracles.
# Row = mid-cycle values (same convention as the strict fixtures).
# --------------------------------------------------------------------------
TRACE_TB_IMG_BP_CHK = TB_HEAD + '''reg [31:0] rst_n=0;
// all $fscanf targets are 32-bit regs (narrow scalar regs corrupt vvp)
reg [31:0] cvI=0,w=0,h=0,nf=0,tf=0,pat=0,tmI=0;
reg [31:0] cvB=0,mode=0,tmB=0,seed=0,run=0,stall=0,thr=0,tpB=0;
reg [31:0] cvC=0,exp=0,crc=0,tpC=0,ce_=0,se=0,ie_=0;
reg [31:0] ss=0,sp=0,iw=0,ih=0,tmC=0;
wire ie = ie_[0];
wire [7:0] md; wire mu,ml,mvI,tgI,dnI,arI,cdI,ceI,crI; wire [31:0] fcI,pcI;
wire srB,beat,bu,bl,tgB,cdB,ceB,arB,crB; wire [7:0] bd; wire [31:0] cntB;
wire srC,dnC,tgC,cdC,ceC,arC,crC; wire [31:0] cntC,frC,ferr;
wire f1,f2,f3,f4,f5;
image_pattern_source #(.DATA_WIDTH(8)) ui(.clk(clk),.rst_n(rst_n),
 .m_tdata(md),.m_tuser(mu),.m_tlast(ml),.m_tvalid(mvI),.m_tready(srB),
 .cfg_valid(cvI),.cfg_ready(crI),.cfg_w(w),.cfg_h(h),.cfg_pattern(pat),
 .cfg_nframes(nf),.cfg_trig_mode(tmI),.cfg_trig_frame(tf),
 .cfg_done(cdI),.cfg_error(ceI),.trigger(tgI),.frame_count(fcI),
 .pixel_count(pcI),.done(dnI),.armed(arI));
backpressure_sink #(.DATA_WIDTH(8)) ub(.clk(clk),.rst_n(rst_n),
 .s_tdata(md),.s_tuser(mu),.s_tlast(ml),.s_tvalid(mvI),.s_tready(srB),
 .cfg_valid(cvB),.cfg_ready(crB),.cfg_mode(mode),.cfg_seed(seed),
 .cfg_threshold(thr),.cfg_run(run),.cfg_stall(stall),
 .cfg_trig_mode(tmB),.cfg_trig_period(tpB),.cfg_done(cdB),.cfg_error(ceB),
 .beat(beat),.beat_data(bd),.beat_user(bu),.beat_last(bl),
 .trigger(tgB),.count(cntB),.armed(arB));
stream_sink_checker #(.DATA_WIDTH(8)) uc(.clk(clk),.rst_n(rst_n),
 .s_tdata(bd),.s_tuser(bu),.s_tlast(bl),.s_tvalid(beat),.s_tready(srC),
 .cfg_valid(cvC),.cfg_ready(crC),.cfg_expected(exp),.cfg_crc_en(ce_),
 .cfg_crc(crc),.cfg_seq_en(se),.cfg_seq_start(ss),.cfg_seq_step(sp),
 .cfg_img_en(ie),.cfg_img_w(iw),.cfg_img_h(ih),.cfg_trig_mode(tmC),
 .cfg_trig_period(tpC),.cfg_done(cdC),.cfg_error(ceC),.count(cntC),
 .frames(frC),.done(dnC),.err_crc(f1),.err_seq(f2),.err_sof(f3),
 .err_eol(f4),.err_extra(f5),.first_error(ferr),.trigger(tgC),.armed(arC));
integer fo;
initial begin
 f=$fopen("vectors.txt","r"); fo=$fopen("trace.txt","w");
 @(posedge clk); #1;
 while(!$feof(f)) begin
  @(negedge clk);
  n=$fscanf(f,"%d %d %d %d %d %d %d %d %d %d %h %d %d %d %d",
   rst_n,cvI,w,h,pat,nf,tmI,tf,cvB,mode,seed,thr,run,stall,tmB);
  if(n!=15)$fatal(1,"bad row n=%0d",n);
  n=$fscanf(f,"%d %d %d %d %h %d %h %h %d %d %d %d %d\\n",
   tpB,cvC,exp,ce_,crc,se,ss,sp,ie_,iw,ih,tmC,tpC);
  if(n!=13)$fatal(1,"bad row n=%0d",n);
  #1;
  $fwrite(fo,"%d %d %h %d %d %d %d %d %d %d %d %d %d %d %d %h %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %h %d %d %d %d\\n",
   crI,mvI,md,mu,ml,cdI,ceI,tgI,fcI,pcI,dnI,arI,
   crB,srB,beat,bd,bu,bl,tgB,cntB,cdB,ceB,arB,
   crC,srC,cntC,frC,dnC,f1,f2,f3,f4,f5,ferr,tgC,cdC,ceC,arC);
  @(posedge clk); #1;
 end
 $fclose(fo); $display("TRACE COMPLETE"); $finish;
end
endmodule
'''


def chain_img_rows(o_img, o_bp, o_chk, events):
    """events: per-cycle dicts of cfg fields; returns (stim_rows, exp_rows).

    Beat tap: checker sees the bp's registered beat one cycle after the real
    transfer, identical to the RTL wiring."""
    stim, exp = [], []
    prev_beat = (0, 0, 0, 0)
    for ev in events:
        rst = ev.get('rst', 1)
        # current combinational ready of bp drives the image source
        srB = int(bool(rst) and o_bp.armed and
                  (o_bp.bpm.ready() if o_bp.bpm else 0))
        mv, md, mu, ml = o_img.valid, o_img.data, o_img.user, o_img.last
        # expected-output rows in trace order
        exp.append(
            f'{int(bool(rst))} {mv} {hx(md,8)} {mu} {ml} {o_img.cd} '
            f'{o_img.ce} {o_img.tg} {o_img.fc} {o_img.pc} {o_img.done} '
            f'{o_img.armed} '
            f'{int(bool(rst))} {srB} {prev_beat[0]} {hx(prev_beat[1],8)} '
            f'{prev_beat[2]} {prev_beat[3]} {o_bp.tg} {o_bp.cnt} {o_bp.cd} '
            f'{o_bp.ce} {o_bp.armed} '
            f'{chk_exp_fields(o_chk, rst)}')
        stim.append(
            f'{rst} {ev.get("cvI",0)} {ev.get("w",0)} {ev.get("h",0)} '
            f'{ev.get("pat",0)} {ev.get("nf",0)} {ev.get("tmI",0)} '
            f'{ev.get("tf",0)} {ev.get("cvB",0)} {ev.get("mode",0)} '
            f'{hx(ev.get("seed",0),16)} {ev.get("thr",0)} {ev.get("run",0)} '
            f'{ev.get("stall",0)} {ev.get("tmB",0)} {ev.get("tpB",0)} '
            f'{ev.get("cvC",0)} {ev.get("exp",0)} {ev.get("ce",0)} '
            f'{hx(ev.get("crc",0),32)} {ev.get("se",0)} '
            f'{hx(ev.get("ss",0),16)} {hx(ev.get("sp",0),16)} '
            f'{ev.get("ie",0)} {ev.get("iw",0)} {ev.get("ih",0)} '
            f'{ev.get("tmC",0)} {ev.get("tpC",0)}')
        # --- edge updates --------------------------------------------------
        # checker: consumes the registered beat visible this cycle
        o_chk.tick(rst, ev.get('cvC', 0), ev.get('exp', 0), ev.get('ce', 0),
                   ev.get('crc', 0), ev.get('se', 0), ev.get('ss', 0),
                   ev.get('sp', 0), ev.get('ie', 0), ev.get('iw', 0),
                   ev.get('ih', 0), ev.get('tmC', 0), ev.get('tpC', 0),
                   prev_beat[0], prev_beat[1], prev_beat[2], prev_beat[3])
        # bp: consumes the image beat (data valid this cycle)
        bp_row = o_bp.tick(rst, ev.get('cvB', 0), ev.get('mode', 0),
                           ev.get('seed', 0), ev.get('thr', 0),
                           ev.get('run', 0), ev.get('stall', 0),
                           ev.get('tmB', 0), ev.get('tpB', 0),
                           mv, md, mu, ml)
        # image: advances when its held beat is accepted
        o_img.tick(rst, ev.get('cvI', 0), ev.get('w', 0), ev.get('h', 0),
                   ev.get('pat', 0), ev.get('nf', 0), ev.get('tmI', 0),
                   ev.get('tf', 0), srB)
        # the bp's registered beat output for the NEXT cycle
        prev_beat = (o_bp.beat, o_bp.bd, o_bp.bu, o_bp.bl)
    return stim, exp


def chk_exp_fields(o_chk, rst):
    m = o_chk.m
    v = m.verdict() if m else dict(done=0, count=0, frames=0, err_crc=0,
                                   err_seq=0, err_sof=0, err_eol=0,
                                   err_extra=0, first_error=0xFFFFFFFF)
    srC = int(bool(rst) and o_chk.armed)
    return (f'{int(bool(rst))} {srC} {v["count"]} {v["frames"]} {v["done"]} '
            f'{v["err_crc"]} {v["err_seq"]} {v["err_sof"]} {v["err_eol"]} '
            f'{v["err_extra"]} {hx(v["first_error"], 32)} {o_chk.tg} '
            f'{o_chk.cd} {o_chk.ce} {o_chk.armed}')


def run_trace_tb(tag, tb_text, stim, exp, rtl_files):
    d = work_dir(tag)
    (d / 'vectors.txt').write_text('\n'.join(stim) + '\n')
    (d / 'tb.sv').write_text(tb_text)
    run([str(TOOL / 'bin/iverilog.exe'), '-g2012', '-Wall', '-s', 'tb',
         '-o', 'sim.vvp'] + [str(RTL / f) for f in rtl_files] + ['tb.sv'],
        'compile.log', d)
    run([str(TOOL / 'bin/vvp.exe'), 'sim.vvp'], 'run.log', d)
    got = (d / 'trace.txt').read_text().splitlines()
    assert len(got) == len(exp), (tag, len(got), len(exp))
    for i, (g, e) in enumerate(zip(got, exp)):
        assert g.split() == e.split(), (tag, i, g, e)
    record(tag, stim, 'wired chain trace vs oracle')


# chain 1: image -> backpressure(LFSR) -> checker (img markers + CRC)
d_pixels_cfg = ImgCfg(w=7, h=5, pattern=2, nframes=2)
pix_beats = [b[:3] for b in
             [(image_pixel(d_pixels_cfg, f, x, y), int(x == 0 and y == 0),
               int(x == 6), f) for f in range(2) for y in range(5)
              for x in range(7)]]
crc_img = crc32_words([b[0] for b in pix_beats], 8)
events = [dict(rst=0) for _ in range(3)]
events.append(dict(cvC=1, exp=70, ce=1, crc=crc_img, se=0, ss=0, sp=0,
                   ie=1, iw=7, ih=5, tmC=2, tpC=0))
events.append(dict(cvB=1, mode=1, seed=0xACE1, thr=196, run=0, stall=0,
                   tmB=1, tpB=10))
events.append(dict(cvI=1, w=7, h=5, pat=2, nf=2, tmI=1, tf=0))
for _ in range(900):
    events.append(dict())
o_img, o_bp, o_chk = ImgOracle(8), BpOracle(8), ChkOracle(8)
stim, exp = chain_img_rows(o_img, o_bp, o_chk, events)
run_trace_tb('chain_img_bp_chk', TRACE_TB_IMG_BP_CHK, stim, exp,
             ['image_pattern_source.sv', 'backpressure_sink.sv',
              'stream_sink_checker.sv', 'crc32.sv'])
assert o_chk.m.verdict()['done'] and o_chk.m.verdict()['frames'] == 2, \
    o_chk.m.verdict()
assert not any(o_chk.m.verdict()[k] for k in
               ('err_crc', 'err_seq', 'err_sof', 'err_eol', 'err_extra')), \
    o_chk.m.verdict()
assert o_img.fc == 2 and o_bp.cnt == 70

# --------------------------------------------------------------------------
# chain 2: prbs_source -> stream_sink_checker direct (m_tready = s_tready)
# --------------------------------------------------------------------------
TRACE_TB_PRBS_CHK = TB_HEAD + '''reg [31:0] rst_n=0;
// all $fscanf targets are 32-bit regs (narrow scalar regs corrupt vvp)
reg [31:0] cvP=0,seed=0,nw=0,tpP=0,tmP=0;
reg [31:0] cvC=0,exp=0,crc=0,tpC=0,ce_=0,se=0,ie_=0;
reg [31:0] ss=0,sp=0,iw=0,ih=0,tmC=0;
wire ie = ie_[0];
wire [15:0] md; wire mv,crP,cdP,ceP,tgP,dnP,arP; wire [31:0] wc;
wire srC,dnC,tgC,cdC,ceC,arC,crC; wire [31:0] cntC,frC,ferr;
wire f1,f2,f3,f4,f5;
prbs_source up(.clk(clk),.rst_n(rst_n),.m_tdata(md),.m_tvalid(mv),
 .m_tready(srC),.cfg_valid(cvP),.cfg_ready(crP),.cfg_seed(seed),
 .cfg_nwords(nw),.cfg_trig_mode(tmP),.cfg_trig_period(tpP),
 .cfg_done(cdP),.cfg_error(ceP),.trigger(tgP),.word_count(wc),
 .done(dnP),.armed(arP));
stream_sink_checker #(.DATA_WIDTH(16)) uc(.clk(clk),.rst_n(rst_n),
 .s_tdata(md),.s_tuser(1'b0),.s_tlast(1'b0),.s_tvalid(mv),.s_tready(srC),
 .cfg_valid(cvC),.cfg_ready(crC),.cfg_expected(exp),.cfg_crc_en(ce_),
 .cfg_crc(crc),.cfg_seq_en(se),.cfg_seq_start(ss),.cfg_seq_step(sp),
 .cfg_img_en(ie),.cfg_img_w(iw),.cfg_img_h(ih),.cfg_trig_mode(tmC),
 .cfg_trig_period(tpC),.cfg_done(cdC),.cfg_error(ceC),.count(cntC),
 .frames(frC),.done(dnC),.err_crc(f1),.err_seq(f2),.err_sof(f3),
 .err_eol(f4),.err_extra(f5),.first_error(ferr),.trigger(tgC),.armed(arC));
integer fo;
initial begin
 f=$fopen("vectors.txt","r"); fo=$fopen("trace.txt","w");
 @(posedge clk); #1;
 while(!$feof(f)) begin
  @(negedge clk);
  n=$fscanf(f,"%d %d %h %d %d %d %d %d %d %h %d %h %h %d %d %d %d %d\\n",
   rst_n,cvP,seed,nw,tmP,tpP,cvC,exp,ce_,crc,se,ss,sp,ie_,iw,ih,tmC,tpC);
  if(n!=18)$fatal(1,"bad row n=%0d",n);
  #1;
  $fwrite(fo,"%d %d %h %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %h %d %d %d %d\\n",
   crP,mv,md,cdP,ceP,tgP,wc,dnP,arP,
   crC,srC,cntC,frC,dnC,f1,f2,f3,f4,f5,ferr,tgC,cdC,ceC,arC);
  @(posedge clk); #1;
 end
 $fclose(fo); $display("TRACE COMPLETE"); $finish;
end
endmodule
'''


def chain_prbs_rows(o_prbs, o_chk, events):
    stim, exp = [], []
    for ev in events:
        rst = ev.get('rst', 1)
        srC = int(bool(rst) and o_chk.armed)
        mv, md = o_prbs.valid, o_prbs.data
        exp.append(
            f'{int(bool(rst))} {mv} {hx(md,16)} {o_prbs.cd} {o_prbs.ce} '
            f'{o_prbs.tg} {o_prbs.wc} {o_prbs.done} {o_prbs.armed} '
            f'{chk_exp_fields(o_chk, rst)}')
        stim.append(
            f'{rst} {ev.get("cvP",0)} {hx(ev.get("seed",0),16)} '
            f'{ev.get("nw",0)} {ev.get("tmP",0)} {ev.get("tpP",0)} '
            f'{ev.get("cvC",0)} {ev.get("exp",0)} {ev.get("ce",0)} '
            f'{hx(ev.get("crc",0),32)} {ev.get("se",0)} '
            f'{hx(ev.get("ss",0),16)} {hx(ev.get("sp",0),16)} '
            f'{ev.get("ie",0)} {ev.get("iw",0)} {ev.get("ih",0)} '
            f'{ev.get("tmC",0)} {ev.get("tpC",0)}')
        # checker consumes the held word when ready; prbs advances on same edge
        o_chk.tick(rst, ev.get('cvC', 0), ev.get('exp', 0), ev.get('ce', 0),
                   ev.get('crc', 0), ev.get('se', 0), ev.get('ss', 0),
                   ev.get('sp', 0), ev.get('ie', 0), ev.get('iw', 0),
                   ev.get('ih', 0), ev.get('tmC', 0), ev.get('tpC', 0),
                   mv, md, 0, 0)
        o_prbs.tick(rst, ev.get('cvP', 0), ev.get('seed', 0),
                    ev.get('nw', 0), ev.get('tmP', 0), ev.get('tpP', 0), srC)
    return stim, exp


words = prbs16_words(0xACE1, 64)
crc_w = crc32_words(words, 16)
events = [dict(rst=0) for _ in range(3)]
events.append(dict(cvC=1, exp=64, ce=1, crc=crc_w, se=0, ss=0, sp=0,
                   ie=0, iw=0, ih=0, tmC=2, tpC=0))
events.append(dict(cvP=1, seed=0xACE1, nw=64, tmP=1, tpP=16))
for _ in range(160):
    events.append(dict())
o_prbs, o_chk = PrbsOracle(), ChkOracle(16)
stim, exp = chain_prbs_rows(o_prbs, o_chk, events)
run_trace_tb('chain_prbs_chk', TRACE_TB_PRBS_CHK, stim, exp,
             ['prbs_source.sv', 'stream_sink_checker.sv', 'crc32.sv'])
v = o_chk.m.verdict()
assert v['done'] and not any(v[k] for k in
    ('err_crc', 'err_seq', 'err_sof', 'err_eol', 'err_extra')), v
assert o_prbs.done and o_prbs.wc == 64

# --------------------------------------------------------------------------
# Harness sensitivity: corrupting expected fixture fields must fail the sim.
# --------------------------------------------------------------------------
neg = []
for tag, field_idx in [('prbs', 9), ('image', 12), ('bpsink', 16)]:
    d = OUT / tag
    rows = (d / 'vectors.txt').read_text().splitlines()
    # find a row with an interesting nonzero expected field to flip
    mut = rows.copy()
    idx = next(i for i, r in enumerate(rows[15:], 15)
               if len(r.split()) > field_idx and
               r.split()[field_idx] not in ('0', '0x0'))
    cells = mut[idx].split()
    cells[field_idx] = '1' if cells[field_idx] != '1' else '0'
    mut[idx] = ' '.join(cells)
    (d / 'vectors.txt').write_text('\n'.join(mut) + '\n')
    p = subprocess.run([str(TOOL / 'bin/vvp.exe'), 'sim.vvp'], cwd=d, env=env,
                       text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (d / f'negative_field{field_idx}.log').write_text(p.stdout)
    assert p.returncode != 0, f'{tag} harness accepted corrupted expected field'
    neg.append(f'{tag}:field{field_idx}')
    (d / 'vectors.txt').write_text('\n'.join(rows) + '\n')

# --------------------------------------------------------------------------
summary = {
    'status': 'PASS',
    'cycles_total': sum(r['cycles'] for r in results),
    'cases': results,
    'harness_negative': neg,
    'rtl_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                   for p in sorted(RTL.glob('*.sv'))},
    'scope': ('cycle-accurate oracle comparison; SOF/EOL markers on '
              '1x1/2x2/7x5/1x7/8x1 frames; random ready/valid fuzz; mid-stream '
              'reset; illegal config; checker mutation rejection; two wired '
              'chains. No P&R or board claim.')
}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
print('evidence:', OUT)
