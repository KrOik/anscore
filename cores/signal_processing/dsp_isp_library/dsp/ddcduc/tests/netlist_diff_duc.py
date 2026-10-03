"""Behavioral-RTL vs post-synthesis netlist differential for DSP-03's DUC core.

Replaying the board's own archived bytes through the behavioral RTL is
model-clean while the same image on silicon is wrong (see
board/eth_rate_harness/replay_board_eth.py).  The remaining board-free place for
that divergence to be introduced is synthesis itself.  This script builds a
gate-level Gowin netlist of ``duc_stream`` with the same ``synth_gowin``
invocation the board image uses, runs the identical transaction stimulus
through BOTH descriptions and diffs the output logs.

  python netlist_diff_duc.py

A divergence here is a synthesis-level defect reproducible without hardware.
Byte-identical output means the board failure is physical (timing or
asynchronous behaviour), not semantic.
"""
import json, math, os, random, subprocess, sys
from datetime import datetime
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]
LIB = BASE.parents[1]
ROOT = LIB.parents[1]
sys.path.insert(0, str(BASE / 'models'))
import model as M

TOOL = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
env['PATH'] = (str(TOOL / 'bin') + os.pathsep + str(TOOL / 'lib')
               + os.pathsep + env.get('PATH', ''))
GOWIN_SIM = TOOL / 'share/yosys/gowin'
RTLS = [BASE / 'rtl/ddcduc_nco.sv', BASE / 'rtl/ddcduc_iq_fir.sv',
        BASE / 'rtl/duc_stream.sv', LIB / 'infra/stream/stream_sync_fifo.v']
CELLS = [GOWIN_SIM / 'cells_sim.v', GOWIN_SIM / 'cells_xtra_gw2a.v',
         GOWIN_SIM / 'cells_latch.v']


def modules_in(text):
    import re
    return set(re.findall(r'^\s*module\s+(\\?[A-Za-z_][\w]*)', text, re.M))


def split_modules(text):
    """[(name, source)] for every top-level module in a Verilog string.

    The Gowin libraries declare ports both as ``module FOO (a, b)`` and
    ``module FOO(a, b)``, so the name comes from a regex on the header line;
    taking split()[1] would keep the attached port list and defeat the dedup.
    """
    import re
    out, name, buf = [], None, []
    for ln in text.splitlines(True):
        if name is None:
            m = re.match(r'\s*module\s+(\\?[A-Za-z_][\w]*)', ln)
            if m:
                name = m.group(1).lstrip('\\')
                buf = [ln]
        else:
            buf.append(ln)
            if ln.lstrip().startswith('endmodule'):
                out.append((name, ''.join(buf)))
                name, buf = None, []
    return out


PAD_BYPASS = '''
// Simulation-only stand-ins for the Gowin IO buffers.  The shipped models make
// every netlist output a tri-state, which iverilog reads as 'x' when the test-
// bench taps the port; the buffers themselves are pure routing, so a
// pass-through is the same function without the pad electrical behaviour.
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

// MULT18X18 as shipped by OSS CAD Suite is an EMPTY BLACK BOX (ports and
// parameters only, no logic), so a gate-level netlist that uses it simulates as
// 'x' everywhere.  This is the datasheet function: an 18x18 multiply whose
// operand signedness comes from the ASIGN/BSIGN pins.  The register pins are
// only active when a REG parameter is set; netdiff asserts the netlist never
// overrides a parameter, so the combinational path below is the whole cell.
module MULT18X18 (A, SIA, B, SIB, ASIGN, BSIGN, ASEL, BSEL, CE, CLK, RESET,
                  DOUT, SOA, SOB);
    parameter AREG = 1'b0, BREG = 1'b0, OUT_REG = 1'b0, PIPE_REG = 1'b0;
    input  [17:0] A, SIA;
    input  [17:0] B, SIB;
    input  ASIGN, BSIGN, ASEL, BSEL, CE, CLK, RESET;
    output [35:0] DOUT;
    output [17:0] SOA, SOB;

    wire signed [18:0] ea = ASIGN ? {A[17], A} : {2'b00, A};
    wire signed [18:0] eb = BSIGN ? {B[17], B} : {2'b00, B};
    wire signed [37:0] pr = ea * eb;
    assign DOUT = pr[35:0];
    assign SOA = A;
    assign SOB = B;
endmodule
'''


DSP_TB = '''
module tb;
reg [17:0] a, b;
reg sa, sb;
reg signed [18:0] ea, eb;
reg signed [37:0] pr;
wire [35:0] d;
integer k, i, bad;
MULT18X18 u (.A(a), .SIA(18'd0), .B(b), .SIB(18'd0), .ASIGN(sa), .BSIGN(sb),
             .ASEL(1'b0), .BSEL(1'b0), .CE(1'b0), .CLK(1'b0), .RESET(1'b0),
             .DOUT(d), .SOA(), .SOB());
task chk; begin
  #1;
  ea = sa ? {a[17], a} : {2'b00, a};
  eb = sb ? {b[17], b} : {2'b00, b};
  pr = ea * eb;
  if (d !== pr[35:0]) begin
     bad = bad + 1;
     if (bad < 5) $display("MODEL MISMATCH a=%h b=%h sa=%b sb=%b cell=%h ref=%h",
                           a, b, sa, sb, d, pr[35:0]);
  end
end
endtask
initial begin
  bad = 0;
  for (i = 0; i < 4; i = i + 1) begin
    sa = i[0]; sb = i[1];
    a = 18'd0;  b = 18'd0;  chk();
    a = 18'h3ffff; b = 18'h3ffff; chk();
    a = 18'h20000; b = 18'h20000; chk();
    a = 18'h20000; b = 18'd1; chk();
    a = 18'd1;  b = 18'h20000; chk();
    for (k = 0; k < 1200; k = k + 1) begin
       a = $urandom & 18'h3ffff;
       b = $urandom & 18'h3ffff;
       chk();
    end
  end
  if (bad) begin $display("DSP MODEL SELF-CHECK FAILED %0d", bad); $fatal(1); end
  $display("DSP MODEL SELF-CHECK PASS");
  $finish;
end
endmodule
'''


def check_dsp_model(d):
    """Validate the hand-written MULT18X18 against Verilog signed arithmetic.

    The whole netlist differential rests on this model being the cell's real
    function, so it is checked here rather than assumed: corners (0, +-1, the
    18-bit min/max) plus 3000 random operand pairs for each of the four
    ASIGN/BSIGN combinations.
    """
    sub = d / 'dsp_model_check'
    sub.mkdir(exist_ok=True)
    (sub / 'gw_cells.v').write_text(PAD_BYPASS)
    (sub / 'tb_model.sv').write_text(DSP_TB)
    r = subprocess.run(
        [str(TOOL / 'bin/iverilog.exe'), '-g2012', '-s', 'tb', '-o', 'x.vvp',
         'gw_cells.v', 'tb_model.sv'], cwd=sub, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode:
        raise RuntimeError('dsp model compile: ' + r.stdout[-1500:])
    r = subprocess.run([str(TOOL / 'bin/vvp.exe'), 'x.vvp'], cwd=sub, env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True, timeout=600)
    if r.returncode or 'PASS' not in r.stdout:
        raise RuntimeError('dsp model self-check: ' + r.stdout[-1500:])
    return r.stdout.strip()


def assert_no_dsp_registers(netlist_text):
    """The MULT18X18 model above is combinational; prove the netlist asked for
    that.  Any instance with a #(...) override would register an operand or the
    result, and the model would no longer be the cell's function."""
    import re
    hits = re.findall(r'MULT18X18\s*#\s*\(([^)]*)\)', netlist_text)
    if hits:
        raise AssertionError(('registered MULT18X18 use; model is combinational',
                              hits[:2]))
    return len(re.findall(r'^\s+MULT18X18\s+\S+\s*\(', netlist_text, re.M))



def merged_cell_models(d):
    """cells_sim.v plus only the family-specific modules it lacks.

    The shipped Gowin simulation libraries overlap (IDES4_MEM / OSER4_MEM / DQS
    appear twice), and iverilog rejects a duplicate module, so the extra files
    are filtered to the names the base file does not define.  IO buffers are
    replaced by pass-throughs so outputs are two-valued.
    """
    seen, parts = set(), [PAD_BYPASS]
    override = {'IBUF', 'OBUF', 'MULT18X18'}
    for f in CELLS:
        text = f.read_text()
        for name, src in split_modules(text):
            if name in seen or name in override:
                continue
            seen.add(name)
            parts.append(src)
    p = d / 'gw_cells.v'
    p.write_text(''.join(parts))
    return p, sorted(n for n in seen if n.startswith(
        ('MULT', 'PADD', 'ALU54', 'BSRAM')))

OUT = BASE / 'evidence' / ('netdiff_duc_' + datetime.now().strftime('%Y%m%d_%H%M%S'))

CANNED = {0: dict(inc=None, init=0x00000000, rate=2, shift=3, taps=1),
          1: dict(inc=None, init=0x22222222, rate=4, shift=6, taps=1),
          2: dict(inc=None, init=0x00000000, rate=8, shift=9, taps=1),
          3: dict(inc=None, init=0x00000000, rate=4, shift=6, taps=5)}
BW = {0: 0.15, 1: -0.075, 2: 0.25, 3: 0.30}

TB = '''
module tb;
reg clk=0; always #5 clk=~clk;
reg rst_n=0, cv=0, sv=0, mr=0;
reg [31:0] inc=0, init=0; reg [6:0] rate=0; reg [5:0] shift=0, taps=0;
reg [287:0] coeffs=0; reg signed [15:0] si=0, sq=0;
wire sr,cr,mv,mcl; wire signed [15:0] mi,mq;
wire cd,ce; wire [15:0] incnt; wire [31:0] outcnt; wire [15:0] sat;
duc_stream dut(.clk(clk),.rst_n(rst_n),
 .s_i_tdata(si),.s_q_tdata(sq),.s_tvalid(sv),.s_tready(sr),
 .m_i_tdata(mi),.m_q_tdata(mq),.m_clip(mcl),.m_tvalid(mv),.m_tready(mr),
 .cfg_valid(cv),.cfg_ready(cr),.cfg_phase_inc(inc),.cfg_phase_init(init),
 .cfg_rate(rate),.cfg_shift(shift),.cfg_taps(taps),.cfg_coeffs(coeffs),
 .cfg_done(cd),.cfg_error(ce),.input_count(incnt),.output_count(outcnt),
 .sat_count(sat));
integer f,o,n,cyc,adv,op,rr,vv,mrv;
initial begin
 f=$fopen("stim.txt","r"); o=$fopen("out.txt","w");
 if(f==0) $fatal(1,"no stim");
 cyc=0; adv=1;
 @(posedge clk); #1;
 while(!$feof(f)) begin
  @(negedge clk);
  if(adv) begin
   n=$fscanf(f,"%d %d %d %h %h %h %h %h %h %h %h %d\\n",
             op,rr,vv,inc,init,rate,shift,taps,coeffs,si,sq,mrv);
   if(n!=12) $fatal(1,"fixture parse failed cyc=%0d n=%0d",cyc,n);
   rst_n=rr; cv=vv; mr=mrv;
   sv=(op==1);
  end
  #1;
  if(sv && sr) $fdisplay(o,"A %0d",cyc);
  if(mv && mr) $fdisplay(o,"O %0d %h %h %d",cyc,mi[15:0],mq[15:0],mcl);
  if(cd) $fdisplay(o,"E %0d DONE",cyc);
  if(ce) $fdisplay(o,"E %0d ERR",cyc);
  if(op==1) adv=sr; else adv=1;
  cyc=cyc+1;
  if(cyc>200000) begin $display("TIMEOUT state-watchdog"); $finish; end
 end
 $fdisplay(o,"CTR %0d %0d %0d",incnt,outcnt,sat);
 $display("done rows=%0d",cyc);
 $finish;
end
endmodule
'''


def row(op=0, rst=1, cv=0, c=None, si=0, sq=0, mr=1):
    c = c or {}
    co = M.pack_coeffs(c.get('uc', ()))
    return ('%d %d %d %08x %08x %02x %02x %02x %072x %04x %04x %d'
            % (op, rst, cv, c.get('inc', 0) & 0xFFFFFFFF,
               c.get('init', 0) & 0xFFFFFFFF, c.get('rate', 0),
               c.get('shift', 0), c.get('taps', 0), co, si & 0xffff,
               sq & 0xffff, mr))


def build_stim(sel, n_in=48):
    e = dict(CANNED[sel])
    e['inc'] = M.inc_for(BW[sel])
    if e['taps'] == 1:
        e['uc'] = ()
    else:
        e['uc'] = tuple(M.design_comp(3, e['rate'], e['taps'])[0])
    rows = [row(rst=0, mr=0) for _ in range(4)]
    rows.append(row(cv=1, c=e))
    for k in range(n_in):
        i = int(9000 * math.sin(2 * math.pi * 0.03 * k))
        q = int(9000 * math.cos(2 * math.pi * 0.03 * k))
        rows.append(row(op=1, si=i, sq=q, mr=1))
    rows += [row(mr=1) for _ in range(600)]
    return '\n'.join(rows) + '\n', e


def iverilog(d, srcs, tag):
    (d / 'tb.sv').write_text(TB)
    cmd = ([str(TOOL / 'bin/iverilog.exe'), '-g2012', '-s', 'tb',
            '-o', 'test.vvp'] + [str(p) for p in srcs] + ['tb.sv'])
    with (d / ('compile_%s.log' % tag)).open('w') as f:
        r = subprocess.run(cmd, cwd=d, env=env, stdout=f,
                           stderr=subprocess.STDOUT)
    if r.returncode:
        print((d / ('compile_%s.log' % tag)).read_text()[:2500])
        raise RuntimeError('compile failed: %s in %s' % (tag, d))
    with (d / ('run_%s.log' % tag)).open('w') as f:
        r = subprocess.run([str(TOOL / 'bin/vvp.exe'), 'test.vvp'], cwd=d,
                           env=env, stdout=f, stderr=subprocess.STDOUT,
                           timeout=3600)
    text = (d / 'out.txt').read_text().splitlines() if (d / 'out.txt').exists() \
        else []
    if r.returncode:
        print((d / ('run_%s.log' % tag)).read_text()[-2500:])
        raise RuntimeError('run failed: %s in %s' % (tag, d))
    return text


def synthesize(d):
    (d / 'synth.ys').write_text(
        'read_verilog -sv %s\n'
        'hierarchy -check -top duc_stream\n'
        'synth_gowin -noalu -family gw2a -top duc_stream\n'
        'stat\n'
        'write_verilog -noattr netlist_duc.v\n'
        % ' '.join(str(p) for p in RTLS))
    log = d / 'synth.log'
    with log.open('w') as f:
        r = subprocess.run([str(TOOL / 'bin/yosys.exe'), '-s', 'synth.ys'],
                           cwd=d, env=env, stdout=f, stderr=subprocess.STDOUT)
    if r.returncode:
        print(log.read_text()[-4000:])
        raise RuntimeError('yosys failed in %s' % d)
    keep = [ln for ln in log.read_text().splitlines()
            if re_search(r'(Number of cells|MULT|PADD|ALU54|BSRAM|DFF\b)', ln)]
    return d / 'netlist_duc.v', keep


def re_search(pat, ln):
    import re
    return re.search(pat, ln)


def diff(a, b):
    shown, n = [], 0
    for i in range(max(len(a), len(b))):
        x = a[i] if i < len(a) else '<absent>'
        y = b[i] if i < len(b) else '<absent>'
        if x != y:
            n += 1
            if len(shown) < 10:
                shown.append((i, x, y))
    return n, shown


def main():
    for f in CELLS:
        if not f.is_file():
            raise FileNotFoundError(str(f))
    OUT.mkdir(parents=True)
    cells_v, hard_cells = merged_cell_models(OUT)
    print('cell models: %s' % ' '.join(hard_cells), flush=True)
    report = {}
    for sel in (0, 1, 2, 3):
        d = OUT / ('cfg%d' % sel)
        d.mkdir()
        stim, cfg = build_stim(sel)
        (d / 'stim.txt').write_text(stim)
        (d / 'config.json').write_text(json.dumps(
            {k: (list(v) if isinstance(v, tuple) else v) for k, v in cfg.items()},
            indent=1))
        net_v, cellstat = synthesize(d)
        nmult = assert_no_dsp_registers(net_v.read_text())
        (d / 'synth_cells.txt').write_text('\n'.join(cellstat))
        check = check_dsp_model(OUT) if sel == 0 else 'cached'
        for sub in ('beh', 'net'):
            (d / sub).mkdir()
            (d / sub / 'stim.txt').write_text(stim)
        beh = iverilog(d / 'beh', RTLS, 'beh')
        net = iverilog(d / 'net', [cells_v, net_v], 'net')
        n, shown = diff(beh, net)
        report['cfg%d' % sel] = dict(beh_lines=len(beh), net_lines=len(net),
                                     differing=n,
                                     dsp_cells=[ln for ln in cellstat
                                                if ln.startswith(
                                                ('MULT', 'PADD', 'ALU54'))],
                                     first=shown)
        print('cfg%d  beh=%d net=%d lines, differing=%d  mults=%d  (inc=%d rate=%d '
              'shift=%d taps=%d)' % (sel, len(beh), len(net), n, nmult, cfg['inc'],
                                     cfg['rate'], cfg['shift'], cfg['taps']),
              flush=True)
        for i, x, y in shown:
            print('   line %d  beh:%-30s net:%s' % (i, x, y), flush=True)
    (OUT / 'netdiff_report.json').write_text(json.dumps(report, indent=1))
    print('NETDIFF', OUT, flush=True)


if __name__ == '__main__':
    main()
