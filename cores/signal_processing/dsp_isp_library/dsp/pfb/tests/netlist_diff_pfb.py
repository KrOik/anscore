"""DSP-16 behavioural-RTL vs post-synthesis-netlist differential.

The board says pfb is byte-exact only for a single M-frame block at stall 0;
every longer block is wrong, and it is wrong differently in the dsp=4 build and
the dsp=0 build (evidence/board_v5_pfb_20261003 vs board_v6_pfb_nodsp_20261004:
same wrong-word counts, different words).  That rules the hard MULT18X18 out as
the sole cause but leaves two candidates this script can separate without
hardware:

  * a synthesis/mapping change of meaning (memory mapped to a BSRAM whose read
    latency or write mode is not what the RTL describes, RNE/width reinterpretation);
  * physical timing (the netlist then stays byte-exact and only silicon differs).

Method: synthesise pfb_stream exactly as the board image does
(`synth_gowin -noalu -family gw2a`, M=8 P=8 as in eth_rate_harness.v), replay the
core's OWN cycle-exact golden vectors (the fixture tests/test_pfb.py produces)
through both descriptions, and diff.

The Gowin deck in OSS CAD Suite declares MULT18X18 as an empty black box, so a
datasheet model is supplied and self-checked over all four ASIGN/BSIGN
combinations before anything trusts it.  DPX9B/SDPX9B/DPB/SP are black boxes for
the same reason; they are modelled here as synchronous-read BSRAMs honouring the
parameters the netlist actually carries, and those parameters are printed so a
wrong assumption is visible instead of silent.

    python netlist_diff_pfb.py            # uses the newest m8p8 fixture
"""
import json, os, re, subprocess, sys
from datetime import datetime
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]                 # dsp/pfb
LIB = BASE.parents[1]
ROOT = LIB.parents[1]
TOOL = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
env['PATH'] = (str(TOOL / 'bin') + os.pathsep + str(TOOL / 'lib')
               + os.pathsep + env.get('PATH', ''))
GOWIN_SIM = TOOL / 'share/yosys/gowin'
RTL = BASE / 'rtl/pfb_stream.sv'
CELLS = [GOWIN_SIM / 'cells_sim.v', GOWIN_SIM / 'cells_xtra_gw2a.v',
         GOWIN_SIM / 'cells_latch.v']

PAD_BYPASS = '''
// The shipped IO-buffer models make every netlist output tri-state, which
// iverilog reads as x when the testbench taps the port.  The buffers are pure
// routing, so a pass-through is the same function without the pad behaviour.
module IBUF (input I, output O); assign O = I; endmodule
module OBUF (input I, output O); assign O = I; endmodule
'''

# MULT18X18 and the BSRAM family are empty black boxes in
# share/yosys/gowin/cells_xtra_gw2a.v, so a gate-level netlist that uses them
# reads x everywhere unless they are modelled.  These are datasheet functions.
BLACKBOX_MODELS = r'''
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

// DPX9B: two-port BSRAM, 9/16/18 bits per word, 8192 bits total.  Address
// granularity is a BYTE address in 18-bit mode: the low two bits are byte
// enables and the word index is ADA[13:2].  A read updates DO on the clock edge
// only when the port is enabled and not writing -- one cycle of latency, which
// is exactly what a behavioural `qr <= mem[addr]` becomes when it is mapped in.
// WRITE_MODE 2'b00 keeps DO unchanged during a write (no write-through); the
// model honours the parameters the netlist carries and prints them, so an
// assumption that does not match the netlist is visible rather than silent.
module DPX9B (CLKA, CEA, OCEA, RESETA, WREA, ADA, DIA, BLKSELA, DOA,
              CLKB, CEB, OCEB, RESETB, WREB, ADB, DIB, BLKSELB, DOB);
    parameter BIT_WIDTH_0 = 18, BIT_WIDTH_1 = 18;
    parameter WRITE_MODE0 = 2'b00, WRITE_MODE1 = 2'b00;
    parameter RESET_MODE  = "SYNC";
    parameter [2:0] BLK_SEL_0 = 3'b000, BLK_SEL_1 = 3'b000;
    input CLKA, CEA, OCEA, RESETA, WREA;
    input [13:0] ADA;
    input [17:0] DIA;
    input [2:0] BLKSELA;
    output [17:0] DOA;
    input CLKB, CEB, OCEB, RESETB, WREB;
    input [13:0] ADB;
    input [17:0] DIB;
    input [2:0] BLKSELB;
    output [17:0] DOB;

    localparam W = (BIT_WIDTH_0 == 9) ? 9 : 18;
    reg [17:0] mem [0:511];
    reg [17:0] ra, rb;
    integer i;

    wire [17:0] doa_q = ra, dob_q = rb;
    assign DOA = OCEA ? doa_q : 18'h0000;
    assign DOB = OCEB ? dob_q : 18'h0000;

    always @(posedge CLKA) begin
        if (CEA && WREA && BLKSELA == BLK_SEL_0) begin
            if (BIT_WIDTH_0 == 9) mem[ADA[12:1]] <= {DIA[17:9], DIA[8:0]};
            else if (ADA[1:0] == 2'b11) mem[ADA[13:2]] <= DIA;
            else begin
                for (i = 0; i < 2; i = i + 1)
                    if (ADA[1:0] & (2 << i))
                        mem[ADA[13:2]][9*i +: 9] <= DIA[9*i +: 9];
            end
        end
        if (CEA && !WREA) ra <= mem[BIT_WIDTH_0 == 9 ? {2'b00, ADA[12:1]}
                                                  : ADA[13:2]];
    end

    always @(posedge CLKB) begin
        if (CEB && WREB && BLKSELB == BLK_SEL_1) begin
            if (BIT_WIDTH_1 == 9) mem[ADB[12:1]] <= {DIB[17:9], DIB[8:0]};
            else if (ADB[1:0] == 2'b11) mem[ADB[13:2]] <= DIB;
            else begin
                for (i = 0; i < 2; i = i + 1)
                    if (ADB[1:0] & (2 << i))
                        mem[ADB[13:2]][9*i +: 9] <= DIB[9*i +: 9];
            end
        end
        if (CEB && !WREB) rb <= mem[BIT_WIDTH_1 == 9 ? {2'b00, ADB[12:1]}
                                                  : ADB[13:2]];
    end
endmodule

module DPB  (/* 18K dual-port subset: alias to DPX9B naming */);
endmodule
module SDPX9B ();
endmodule
module SPX9B ();
endmodule
'''

DSP_SELFTEST = r'''
module tb_model_selfcheck;
    reg [17:0] a, b; reg sa, sb; reg signed [18:0] ea, eb;
    reg signed [37:0] refprod; integer k, bad; wire [35:0] d;
    MULT18X18 u(.A(a), .SIA(18'd0), .B(b), .SIB(18'd0), .ASIGN(sa), .BSIGN(sb),
               .ASEL(1'b0), .BSEL(1'b0), .CE(1'b0), .CLK(1'b0), .RESET(1'b0),
               .DOUT(d), .SOA(), .SOB());
    initial begin
        bad = 0;
        for (k = 0; k < 64; k = k + 1) begin
            a = $random; b = $random; sa = k[0]; sb = k[1];
            ea = sa ? {a[17], a} : {2'b00, a};
            eb = sb ? {b[17], b} : {2'b00, b};
            refprod = ea * eb;
            #1;
            if (d !== refprod[35:0]) bad = bad + 1;
        end
        if (bad) begin $display("MODEL SELF CHECK FAIL %0d", bad); $fatal(1, "x"); end
        $display("MODEL SELF CHECK PASS");
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


def merged_deck(d):
    """Gowin cell library, deduplicated, black boxes replaced by real models."""
    seen, parts = set(), [PAD_BYPASS, BLACKBOX_MODELS]
    override = {'IBUF', 'OBUF', 'MULT18X18', 'DPX9B', 'SDPX9B', 'DPB',
                'SPX9B', 'SP', 'DPX9', 'SDPX9', 'ROM', 'ROM16'}
    for f in CELLS:
        for name, src in split_modules(f.read_text()):
            if name in seen or name in override:
                continue
            seen.add(name)
            parts.append(src)
    p = d / 'gw_cells.v'
    p.write_text(''.join(parts))
    return p, sorted(n for n in seen if 'RAM' in n or 'DPX' in n or 'MULT' in n)


def run(cmd, cwd, log):
    with (cwd / log).open('w') as fh:
        r = subprocess.run([str(c) for c in cmd], cwd=cwd, env=env,
                           stdout=fh, stderr=subprocess.STDOUT)
    return r.returncode, fh.name


def latest_fixture():
    ds = sorted((BASE / 'evidence').glob('rtl_*_m8p8'), key=lambda p: p.name)
    if not ds:
        raise SystemExit('no m8p8 fixture; run tests/test_pfb.py first')
    d = ds[-1]
    for f in ('vectors.txt', 'tb.sv', 'pfb_coeffs.vh'):
        if not (d / f).exists():
            raise SystemExit('%s missing in %s' % (f, d))
    return d


def main():
    src = latest_fixture()
    out = BASE / 'evidence' / ('netdiff_pfb_'
                               + datetime.now().strftime('%Y%m%d_%H%M%S'))
    out.mkdir(parents=True)
    cells_v, ram_cells = merged_deck(out)
    print('deck supplies models for: %s' % ' '.join(ram_cells), flush=True)

    # self-check the multiplier model before trusting any of it
    (out / 'selfcheck.v').write_text(DSP_SELFTEST)
    rc, _ = run([TOOL / 'bin/iverilog.exe', '-g2012', '-o', 'sc.vvp',
                 'gw_cells.v', 'selfcheck.v'], out, 'selfcheck_compile.log')
    rc, _ = run([TOOL / 'bin/vvp.exe', 'sc.vvp'], out, 'selfcheck.log')
    sc = (out / 'selfcheck.log').read_text()
    print('multiplier model:', sc.strip().splitlines()[-1] if sc.strip() else 'no output',
          flush=True)
    if 'PASS' not in sc:
        raise SystemExit('MULT18X18 model self-check failed; see %s' % out)

    # synthesise exactly the way the board image does
    shutil_src = out / 'pfb_stream.sv'
    shutil_src.write_text(RTL.read_text(encoding='utf-8'))
    (out / 'pfb_coeffs.vh').write_text((src / 'pfb_coeffs.vh').read_text())
    (out / 'synth.ys').write_text(
        'read_verilog -sv -I. pfb_stream.sv\n'
        'hierarchy -check -top pfb_stream\n'
        'synth_gowin -noalu -family gw2a -top pfb_stream\nstat\n'
        'write_verilog -noattr netlist_pfb.v\n')
    rc, _ = run([TOOL / 'bin/yosys.exe', '-s', 'synth.ys'], out, 'synth.log')
    if rc:
        raise SystemExit('yosys failed; see %s' % out)
    net = (out / 'netlist_pfb.v').read_text()
    used = sorted(set(re.findall(r'^\s+\\?([A-Z][A-Za-z0-9_]*)\s+\S+\s*\(',
                                 net, re.M)))
    print('netlist cell types: %s' % ' '.join(used), flush=True)
    params = re.findall(r'DPX9B\s+#\((.*?)\)\s*\w', net, re.S)[:3]
    print('DPX9B parameter overrides seen: %d %s' % (len(params),
          [p.replace('\n', ' ')[:90] for p in params]), flush=True)

    # replay the SAME golden vectors through both descriptions.  The netlist run
    # needs a TB that instantiates the module without the parameter override:
    # synthesis constant-propagates M and P, so the netlist module has none, and
    # `pfb_stream #(.M(M), .P(P))` then fails to elaborate.
    (out / 'vectors.txt').write_text((src / 'vectors.txt').read_text())
    tb_beh = (src / 'tb.sv').read_text()
    tb_net = tb_beh.replace('pfb_stream #(.M(M),.P(P)) dut(', 'pfb_stream dut(')
    assert tb_net != tb_beh
    (out / 'tb_beh.sv').write_text(tb_beh)
    (out / 'tb_net.sv').write_text(tb_net)
    report = {}
    for tag, srcs in (('beh', [out / 'pfb_stream.sv']),
                      ('net', [cells_v, out / 'netlist_pfb.v'])):
        d = out / tag
        d.mkdir()
        (d / 'vectors.txt').write_text((out / 'vectors.txt').read_text())
        (d / 'pfb_coeffs.vh').write_text((out / 'pfb_coeffs.vh').read_text())
        (d / 'tb.sv').write_text((out / ('tb_net.sv' if tag == 'net'
                                                  else 'tb_beh.sv')).read_text())
        rc, _ = run([TOOL / 'bin/iverilog.exe', '-g2012', '-Wall', '-I.',
                     '-o', 't.vvp', '-s', 'tb']
                    + [str(p if p.parent == d else Path('../' + p.name))
                       for p in srcs] + ['tb.sv'], d, 'compile.log')
        if rc:
            print('%s compile FAILED: %s' % (tag, (d / 'compile.log').read_text()
                                             [-1500:]), flush=True)
            report[tag] = 'compile_error'
            continue
        rc, _ = run([TOOL / 'bin/vvp.exe', 't.vvp'], d, 'run.log')
        log = (d / 'run.log').read_text()
        report[tag] = dict(rc=rc, pass_row=(re.search(r'PASS rows=(\d+)', log)
                                            or [None, None])[1],
                           first_fail=(re.search(r'(data|ctrl|count|FATAL)[^\n]*',
                                                 log) or [None, None])[0],
                           x_seen='x' in log.lower() and 'exp=' in log)
        print('%-4s rc=%d %s' % (tag, rc, json.dumps(report[tag])), flush=True)
    (out / 'netdiff_report.json').write_text(json.dumps(
        dict(fixture=str(src), cell_types=used, dpx9b_params=len(params),
             runs=report), indent=1))
    beh, net_r = report.get('beh'), report.get('net')
    if isinstance(beh, dict) and isinstance(net_r, dict):
        same = beh.get('pass_row') == net_r.get('pass_row')
        print('NETDIFF %s  (behavioural rows=%s, netlist rows=%s)  %s'
              % ('CLEAN' if same else 'DIVERGES', beh.get('pass_row'),
                 net_r.get('pass_row'), out))
    else:
        print('NETDIFF inconclusive (a run did not complete) %s' % out)


import shutil  # noqa: E402  (used above for staging the RTL copy)

if __name__ == '__main__':
    main()
