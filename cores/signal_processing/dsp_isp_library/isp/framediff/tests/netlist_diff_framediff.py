"""Behavioral-RTL vs post-synthesis netlist differential for ISP-17 framediff.

The board replays of framediff (board/eth_rate_harness/fd_ref_rel.py) show the
silicon using the reference of a NEIGHBOURING raster position -- one earlier in
some cases, one later in others -- while the behavioral RTL and the model agree
byte for byte.  A neighbour-of-the-wrong-pixel reference is exactly what a
reference RAM whose read address and read capture are not what the RTL
describes would produce, and the synthesiser is free to map a 16x8 array onto
Gowin distributed RAM.  This script builds the same netlist the board image
uses (synth_gowin -noalu -family gw2a, MAX_W/MAX_H = 4 as in eth_rate_harness.v)
and runs the archived block stimulus through BOTH descriptions.

  python netlist_diff_framediff.py

The testbench is not a generic pixel drivel: it re-implements the cycle-accurate
driving board/eth_rate_harness/eth_rate_harness.v applies to the core, because
the reference-store behaviour under test depends on *when* the output side
stalls:

  * rst_n released, then cfg_valid held until cfg_ready (state CONFIG),
    then two dead cycles (CHECK, PREFETCH), then RUN;
  * in RUN, s_tdata/s_tvalid track the accepted-pixel count (word i appears as
    soon as i inputs have been accepted, held while back-pressured), and
    SOF/EOL come from that same counter, not from the cycle number;
  * m_tready = (phase & 7) >= stall, with phase an untouched counter that
    increments once per RUN cycle.

Two self-checks keep the harness honest: the behavioural run must reproduce the
archived model word-for-word (otherwise the stimulus is not the archived block),
and every board-vs-behavioural mismatch is reported so the differential is aimed
at the words the silicon actually got wrong.

A divergence here is a synthesis-level semantic defect reproducible without
hardware.  Identical logs push the cause to physical timing.
"""
import json, os, re, struct, subprocess, sys
from datetime import datetime
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]                 # isp/framediff
LIB = BASE.parents[1]
ROOT = LIB.parents[1]
sys.path.insert(0, str(LIB / 'board' / 'eth_rate_harness'))
import eth_protocol as ep                                   # noqa: E402
from fd_diag import load                                      # noqa: E402

TOOL = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
env['PATH'] = (str(TOOL / 'bin') + os.pathsep + str(TOOL / 'lib')
               + os.pathsep + env.get('PATH', ''))
GOWIN_SIM = TOOL / 'share/yosys/gowin'
RTL = BASE / 'rtl/framediff_stream.sv'
CELLS = [GOWIN_SIM / 'cells_sim.v', GOWIN_SIM / 'cells_xtra_gw2a.v',
         GOWIN_SIM / 'cells_latch.v']

PAD_BYPASS = '''
// Simulation-only stand-ins for the Gowin IO buffers: the shipped models make
// every netlist output tri-state, which iverilog reads as 'x' when the test-
// bench taps the port.  The buffers are pure routing, so a pass-through is the
// same function without the pad electrical behaviour.
module IBUF (I, O);
    input  I;
    output O;
    assign O = I;
endmodule
module OBUF (I, O);
    input  I;
    output O;
    assign O = I;
endmodule
'''

WRAP = '''
// The harness elaborates framediff at its own 4x4 geometry; synthesising the
// bare core would build the 128x128 default and map the RAM elsewhere.
module dut (clk, rst_n, s_tdata, s_tvalid, s_tuser, s_tlast, s_tready,
            m_tdata, m_tvalid, m_tuser, m_tlast, m_tready,
            cfg_valid, cfg_ready, cfg_width, cfg_height, cfg_mode, cfg_thresh,
            cfg_alpha, cfg_scn, cfg_scpol, cfg_done, cfg_error,
            o_error, scn_event, busy);
  input clk, rst_n, s_tvalid, s_tuser, s_tlast, m_tready, cfg_valid;
  input [7:0] s_tdata, cfg_thresh;
  input [2:0] cfg_width, cfg_height;
  input [1:0] cfg_mode;
  input [3:0] cfg_alpha;
  input [7:0] cfg_scn;
  input cfg_scpol;
  output s_tready, cfg_ready, cfg_done, cfg_error, o_error, scn_event, busy;
  output [7:0] m_tdata;
  output m_tvalid, m_tuser, m_tlast;
  framediff_stream #(.BITS(8), .MAX_W(4), .MAX_H(4)) core(
    .clk(clk), .rst_n(rst_n), .s_tdata(s_tdata), .s_tvalid(s_tvalid),
    .s_tuser(s_tuser), .s_tlast(s_tlast), .s_tready(s_tready),
    .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tuser(m_tuser),
    .m_tlast(m_tlast), .m_tready(m_tready), .cfg_valid(cfg_valid),
    .cfg_ready(cfg_ready), .cfg_width(cfg_width), .cfg_height(cfg_height),
    .cfg_mode(cfg_mode), .cfg_thresh(cfg_thresh), .cfg_alpha(cfg_alpha),
    .cfg_scn(cfg_scn), .cfg_scpol(cfg_scpol), .cfg_done(cfg_done),
    .cfg_error(cfg_error), .o_error(o_error), .scn_event(scn_event),
    .busy(busy));
endmodule
'''

# The testbench drives one block exactly the way eth_rate_harness.v does.
# Stimulus file: "<count> <stall> <mode> <thresh> <alpha> <scn> <scpole> <exp>"
# then <count> hex pixel words, one per line.
TB = '''
module tb;
reg clk=0; always #10 clk=~clk;
reg rst_n=0, cv=0, sv=0, mr=0, su=0, sl=0;
reg [7:0] sd=0;
reg [1:0] cmode=0; reg [7:0] cthr=0, cscn=0; reg [3:0] cal=0; reg cpol=0;
wire sr,cr,cd,ce,oerr,scn,busy;
wire [7:0] md; wire mv,mu,ml;
dut u(.clk(clk),.rst_n(rst_n),.s_tdata(sd),.s_tvalid(sv),.s_tuser(su),
      .s_tlast(sl),.s_tready(sr),.m_tdata(md),.m_tvalid(mv),.m_tuser(mu),
      .m_tlast(ml),.m_tready(mr),.cfg_valid(cv),.cfg_ready(cr),
      .cfg_width(3'd4),.cfg_height(3'd4),.cfg_mode(cmode),.cfg_thresh(cthr),
      .cfg_alpha(cal),.cfg_scn(cscn),.cfg_scpol(cpol),.cfg_done(cd),
      .cfg_error(ce),.o_error(oerr),.scn_event(scn),.busy(busy));

integer f,o,i,n,cnt,stall,exp,fed,ocnt,phase,cyc,quiet,hold;
reg [7:0] wbuf[0:4095];

task loghand;         // sample this cycle's handshakes and events
begin
  #1;
  if(sv && sr) $fdisplay(o,"A %0d %h",cyc,sd);
  // The scene bit follows eth_rate_harness.v's fd_scn_hold law exactly: the
  // word that fires carries (held | this-cycle pulse), a pulse arriving while
  // nothing fires is kept for the word that eventually does, and a fire
  // clears it.  Without this the stall-5/7 blocks lose bit 11 and the
  // differential reports a phantom model disagreement.
  if(mv && mr) $fdisplay(o,"O %0d %h %b %b %b",cyc,md,mu,ml,hold|scn);
  if(scn && !(mv && mr)) hold = 1;
  if(mv && mr)           hold = 0;
  if(cd)       $fdisplay(o,"E %0d DONE",cyc);
  if(ce)       $fdisplay(o,"E %0d ERR",cyc);
  if(oerr)     $fdisplay(o,"E %0d MARKERR",cyc);
end
endtask

initial begin
  f=$fopen("stim.txt","r"); o=$fopen("out.txt","w");
  if(f==0) $fatal(1,"no stim");
  n=$fscanf(f,"%d %d %d %d %d %d %d %d\\n",
            cnt,stall,cmode,cthr,cal,cscn,cpol,exp);
  if(n!=8) $fatal(1,"header parse n=%0d",n);
  for(i=0;i<cnt;i=i+1)
    if($fscanf(f,"%h\\n",wbuf[i])!=1) $fatal(1,"word %0d parse",i);

  fed=0; ocnt=0; phase=0; quiet=0; hold=0;
  @(negedge clk); cv=0; sv=0; mr=0; sd=0;

  // ---- RESET: core held in reset, as the harness holds it through LOAD ----
  for(cyc=0;cyc<4;cyc=cyc+1) begin
    @(negedge clk); rst_n=0; loghand();
  end
  @(negedge clk); rst_n=1;

  // ---- CONFIG: cfg_valid held until the core accepts ----
  cv=1;
  for(cyc=0;cyc<64 && !cr;cyc=cyc+1) begin
    @(negedge clk); loghand();
  end
  cv=0;
  // ---- CHECK + PREFETCH ----
  @(negedge clk); loghand();
  @(negedge clk); loghand();

  // ---- RUN ----
  for(cyc=0;cyc<6000;cyc=cyc+1) begin
    @(negedge clk);
    sv = (fed<cnt);
    sd = wbuf[fed<cnt?fed:cnt-1];
    su = ((fed%16)==0);
    sl = ((fed%4)==3);
    mr = (((phase%8))>=stall);
    loghand();
    if(sv && sr) fed=fed+1;
    if(mv && mr) begin
      ocnt=ocnt+1; quiet=0;
    end else quiet=quiet+1;
    phase=phase+1;
    if(fed>=cnt && (ocnt>=exp || quiet>400)) begin
      @(negedge clk); loghand();
      cyc=6000;
    end
  end
  $display("done fed=%0d ocnt=%0d exp=%0d cyc=%0d",fed,ocnt,exp,cyc);
  $finish;
end
endmodule
'''


def split_modules(text):
    out, name, buf = [], None, []
    for ln in text.splitlines(True):
        if name is None:
            m = re.match(r'\s*module\s+(\\?[A-Za-z_][\w]*)', ln)
            if m:
                name, buf = m.group(1).lstrip('\\'), [ln]
        else:
            buf.append(ln)
            if ln.lstrip().startswith('endmodule'):
                out.append((name, ''.join(buf)))
                name, buf = None, []
    return out


def merged_cell_models(d):
    """Gowin simulation library, deduplicated and with IO buffers bypassed.

    cells_sim.v and cells_xtra_gw2a.v re-declare the same module names, which
    iverilog rejects, so later definitions are dropped.
    """
    seen, parts = set(), [PAD_BYPASS]
    override = {'IBUF', 'OBUF'}
    for f in CELLS:
        for name, src in split_modules(f.read_text()):
            if name in seen or name in override:
                continue
            seen.add(name)
            parts.append(src)
    p = d / 'gw_cells.v'
    p.write_text(''.join(parts))
    return p, sorted(n for n in seen if 'RAM' in n or 'DPX' in n)


def build_stim(words, cfg_sel, stall):
    mode, thr, alpha, scn, pol = ep.protocol.FD_BUNDLES[cfg_sel]
    rows = ['%d %d %d %d %d %d %d %d' % (len(words), stall, mode, thr, alpha,
                                         scn, pol, len(words))]
    rows += ['%02x' % (w & 0xFF) for w in words]
    return '\n'.join(rows) + '\n'


def iverilog(d, srcs, tag):
    (d / 'tb.sv').write_text(TB)
    cmd = [str(TOOL / 'bin/iverilog.exe'), '-g2012', '-s', 'tb',
           '-o', 'test.vvp'] + [str(p) for p in srcs] + ['tb.sv']
    with (d / ('compile_%s.log' % tag)).open('w') as fh:
        r = subprocess.run(cmd, cwd=d, env=env, stdout=fh,
                           stderr=subprocess.STDOUT)
    if r.returncode:
        print((d / ('compile_%s.log' % tag)).read_text()[:3000])
        raise RuntimeError('compile failed: %s' % tag)
    with (d / ('run_%s.log' % tag)).open('w') as fh:
        r = subprocess.run([str(TOOL / 'bin/vvp.exe'), 'test.vvp'], cwd=d,
                           env=env, stdout=fh, stderr=subprocess.STDOUT,
                           timeout=1800)
    if r.returncode:
        print((d / ('run_%s.log' % tag)).read_text()[-2000:])
        raise RuntimeError('run failed: %s' % tag)
    text = (d / 'out.txt').read_text() if (d / 'out.txt').exists() else ''
    if re.search(r'\bxx?\b', text):
        raise RuntimeError('run %s produced x-valued outputs (black-box cell?)'
                           % tag)
    return text.splitlines()


def words_from(log):
    """Rebuild the emitted result words (value | sof<<8 | eol<<9 | scn<<11)."""
    out = []
    for ln in log:
        if not ln.startswith('O '):
            continue
        _, cyc, val, u, l, s = ln.split()
        out.append(int(val, 16) | (int(u) << 8) | (int(l) << 9) |
                   (int(s) << 11))
    return out


def synthesize(d):
    (d / 'dut_wrap.v').write_text(WRAP)
    (d / 'synth.ys').write_text(
        'read_verilog -sv %s\nread_verilog -sv dut_wrap.v\n'
        'hierarchy -check -top dut\n'
        'synth_gowin -noalu -family gw2a -top dut\nstat\n'
        'write_verilog -noattr netlist_framediff.v\n' % str(RTL))
    log = d / 'synth.log'
    with log.open('w') as fh:
        r = subprocess.run([str(TOOL / 'bin/yosys.exe'), '-s', 'synth.ys'],
                           cwd=d, env=env, stdout=fh, stderr=subprocess.STDOUT)
    if r.returncode:
        print(log.read_text()[-4000:])
        raise RuntimeError('yosys failed')
    txt = log.read_text()
    keep = [ln.strip() for ln in txt.splitlines()
            if re.search(r'(Number of cells|RAM|DPX|BSRAM|\$mem)', ln)]
    return d / 'netlist_framediff.v', keep


def diff(a, b):
    shown, n = [], 0
    for i in range(max(len(a), len(b))):
        x = a[i] if i < len(a) else '<absent>'
        y = b[i] if i < len(b) else '<absent>'
        if x != y:
            n += 1
            if len(shown) < 6:
                shown.append((i, x, y))
    return n, shown


def main():
    for f in CELLS + [RTL]:
        if not f.is_file():
            raise FileNotFoundError(str(f))
    out = BASE / 'evidence' / ('netdiff_fd_' +
                               datetime.now().strftime('%Y%m%d_%H%M%S'))
    out.mkdir(parents=True)
    cells_v, ram_cells = merged_cell_models(out)
    print('cell models with RAM: %s' % ' '.join(ram_cells), flush=True)
    net_v, stat = synthesize(out)
    net_txt = net_v.read_text()
    used = sorted(set(re.findall(r'^\s+\\?([A-Z][A-Za-z0-9_]*)\s+\S+\s*\(',
                                 net_txt, re.M)))
    print('netlist cell types: %s' % ' '.join(used), flush=True)
    (out / 'synth_cells.txt').write_text('\n'.join(stat))

    rd = LIB / 'board/eth_rate_harness/evidence/board_v4_framediff_20261003/round_01'
    # --only=drate11,sw13 replays a subset, for following up a single row.
    only = next((a.split('=', 1)[1].split(',') for a in sys.argv
                 if a.startswith('--only=')), None)
    cases = [c for c in load(str(rd))
             if not c['name'].startswith(('ctl', 'pers', 'recfg'))
             and (only is None or c['name'] in only)]
    print('cases: %d' % len(cases), flush=True)
    report = {}
    tot_b = tot_n = 0
    for c in cases:
        d = out / c['name']
        d.mkdir()
        stim = build_stim(c['inw'], c['cfg'], c['stall'])
        (d / 'stim.txt').write_text(stim)
        for sub in ('beh', 'net'):
            (d / sub).mkdir()
            (d / sub / 'stim.txt').write_text(stim)
        beh = iverilog(d / 'beh', [RTL, out / 'dut_wrap.v'], 'beh')
        net = iverilog(d / 'net', [cells_v, net_v], 'net')
        # self-check: the behavioural replay must be the archived model
        # The oracle is protocol.oracle(), the same independent model the
        # harness host path and the board runner use -- never a local
        # re-derivation of the RTL equations, which has no business deciding
        # what the core should emit.
        exp = ep.model_oracle(c['cfg'], c['inw'], 7)
        bw = words_from(beh)
        dm, _ = diff(['%08x' % w for w in exp], ['%08x' % w for w in bw])
        nw, shown = diff(beh, net)
        nb, _ = diff(['%08x' % w for w in c['board']],
                     ['%08x' % w for w in bw])
        tot_b += nb
        tot_n += nw
        report[c['name']] = dict(cfg=c['cfg'], stall=c['stall'],
                                 words=len(bw), model_vs_beh=dm,
                                 board_vs_beh=nb, beh=len(beh), net=len(net),
                                 differing=nw, first=shown)
        print('%-22s cfg%-2d stall%d w=%d model_vs_beh=%d board_vs_beh=%d '
              'beh_vs_net=%d %s' % (c['name'], c['cfg'], c['stall'], len(bw),
                                    dm, nb, nw, shown[:2]), flush=True)
    (out / 'netdiff_report.json').write_text(json.dumps(report, indent=1))
    n = sum(1 for v in report.values() if v['differing'])
    print('CASES %d  DIVERGING %d  board-mismatch total %d  %s'
          % (len(report), n, tot_b, out))


if __name__ == '__main__':
    main()
