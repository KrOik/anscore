"""Cycle-accurate RTL verification for DSP-15 lms_stream (serial + parallel).

Conventions follow dsp/statistics/tests/test_rtl.py: an independent Python
oracle replicates the externally visible contract every cycle; a generated
fixture drives inputs at negedge and checks every output; corrupted fixtures
must be rejected.  Deterministic seeds throughout.

Sections:
  1. model sanity: convergence vs float reference, misadjustment vs step,
     saturation, freeze, energy-floor bypass, illegal config rejection.
  2. RTL oracle per implementation (lms_serial FSM, lms_parallel pipeline),
     fixture sims through iverilog covering LMS/NLMS, random valid/ready,
     backpressure, resets, config rewrites incl. illegal taps, cw preload,
     readback sweep, saturation extremes.
  3. dense-stream cross-check of each oracle against the algorithm-level
     FixedLMS model (validates the delayed-commit visibility constant and
     gives II=1 evidence for the parallel core).
  4. negative mutations of the fixture must all fail.

Run:  python cores/signal_processing/dsp_isp_library/dsp/lms/tests/test_lms.py
"""
import os, sys, json, random, shutil, subprocess, hashlib
from pathlib import Path
from datetime import datetime

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
from lms_model import rne, sat, fpdiv_q, ceil_log2, Config, FixedLMS, float_lms

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
OUT = BASE / 'evidence' / ('rtl_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir()
TOOL = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
env['PATH'] = str(TOOL / 'bin') + os.pathsep + str(TOOL / 'lib') + os.pathsep + env['PATH']
DIV = ROOT / 'cores/signal_processing/dsp_isp_library/infra/fixedpoint/rtl/recip_div.sv'
RTL = BASE / 'rtl/lms_stream.sv'
CW = 24


def tool(name):
    p = TOOL / 'bin' / f'{name}.exe'
    return str(p) if p.exists() else shutil.which(name) or name


def sat24(v):
    return sat(v, CW)


def sext(v, w):
    return v - (1 << w) if v >= (1 << (w - 1)) else v


# ============================================================== oracles
class SerOracle:
    """Bit-exact cycle mirror of lms_serial."""
    def __init__(s, ntaps):
        s.N = ntaps
        s.reset_all()

    def reset_all(s):
        s.st = 0; s.k = 0
        s.taps = s.N; s.mu = 0x2000; s.nlms = 0; s.uen = 1; s.floor = 64
        s.coef = [0] * s.N; s.hist = [0] * s.N
        s.d_r = s.y_r = s.e_r = 0; s.t2r = 0; s.gr = 0; s.eden = 0
        s.bp = 0; s.cl = 0; s.acc = 0; s.accE = 0
        s.mv = 0; s.md = 0; s.mu_ = 0
        s.done = 0; s.err = 0; s.rv = 0; s.rd = 0
        s.dst = 0; s.dcnt = 0; s.da = 0; s.db = 0
        s.dmv = 0; s.dq = 0; s.du = 0

    def tick(s, rst, cv, ct, cmu, cn, cu, cf, cc, sv, sd, mr,
             cwe, cwa, cwd, rbe, rba):
        sr = int(rst and s.st == 0 and not cv and (not s.mv or mr))
        cr = int(rst and s.st == 0 and not s.mv)
        out = (sr, cr, s.mv, s.md, s.mu_, s.done, s.err, s.rv, s.rd)
        if not rst:
            s.reset_all()
            return out
        # ---------------- edge ----------------
        s.done = s.err = 0; s.rv = 0
        if rbe:
            s.rv = 1
            s.rd = s.coef[rba] if rba < s.N else 0       # pre-edge read
        if mr:
            s.mv = 0
        if cv and cr:
            s.done = 1
            if ct < 1 or ct > s.N:
                s.err = 1
            else:
                s.taps, s.mu, s.nlms, s.uen, s.floor = ct, cmu, cn, cu, cf
                s.hist = [0] * s.N; s.acc = 0; s.accE = 0
                if cc:
                    s.coef = [0] * s.N
        old_dmv = s.dmv
        st = s.st
        # fp_div_iter mirror: transfer edge -> m_tvalid at +26 (b!=0) / +1 (b==0)
        new_dmv = 0; new_dq = s.dq; new_du = s.du
        if s.dst == 1:
            if s.db == 0 or s.dcnt == 25:
                q, (d0f, clf) = fpdiv_q(s.da, s.db, 8, 20)
                new_dq, new_du, new_dmv = q, (d0f << 1) | clf, 1
                s.dst = 0
            else:
                s.dcnt += 1
        x_in = sext(sd & 0xFFFF, 16); d_in = sext((sd >> 16) & 0xFFFF, 16)
        if st == 0:
            if sv and sr:
                s.d_r = d_in
                s.hist = [x_in] + s.hist[:-1]
                s.acc = 0; s.accE = 0; s.k = 0; s.cl = 0; s.bp = 0
                s.st = 1
        elif st == 1:
            s.acc += s.coef[s.k] * s.hist[s.k]
            if s.k == s.taps - 1:
                s.k = 0; s.st = 2 if s.nlms else 3
            else:
                s.k += 1
        elif st == 2:
            s.accE += s.hist[s.k] * s.hist[s.k]
            if s.k == s.taps - 1:
                s.k = 0; s.st = 3
            else:
                s.k += 1
        elif st == 3:
            y, cy = sat(rne(s.acc, 20), 16)
            e, ce_ = sat(s.d_r - y, 16)
            s.y_r = y; s.e_r = e; s.eden = min(s.accE >> 16, 0xFFFFF)
            s.bp = int(s.nlms and s.eden < max(s.floor, 1))
            s.cl |= cy | ce_
            s.st = 4
        elif st == 4:
            t2, ct2 = sat(rne(s.mu * s.e_r, 15), 18)
            s.t2r = t2; s.cl |= ct2
            if s.nlms and not s.bp and s.uen:
                s.st = 5
            else:
                s.gr = t2 if (s.uen and not s.nlms) else 0
                s.k = 0; s.st = 7
        elif st == 5:
            s.da = s.t2r; s.db = s.eden if s.eden else 1
            s.dst = 1; s.dcnt = 0
            s.st = 6
        elif st == 6:
            if old_dmv:
                s.gr = sext(s.dq & 0xFFFFF, 20)
                s.cl |= (s.du & 1) | ((s.du >> 1) & 1)
                s.k = 0; s.st = 7
        elif st == 7:
            sh = 5 if s.nlms else 11
            nv, cc_ = sat24(s.coef[s.k] + rne(s.gr * s.hist[s.k], sh))
            s.cl |= cc_
            s.coef[s.k] = nv
            if s.k == s.taps - 1:
                s.k = 0; s.st = 8
            else:
                s.k += 1
        elif st == 8:
            s.md = ((s.e_r & 0xFFFF) << 16) | (s.y_r & 0xFFFF)
            s.mu_ = (s.bp << 1) | (s.cl & 1)
            s.mv = 1; s.st = 0
        else:
            s.st = 0
        s.dmv = new_dmv; s.dq = new_dq; s.du = new_du
        if cwe and cwa < s.N:
            s.coef[cwa] = sext(cwd, CW)
        return out


class ParOracle:
    """Bit-exact cycle mirror of lms_parallel (rigid global-enable pipeline)."""
    DMLEN = 27
    DIVN = 26                      # fp_div_pipe N = AW+FB

    def __init__(s, ntaps):
        s.N = ntaps
        s.NL = max(1, ceil_log2(ntaps))
        s.reset_all()

    def reset_all(s):
        N = s.N
        s.taps = N; s.mu = 0x2000; s.nlms = 0; s.uen = 1; s.floor = 64
        s.coef = [0] * N; s.xsh = [0] * N; s.E = 0
        s.v0 = 0; s.xv0 = [0] * N; s.d0 = 0; s.e0 = 0
        s.v1 = 0; s.p1 = [0] * N; s.xv1 = [0] * N; s.d1 = 0; s.ed1 = 0
        s.vt = [0] * s.NL
        s.tr = [[0] * N for _ in range(s.NL)]
        s.xvt = [[0] * N for _ in range(s.NL)]
        s.dt = [0] * s.NL; s.edt = [0] * s.NL
        s.ve = 0; s.y_e = 0; s.e_e = 0; s.xve = [0] * N; s.ede = 0; s.ce = 0
        s.v2 = 0; s.y2 = 0; s.e2 = 0; s.xv2 = [0] * N; s.t22 = 0
        s.eden2 = 0; s.c2 = 0; s.bp2 = 0
        s.dm = [None] * s.DMLEN; s.dmv = [0] * s.DMLEN
        s.items = []
        s.hq = []                       # quotient hold FIFO (depth 32)
        s.dvm = 0; s.dq = 0; s.du = 0
        s.mv = 0; s.md = 0; s.mu_ = 0
        s.done = 0; s.err = 0; s.rv = 0; s.rd = 0

    def tick(s, rst, cv, ct, cmu, cn, cu, cf, cc, sv, sd, mr,
             cwe, cwa, cwd, rbe, rba):
        N = s.N
        adv = int((not s.mv) or mr)
        cbusy = s.v0 or s.v1 or any(s.vt) or s.ve or s.v2 or any(s.dmv)
        sr = int(rst and adv and not cv)
        cr = int(rst and not s.mv and not cbusy)
        out = (sr, cr, s.mv, s.md, s.mu_, s.done, s.err, s.rv, s.rd)
        if not rst:
            s.reset_all()
            return out
        # snapshot pre-edge state used by commit/output this edge
        dvl = s.dmv[-1]; dml = s.dm[-1]
        dvq = s.dq; dvu = s.du
        v2o = s.v2; xv2o = s.xv2; y2o = s.y2; e2o = s.e2
        eden2o = s.eden2; t22o = s.t22; c2o = s.c2; bp2o = s.bp2
        # front-of-queue quotient and commit intent for this edge
        fq_q, fq_u = (s.hq[0] if s.hq else (dvq, dvu))
        commit_e = int(adv and dvl and s.uen and (dml is not None) and
                       not dml['bp'])
        use_q = commit_e and s.nlms
        # ---------------- edge ----------------
        s.done = s.err = 0; s.rv = 0
        if rbe:
            s.rv = 1
            s.rd = s.coef[rba] if rba < N else 0
        if cv and cr:
            s.done = 1
            if ct < 1 or ct > N:
                s.err = 1
            else:
                s.taps, s.mu, s.nlms, s.uen, s.floor = ct, cmu, cn, cu, cf
                s.xsh = [0] * N; s.E = 0
                if cc:
                    s.coef = [0] * N
        if adv:
            # ---- output stage (uses pre-edge dm[-1] + front-of-queue) ----
            s.mv = dvl
            if dvl:
                g_c = sext(fq_q & 0xFFFFF, 20) if s.nlms else \
                    sext(dml['t2'] & 0x3FFFF, 18)
                sh = 5 if s.nlms else 11
                cclip = 0
                if commit_e:
                    for k2 in range(s.taps):
                        _, ccl = sat24(s.coef[k2] + rne(g_c * dml['xv'][k2], sh))
                        cclip |= ccl
                dcl = int(s.nlms and not dml['bp'] and
                          ((fq_u & 1) or (fq_u >> 1)))
                s.md = ((dml['e'] & 0xFFFF) << 16) | (dml['y'] & 0xFFFF)
                s.mu_ = (dml['bp'] << 1) | (dml['c'] | (dcl | cclip if
                        commit_e else 0))
            # ---- divider mirror pipe (high->low, pre-edge source) ----
            for i in range(s.DMLEN - 1, 0, -1):
                s.dmv[i] = s.dmv[i - 1]
                if s.dmv[i - 1]:
                    s.dm[i] = s.dm[i - 1]
            s.dmv[0] = v2o
            if v2o:
                s.dm[0] = {'xv': list(xv2o), 'y': y2o, 'e': e2o,
                           'eden': eden2o, 't2': t22o, 'c': c2o, 'bp': bp2o}
            # ---- quotient queue consumption (pre-edge values) ----
            if use_q:
                assert s.hq or s.dvm, ('NLMS commit with no quotient: '
                                       'queue accounting broken')
            hq_ne = bool(s.hq)
            if use_q:
                if hq_ne:
                    s.hq.pop(0)
                # else: dv output slot consumed directly at this edge
            # dv output retires into hold unless it was consumed in place
            # (use_q with empty hold); use pre-edge hq occupancy
            if s.dvm and not (use_q and not hq_ne):
                s.hq.append((dvq, dvu))
            # ---- divider feed/advance (pre-edge v2; never back-pressured) ----
            hit = [it for it in s.items if it['pos'] == s.DIVN - 1]
            s.items = [it for it in s.items if it['pos'] < s.DIVN - 1]
            for it in s.items:
                it['pos'] += 1
            s.dvm = int(bool(hit))
            if hit:
                q, (d0f, clf) = fpdiv_q(hit[0]['a'], hit[0]['b'], 8, 20)
                s.dq = q; s.du = (d0f << 1) | clf
            if v2o and s.nlms and s.uen and not bp2o:
                s.items.append({'a': t22o, 'b': eden2o if eden2o else 1,
                                'pos': 0})
            # ---- t2 stage ----
            s.v2 = s.ve
            if s.ve:
                t2, ct2 = sat(rne(s.mu * s.e_e, 15), 18)
                s.t22 = t2; s.c2 = s.ce | ct2
                s.bp2 = int(s.nlms and s.ede < max(s.floor, 1))
                s.y2 = s.y_e; s.e2 = s.e_e; s.eden2 = s.ede
                s.xv2 = list(s.xve)
            # ---- error stage ----
            s.ve = s.vt[s.NL - 1]
            if s.vt[s.NL - 1]:
                acc = s.tr[s.NL - 1][0]
                y, cy = sat(rne(acc, 20), 16)
                e, ce_ = sat(s.dt[s.NL - 1] - y, 16)
                s.y_e = y; s.e_e = e; s.ce = cy | ce_
                s.ede = s.edt[s.NL - 1]
                s.xve = list(s.xvt[s.NL - 1])
            # ---- adder tree (high->low so level j-1 is still old) ----
            for j in range(s.NL - 1, -1, -1):
                pv = s.v1 if j == 0 else s.vt[j - 1]
                ps = s.p1 if j == 0 else s.tr[j - 1]
                px = s.xv1 if j == 0 else s.xvt[j - 1]
                pd = s.d1 if j == 0 else s.dt[j - 1]
                pe = s.ed1 if j == 0 else s.edt[j - 1]
                s.vt[j] = pv; s.dt[j] = pd; s.edt[j] = pe
                live_prev = (N + (1 << j) - 1) >> j
                live = (N + (1 << (j + 1)) - 1) >> (j + 1)
                for i in range(live):
                    s.tr[j][i] = ps[2 * i] + (ps[2 * i + 1]
                                            if 2 * i + 1 < live_prev else 0)
                for i in range(N):
                    s.xvt[j][i] = px[i]
            # ---- product stage ----
            s.v1 = s.v0
            if s.v0:
                s.d1 = s.d0; s.ed1 = s.e0
                for i in range(N):
                    s.xv1[i] = s.xv0[i]
                    s.p1[i] = s.coef[i] * s.xv0[i] if i < s.taps else 0
            # ---- accept stage ----
            x_in = sext(sd & 0xFFFF, 16); d_in = sext((sd >> 16) & 0xFFFF, 16)
            acc_ept = sv and sr
            s.v0 = acc_ept
            if acc_ept:
                xl = s.xsh[s.taps - 1]
                s.E = s.E + x_in * x_in - xl * xl
                s.e0 = min(s.E >> 16, 0xFFFFF)
                s.d0 = d_in
                s.xv0 = [x_in] + s.xsh[:-1]
                s.xsh = [x_in] + s.xsh[:-1]
        # ---- coefficient commit edge ----
        if commit_e:
            g_c = sext(fq_q & 0xFFFFF, 20) if s.nlms else \
                sext(dml['t2'] & 0x3FFFF, 18)
            sh = 5 if s.nlms else 11
            for k2 in range(s.taps):
                nv, _ = sat24(s.coef[k2] + rne(g_c * dml['xv'][k2], sh))
                s.coef[k2] = nv
        if cwe and cwa < N:
            s.coef[cwa] = sext(cwd, CW)
        return out


# ============================================================== stimulus
class Plant:
    """Unknown FIR to identify: d[n] = sum h[k] x[n-k] quantized to Q1.15."""
    def __init__(self, h, noise=0.0, seed=7):
        self.h = h; self.noise = noise; self.hist = [0.0] * len(h)
        self.r = random.Random(seed)

    def push(self, x):
        self.hist = [x / 32768.0] + self.hist[:-1]
        y = sum(h * v for h, v in zip(self.h, self.hist))
        y += self.noise * (self.r.random() * 2 - 1)
        v = int(round(y * 32768))
        return min(32767, max(-32768, v))


class Stim:
    """Per-cycle stimulus generator; consumes accept/config-ready feedback."""
    def __init__(s, ntaps, plant=None, cfgseq=(), seed=0x1A5E):
        s.r = random.Random(seed)
        s.N = ntaps; s.plant = plant; s.cfgseq = list(cfgseq)
        s.pend = None; s.ci = 0; s.held = None
        s.stats = {'sent': 0, 'cfg_issued': 0}

    def intent(s, c):
        rst = 0 if (c < 2 or c % 997 == 500) else 1
        if not rst:
            s.held = None
            return dict(rst=0)
        if s.pend is None and s.ci < len(s.cfgseq) and c % 211 == 17:
            s.pend = s.cfgseq[s.ci]; s.ci += 1
        cfg = s.pend or dict(taps=s.N, mu=8192, nlms=0, uen=1, floor=64, clr=0)
        if s.held is None and s.r.random() < 0.8:
            r = s.r.random()
            if r < 0.08:
                x = s.r.choice([-32768, 32767])
                d = s.r.choice([-32768, 32767])
            elif r < 0.25:
                x = s.r.choice([0, 1, -1, 8192, -8192, 32767 // 4])
                d = s.plant.push(x) if s.plant else s.r.randrange(-32768, 32768)
            else:
                x = s.r.randrange(-32768, 32768)
                d = s.plant.push(x) if (s.plant and s.r.random() < 0.9) \
                    else s.r.randrange(-32768, 32768)
            s.held = ((d & 0xFFFF) << 16) | (x & 0xFFFF)
        sv = int(s.held is not None)
        mr = int(s.r.random() < 0.75) if c % 13 else 1
        if c % 89 < 5:
            mr = 0
        return dict(rst=1, cv=int(s.pend is not None), ct=cfg['taps'],
                    cmu=cfg['mu'], cn=cfg['nlms'], cu=cfg['uen'],
                    cf=cfg['floor'], cc=cfg['clr'], sv=sv,
                    sd=s.held or 0, mr=mr,
                    cwe=int(s.r.random() < 0.04), cwa=s.r.randrange(s.N + 2),
                    cwd=s.r.randrange(-(1 << 23), (1 << 23)) & 0xFFFFFF,
                    rbe=int(s.r.random() < 0.3), rba=s.r.randrange(s.N + 2))

    def release(s, sr, cr):
        if s.held is not None and sr:
            s.held = None; s.stats['sent'] += 1
        if s.pend is not None and cr:
            s.pend = None; s.stats['cfg_issued'] += 1


# ============================================================== testbench
TB = '''`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,cv=0,sv=0,mr=0,cwe=0,rbe=0,cn=0,cu=0,cc=0;
reg[6:0] ct=0,cwa=0,rba=0;reg[15:0] cmu=0;reg[19:0] cf=0;
reg[31:0] sd=0;reg[23:0] cwd=0;
wire sr,cr,mv,cd,ce,rv;wire[31:0] md;wire[1:0] mu;wire signed[23:0] rd;
lms_stream #(.NTAPS(NTAPS_P),.IMPL(IMPL_P),.MULT_DSP(1)) dut(
 .clk(clk),.rst_n(rst_n),.s_tdata(sd),.s_tvalid(sv),.s_tready(sr),
 .m_tdata(md),.m_tuser(mu),.m_tvalid(mv),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_taps(ct),.cfg_mu(cmu),.cfg_nlms(cn),
 .cfg_update_en(cu),.cfg_floor(cf),.cfg_coef_clr(cc),.cfg_done(cd),.cfg_error(ce),
 .cw_en(cwe),.cw_addr(cwa),.cw_data(cwd),
 .rb_en(rbe),.rb_addr(rba),.rb_valid(rv),.rb_data(rd));
wire sr2,cr2,mv2,cd2,ce2,rv2;wire[31:0] md2;wire[1:0] mu2;wire signed[23:0] rd2;
lms_stream #(.NTAPS(NTAPS_P),.IMPL(IMPL_P),.MULT_DSP(0)) dut_logic(
 .clk(clk),.rst_n(rst_n),.s_tdata(sd),.s_tvalid(sv),.s_tready(sr2),
 .m_tdata(md2),.m_tuser(mu2),.m_tvalid(mv2),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr2),.cfg_taps(ct),.cfg_mu(cmu),.cfg_nlms(cn),
 .cfg_update_en(cu),.cfg_floor(cf),.cfg_coef_clr(cc),.cfg_done(cd2),.cfg_error(ce2),
 .cw_en(cwe),.cw_addr(cwa),.cw_data(cwd),
 .rb_en(rbe),.rb_addr(rba),.rb_valid(rv2),.rb_data(rd2));
integer f,n,row;
integer rr,vv,tt,muu,nn,uu,ff,ccr,ss,mm,we,wa,re,ra;
integer esr,ecr,emv,emuu,ecd,ece,erv;
reg[31:0] dd,emd;reg[23:0] wd,erd;
initial begin
 f=$fopen("vectors.txt","r");row=0;@(posedge clk);#1;
 while(!$feof(f))begin
  @(negedge clk);
  n=$fscanf(f,"%d %d %d %h %d %d %h %d %d %h %d %d %d %h %d %h %d %d %d %h %d %d %d %d %h\\n",
   rr,vv,tt,muu,nn,uu,ff,ccr,ss,dd,mm,we,wa,wd,re,ra,
   esr,ecr,emv,emd,emuu,ecd,ece,erv,erd);
  if(n!=25)$fatal(1,"fixture row=%0d n=%0d",row,n);
  rst_n=rr;cv=vv;ct=tt;cmu=muu;cn=nn;cu=uu;cf=ff;cc=ccr;sv=ss;sd=dd;mr=mm;
  cwe=we;cwa=wa;cwd=wd;rbe=re;rba=ra;#1;
  if({sr,cr,mv,cd,ce,rv}!=={esr[0],ecr[0],emv[0],ecd[0],ece[0],erv[0]})
    $fatal(1,"ctrl row=%0d got=%b%b%b%b%b%b exp=%b%b%b%b%b%b",row,
     sr,cr,mv,cd,ce,rv,esr,ecr,emv,ecd,ece,erv);
  if(emv && {md,mu}!=={emd,emuu[1:0]})
    $fatal(1,"data row=%0d got=%h/%b exp=%h/%b",row,md,mu,emd,emuu);
  if(erv && rd!==erd)
    $fatal(1,"rb row=%0d got=%h exp=%h",row,rd,erd);
  if({sr2,cr2,mv2,cd2,ce2,rv2}!=={sr,cr,mv,cd,ce,rv})
    $fatal(1,"logic-mult control mismatch row=%0d",row);
  if(mv2 && {md2,mu2}!=={md,mu})
    $fatal(1,"logic-mult data mismatch row=%0d",row);
  @(posedge clk);#1;row=row+1;
 end
 $display("PASS rows=%0d",row);$finish;
end
endmodule
'''

FMT = ('{rst} {cv} {ct} {cmu:x} {cn} {cu} {cf:x} {cc} {sv} {sd:08x} {mr} '
       '{cwe} {cwa} {cwd:06x} {rbe} {rba} {sr} {cr} {mv} {md:08x} {mu} '
       '{cd} {ce} {rv} {rd:06x}')


def run_sim(name, ntaps, impl, stim, cycles):
    """Drive oracle+stimulus, write fixture, compile+run iverilog, negatives."""
    oracle = SerOracle(ntaps) if impl == 0 else ParOracle(ntaps)
    out_rows = []
    stats = dict(accepts=0, outputs=0, cfgs=0, errs=0, resets=0,
                 clips=0, bypasses=0, cfgwait=0, rbreads=0)
    for c in range(cycles):
        st = stim.intent(c)
        rst = st.get('rst', 1); sv = st.get('sv', 0); sd = st.get('sd', 0)
        cv = st.get('cv', 0); ct = st.get('ct', ntaps)
        cmu = st.get('cmu', 8192); cn = st.get('cn', 0); cu = st.get('cu', 1)
        cf = st.get('cf', 64); cc = st.get('cc', 0); mr = st.get('mr', 1)
        cwe = st.get('cwe', 0); cwa = st.get('cwa', 0); cwd = st.get('cwd', 0)
        rbe = st.get('rbe', 0); rba = st.get('rba', 0)
        e = oracle.tick(rst, cv, ct, cmu, cn, cu, cf, cc, sv, sd, mr,
                        cwe, cwa, cwd, rbe, rba)
        sr, cr, mv, md, mu, cd, ce, rv, rd = e
        stim.release(sr, cr)
        stats['accepts'] += int(bool(sv and sr and rst))
        stats['outputs'] += int(bool(mv and mr))
        stats['cfgs'] += cd; stats['errs'] += ce
        stats['resets'] += int(not rst)
        stats['clips'] += int(mv and (mu & 1))
        stats['bypasses'] += int(mv and (mu & 2))
        stats['cfgwait'] += int(cv and not cr)
        stats['rbreads'] += rv
        out_rows.append(FMT.format(rst=rst, cv=cv, ct=ct, cmu=cmu, cn=cn,
                                   cu=cu, cf=cf, cc=cc, sv=sv, sd=sd, mr=mr,
                                   cwe=cwe, cwa=cwa, cwd=cwd, rbe=rbe, rba=rba,
                                   sr=sr, cr=cr, mv=mv, md=md, mu=mu, cd=cd,
                                   ce=ce, rv=rv, rd=rd & 0xFFFFFF))
    d = OUT / name
    d.mkdir()
    fixture = '\n'.join(out_rows) + '\n'
    (d / 'vectors.txt').write_text(fixture)
    (d / 'tb.sv').write_text(
        TB.replace('NTAPS_P', str(ntaps)).replace('IMPL_P', str(impl)))

    def run(cmd, log, fail_ok=False):
        p = subprocess.run(cmd, cwd=d, env=env, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (d / log).write_text(p.stdout)
        if p.returncode and not fail_ok:
            raise RuntimeError(f'{name}/{log} failed:\n{p.stdout[-3000:]}')
        return p.returncode, p.stdout

    run([tool('iverilog'), '-g2012', '-Wall', '-s', 'tb', '-o', 'test.vvp',
         str(RTL), str(DIV), 'tb.sv'], 'compile.log')
    rc, o = run([tool('vvp'), 'test.vvp'], 'run.log')
    assert 'PASS' in o, f'{name}: no PASS line in run.log'
    # ---- negative mutations --------------------------------------------------
    neg = []
    # field indices in the fixture row: 0-15 stimulus, 16-24 expected
    expidx = {'m_tdata': 19, 'm_tuser': 20, 's_tready': 16, 'm_tvalid': 18,
              'cfg_done': 21, 'cfg_error': 22, 'rb_data': 24, 'cfg_ready': 17}
    need = {'m_tdata': (18, '1'), 'm_tuser': (18, '1'), 's_tready': (16, '1'),
            'm_tvalid': (18, '1'), 'cfg_done': (21, '1'), 'cfg_error': (22, '1'),
            'rb_data': (23, '1'), 'cfg_ready': (17, '1')}
    for label, fidx in expidx.items():
        trig, tval = need[label]
        idx = next((i for i, r in enumerate(out_rows)
                    if i > 10 and r.split()[trig] == tval), None)
        assert idx is not None, f'{name}: no trigger row for {label}'
        alt = out_rows.copy()
        cells = alt[idx].split()
        if fidx in (19, 24):
            w = 8 if fidx == 19 else 6
            cells[fidx] = '%0*x' % (w, int(cells[fidx], 16) ^ 0xA5)
        else:
            cells[fidx] = str(1 - int(cells[fidx]))
        alt[idx] = ' '.join(cells)
        (d / 'vectors.txt').write_text('\n'.join(alt) + '\n')
        rc, _ = run([tool('vvp'), 'test.vvp'], f'negative_{label}.log',
                    fail_ok=True)
        assert rc != 0, f'{name}: corrupted {label} not rejected'
        neg.append(label)
    (d / 'vectors.txt').write_text(fixture)
    stats.update(status='PASS', rows=len(out_rows), negatives=neg,
                 impl=impl, ntaps=ntaps, **stim.stats)
    (d / 'summary.json').write_text(json.dumps(stats, indent=2))
    print(f'  {name}: PASS {stats}')
    return stats


# ============================================================== model tests
def model_section():
    rep = {}
    # ---- helpers ----
    assert rne(3, 2) == 1 and rne(5, 2) == 1 and rne(6, 2) == 2
    assert rne(-3, 2) == -1 and rne(-5, 2) == -1 and rne(-6, 2) == -2
    assert fpdiv_q(256, 3, 8, 20)[0] == 21845              # 65536/3 RNE
    assert fpdiv_q(-256, 3, 8, 20)[0] == -21845
    assert fpdiv_q(5, 0, 8, 20)[0] == (1 << 19) - 1        # div0 -> OUT_MAX
    assert fpdiv_q(-5, 0, 8, 20)[0] == -(1 << 19)
    for bad in [dict(taps=0), dict(taps=9, ntaps_max=8), dict(mu=-1),
                dict(floor=1 << 20)]:
        c = Config(**bad)
        assert c.check() is not None, bad
    rep['config_reject'] = 4
    # ---- convergence: identify unknown FIR; serial (vis=1) & parallel ----
    h = [0.5, -0.25, 0.125, -0.0625]
    pr = random.Random(0xC0FFEE)
    xs = [pr.randrange(-20000, 20000) for _ in range(4000)]
    pl = Plant(h, noise=0.001)
    ds = [pl.push(x) for x in xs]
    cfg = Config(taps=4, mu=16384, nlms=1, floor=16, ntaps_max=8)
    cfg_par = Config(taps=4, mu=8192, nlms=1, floor=16, ntaps_max=8)
    # delayed-LMS: parallel commit latency VIS=NL+31 shrinks the stable step
    # range, so the parallel run uses a smaller mu (documented in SPEC.md)
    for name, vis, cfv in (('serial', 1, cfg), ('parallel', 3 + 31, cfg_par)):
        m = FixedLMS(8, vis)
        out = [m.step(x, d, cfv) for x, d in zip(xs, ds)]
        got = [c / 2**20 for c in m.coef[:4]]
        err = max(abs(g - hh) for g, hh in zip(got, h))
        rep[f'conv_{name}_max_weight_err'] = err
        assert err < 0.02, (name, got, err)
        e_first = sum(o['e'] ** 2 for o in out[:200]) / 200
        e_last = sum(o['e'] ** 2 for o in out[-200:]) / 200
        rep[f'conv_{name}_mse_ratio'] = e_first / max(e_last, 1e-12)
        assert e_last * 20 < e_first
    # fixed vs float trajectory bound (same update rule, same floor)
    # eden>=floor <=> E_real >= floor*2^16/2^30 = floor/1024
    fout, fcoef = float_lms([x / 32768 for x in xs],
                            [d / 32768 for d in ds], 8, 16384 / 65536,
                            nlms=1, floor=16 / 1024.0, vis=1)
    m = FixedLMS(8, 1)
    iout = [m.step(x, d, cfg) for x, d in zip(xs, ds)]
    diffs = [abs(o['e'] / 32768 - fe) for o, (fy, fe) in zip(iout, fout)]
    rep['fixed_vs_float_mean_ediff'] = sum(diffs) / len(diffs)
    rep['fixed_vs_float_tail_ediff'] = max(diffs[-500:])
    assert rep['fixed_vs_float_mean_ediff'] < 0.005
    assert rep['fixed_vs_float_tail_ediff'] < 0.02
    werr = max(abs(m.coef[k] / 2**20 - fcoef[k]) for k in range(4))
    rep['fixed_vs_float_weight_err'] = werr
    assert werr < 0.01
    # ---- misadjustment vs step ----
    for mu_i in (4096, 16384):
        m = FixedLMS(8, 1)
        cfgm = Config(taps=4, mu=mu_i, nlms=0, update_en=1, floor=64,
                      ntaps_max=8)
        xs2 = [pr.randrange(-16000, 16000) for _ in range(3000)]
        p2 = Plant(h, noise=0.0005, seed=mu_i)
        out = [m.step(x, p2.push(x), cfgm) for x in xs2]
        rep[f'misadj_mu{mu_i}_mse'] = sum(o['e'] ** 2 for o in out[-400:]) / 400
    rep['misadj_monotone'] = rep['misadj_mu16384_mse'] > rep['misadj_mu4096_mse']
    assert rep['misadj_monotone']
    # ---- saturation: full-scale drive must clip, never wrap ----
    cfgf = Config(taps=8, mu=65535, nlms=0, update_en=1, floor=0, ntaps_max=8)
    m = FixedLMS(8, 1)
    clips = 0
    for x, d in zip([32767] * 200 + [-32768] * 200,
                    [32767] * 200 + [-32768] * 200):
        o = m.step(x, d, cfgf)
        clips += o['clip']
        assert -32768 <= o['y'] <= 32767 and -32768 <= o['e'] <= 32767
    assert clips > 0
    assert all(-(1 << 23) <= c <= (1 << 23) - 1 for c in m.coef)
    rep['sat_clip_events'] = clips
    # ---- freeze ----
    # Note: in-flight updates committed after the enable drops are legal;
    # after vis samples the coefficient array must be perfectly stable.
    m = FixedLMS(8, 1)
    for x, d in zip(xs[:200], ds[:200]):
        m.step(x, d, Config(taps=4, mu=16384, update_en=1, ntaps_max=8))
    cfgz = Config(taps=4, mu=16384, update_en=0, ntaps_max=8)
    for x, d in zip(xs[200:210], ds[200:210]):
        m.step(x, d, cfgz)
    frozen = list(m.coef)
    for x, d in zip(xs[210:400], ds[210:400]):
        m.step(x, d, cfgz)
    assert m.coef == frozen
    rep['freeze_ok'] = True
    # ---- NLMS floor bypass ----
    m = FixedLMS(8, 1)
    cfgb = Config(taps=8, mu=32768, nlms=1, floor=1024, ntaps_max=8)
    o = [m.step(0, 12345, cfgb) for _ in range(10)]
    assert all(x['bypass'] for x in o) and m.coef == [0] * 8
    rep['floor_bypass_ok'] = True
    print('  model section PASS')
    return rep


# ============================================================== RTL runs
def main():
    rep = {'model': model_section()}
    runs = {}
    h4 = [0.5, -0.25, 0.125, -0.0625]

    runs['serial_lms'] = run_sim('serial_lms', 8, 0, Stim(
        8, Plant(h4, 0.001),
        cfgseq=[dict(taps=8, mu=8192, nlms=0, uen=1, floor=64, clr=0),
                dict(taps=4, mu=16384, nlms=0, uen=1, floor=64, clr=1),
                dict(taps=0, mu=1, nlms=0, uen=1, floor=0, clr=0),
                dict(taps=8, mu=65535, nlms=0, uen=1, floor=0, clr=0),
                dict(taps=4, mu=16384, nlms=0, uen=0, floor=64, clr=0)],
        seed=11), 16000)

    runs['serial_nlms'] = run_sim('serial_nlms', 8, 0, Stim(
        8, Plant(h4, 0.001),
        cfgseq=[dict(taps=8, mu=8192, nlms=1, uen=1, floor=64, clr=0),
                dict(taps=4, mu=16384, nlms=1, uen=1, floor=16, clr=1),
                dict(taps=9, mu=1, nlms=1, uen=1, floor=0, clr=0),
                dict(taps=8, mu=32768, nlms=1, uen=1, floor=1024, clr=0)],
        seed=22), 18000)

    runs['parallel_lms'] = run_sim('parallel_lms', 8, 1, Stim(
        8, Plant(h4, 0.001),
        cfgseq=[dict(taps=8, mu=8192, nlms=0, uen=1, floor=64, clr=0),
                dict(taps=4, mu=16384, nlms=0, uen=1, floor=64, clr=1),
                dict(taps=0, mu=1, nlms=0, uen=1, floor=0, clr=0),
                dict(taps=8, mu=65535, nlms=0, uen=1, floor=0, clr=0)],
        seed=33), 16000)

    runs['parallel_nlms'] = run_sim('parallel_nlms', 8, 1, Stim(
        8, Plant(h4, 0.001),
        cfgseq=[dict(taps=8, mu=8192, nlms=1, uen=1, floor=64, clr=0),
                dict(taps=4, mu=16384, nlms=1, uen=1, floor=16, clr=1),
                dict(taps=9, mu=1, nlms=1, uen=1, floor=0, clr=0),
                dict(taps=8, mu=32768, nlms=1, uen=1, floor=4096, clr=0),
                dict(taps=8, mu=16384, nlms=1, uen=0, floor=64, clr=0)],
        seed=44), 18000)

    runs['parallel_n5'] = run_sim('parallel_n5', 5, 1, Stim(
        5, Plant(h4, 0.001),
        cfgseq=[dict(taps=5, mu=8192, nlms=1, uen=1, floor=64, clr=0),
                dict(taps=3, mu=16384, nlms=0, uen=1, floor=64, clr=0),
                dict(taps=6, mu=1, nlms=0, uen=1, floor=0, clr=0)],
        seed=55), 12000)

    runs['serial_n3_lms'] = run_sim('serial_n3', 3, 0, Stim(
        3, Plant(h4[:3], 0.001),
        cfgseq=[dict(taps=3, mu=16384, nlms=1, uen=1, floor=32, clr=1),
                dict(taps=4, mu=1, nlms=0, uen=1, floor=0, clr=0),
                dict(taps=2, mu=32768, nlms=0, uen=1, floor=8, clr=0)],
        seed=66), 8000)

    # ---- dense-stream oracle/model cross-check (validates VIS + II=1) -------
    for impl, vis in ((0, 1), (1, 3 + 31)):
        ntaps = 8
        m = FixedLMS(ntaps, vis)
        cfg = Config(taps=8, mu=8192, nlms=1, floor=64, ntaps_max=8)
        oracle = SerOracle(ntaps) if impl == 0 else ParOracle(ntaps)
        # phase 0: two reset cycles, then hold cfg until accepted
        for st in [dict(rst=0), dict(rst=0)]:
            oracle.tick(0, 0, 8, 8192, 0, 1, 64, 0, 0, 0, 1, 0, 0, 0, 0, 0)
        cv_hold = 1
        while cv_hold:
            e = oracle.tick(1, 1, 8, 8192, 1, 1, 64, 0, 0, 0, 1,
                            0, 0, 0, 0, 0)
            cv_hold = not e[1]
        # phase 1: stream samples, held until s_tready; mready=1 throughout
        pl = Plant(h4)
        xs = random.Random(0xD51A).sample(range(-30000, 30000), 300)
        exp = []
        got = []
        for x in xs:
            sd = ((pl.push(x) & 0xFFFF) << 16) | (x & 0xFFFF)
            while True:
                e = oracle.tick(1, 0, 8, 8192, 1, 1, 64, 0, 1, sd, 1,
                                0, 0, 0, 0, 0)
                if e[2]:
                    got.append((sext((e[3] >> 16) & 0xFFFF, 16),
                                sext(e[3] & 0xFFFF, 16), (e[4] >> 1) & 1))
                if e[0]:
                    break
            exp.append(m.step(x, sext((sd >> 16) & 0xFFFF, 16), cfg))
        for _ in range(120):
            e = oracle.tick(1, 0, 8, 8192, 1, 1, 64, 0, 0, 0, 1, 0, 0, 0, 0, 0)
            if e[2]:
                got.append((sext((e[3] >> 16) & 0xFFFF, 16),
                            sext(e[3] & 0xFFFF, 16), (e[4] >> 1) & 1))
        assert len(got) == len(exp), (impl, len(got), len(exp))
        for i, (g, x_) in enumerate(zip(got, exp)):
            assert g == (x_['e'], x_['y'], x_['bypass']), (impl, i, g, x_)
        rep[f'dense_impl{impl}'] = {'samples': len(got), 'match': True}

    rep['runs'] = runs
    rep['status'] = 'PASS'
    rep['rtl_sha256'] = hashlib.sha256(RTL.read_bytes()).hexdigest()
    rep['scope'] = 'RTL simulation only; no P&R or hardware acceptance'
    (OUT / 'summary.json').write_text(json.dumps(rep, indent=2))
    print(OUT)
    print(json.dumps(rep, indent=2)[:6000])


if __name__ == '__main__':
    main()
