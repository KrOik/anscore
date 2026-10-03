"""Does -nodsp change what the design MEANS, not just where it lands?

The board rounds say it bluntly: `evidence/w4_hb_decim_nodsp` (multipliers in LUT
logic) failed 56 of 72 blocks, and it failed THE SAME blocks, at the same word
indices, with the same wrong values, in all three rounds - while the dsp=1 build
of the same core failed 1..4 of 96.  A deterministic, reproducible difference
between two implementations that are supposed to compute the same function is a
synthesis-semantics finding, not a silicon one, and it matters beyond this core:
every "-nodsp tells us whether the hard DSP block is at fault" experiment in this
library rests on the nodsp build being a faithful equivalent.

This script decides it without hardware: synthesise the core twice
(`synth_gowin -noalu -family gw2a`, then the same with `-nodsp`), run the SAME
deterministic stimulus through the behavioural RTL and through each netlist, and
diff the emitted output streams.

    python netdiff_nodsp_hb_decim.py

Cell models come from dsp/pfb/tests/netlist_diff_pfb.py (merged, deduplicated
Gowin deck plus a self-checked MULT18X18 datasheet model) - one implementation,
not three.
"""
import json, os, re, subprocess, sys
from datetime import datetime
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]                    # dsp/halfband
LIB = BASE.parents[1]
ROOT = LIB.parents[1]
sys.path.insert(0, str(LIB / 'dsp' / 'pfb' / 'tests'))
from netlist_diff_pfb import merged_deck                      # noqa: E402

TOOL = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
env['PATH'] = (str(TOOL / 'lib') + os.pathsep + str(TOOL / 'bin')
               + os.pathsep + env.get('SystemRoot', 'C:\\Windows')
               + r'\System32')
RTL = BASE / 'rtl/halfband_decim.sv'

WRAP = '''
// The rate harness elaborates halfband_decim with LANES=1; synthesising the
// bare core would build its 4-lane default and answer a different question.
module dut (clk, rst_n, s_tdata, s_tvalid, s_tready, m_tdata, m_tuser,
            m_tvalid, m_tready, cfg_valid, cfg_ready, cfg_taps, cfg_coeffs,
            cfg_done, cfg_error, flush_valid, flush_ready, flush_done,
            input_count, output_count, capacity_error);
    input clk, rst_n, s_tvalid, m_tready, cfg_valid, flush_valid;
    input signed [15:0] s_tdata;
    input [5:0] cfg_taps;
    input [9*18-1:0] cfg_coeffs;
    output wire s_tready, cfg_ready, flush_ready, m_tvalid, m_tuser;
    output reg signed [15:0] m_tdata;
    output reg cfg_done, cfg_error, flush_done;
    output reg [15:0] input_count;
    output reg [20:0] output_count;
    output reg capacity_error;
    halfband_decim #(.MAX_PAIRS(9), .LANES(1), .MAX_INPUTS(65535)) core(
        .clk(clk), .rst_n(rst_n), .s_tdata(s_tdata), .s_tvalid(s_tvalid),
        .s_tready(s_tready), .m_tdata(m_tdata), .m_tuser(m_tuser),
        .m_tvalid(m_tvalid), .m_tready(m_tready), .cfg_valid(cfg_valid),
        .cfg_ready(cfg_ready), .cfg_taps(cfg_taps), .cfg_coeffs(cfg_coeffs),
        .cfg_done(cfg_done), .cfg_error(cfg_error), .flush_valid(flush_valid),
        .flush_ready(flush_ready), .flush_done(flush_done),
        .input_count(input_count), .output_count(output_count),
        .capacity_error(capacity_error));
endmodule
'''

TB = '''
module tb;
reg clk=0; always #5 clk=~clk;
reg rst_n=0, cv=0, sv=0, fv=0, mr=1;
reg signed [15:0] sd=0;
reg [5:0] ct=9;   // 9 taps = 5 pairs, legal for MAX_PAIRS=9
reg         taps_seen=0;
parameter [9*18-1:0] DEFAULTS = 162'ha017f4770148bfdb5003a7ffb7000340000;
reg [9*18-1:0] cc=DEFAULTS;
wire sr, cr, mv, mu, fr, fd, ce, caperr;
wire signed [15:0] md;
wire [15:0] ic; wire [20:0] oc;
dut u(.clk(clk), .rst_n(rst_n), .s_tdata(sd), .s_tvalid(sv), .s_tready(sr),
      .m_tdata(md), .m_tuser(mu), .m_tvalid(mv), .m_tready(mr),
      .cfg_valid(cv), .cfg_ready(cr), .cfg_taps(ct), .cfg_coeffs(cc),
      .cfg_done(fd), .cfg_error(ce), .flush_valid(fv), .flush_ready(fr),
      .flush_done(), .input_count(ic), .output_count(oc),
      .capacity_error(caperr));
integer i, k, o;
initial begin
  o = $fopen("out.txt", "w");
  repeat (4) @(negedge clk);
  rst_n = 1;
  @(negedge clk); cv = 1;
  @(negedge clk); while (!cr) @(negedge clk);
  cv = 0;
  @(negedge clk); @(negedge clk);
  for (i = 0; i < 96; i = i + 1) begin
    @(negedge clk);
    sv = (i < 64);
    sd = ((i * 1597) % 2000) - 1000;
    if (mv && mr) begin $fdisplay(o, "S %0d %h %b", i, md, mu); taps_seen=1; end
  end
  @(negedge clk); sv = 0; fv = 1;
  @(negedge clk); fv = 0;
  for (k = 0; k < 96; k = k + 1) begin
    @(negedge clk);
    if (mv && mr) $fdisplay(o, "F %0d %h %b", k, md, mu);
  end
  $fclose(o);
  $display("done taps_seen=%b", taps_seen);
  $fclose(o);
  $finish;
end
endmodule
'''


def synth(d, tag, extra):
    (d / (tag + '.ys')).write_text(
        'read_verilog -sv -I. %s\nread_verilog -sv dut_wrap.v\n'
        'hierarchy -check -top dut\n'
        'synth_gowin -noalu%s -family gw2a -top dut\nstat\n'
        'write_verilog -noattr netlist_%s.v\n' % (RTL, extra, tag))
    with (d / ('synth_%s.log' % tag)).open('w') as fh:
        r = subprocess.run([str(TOOL / 'bin/yosys.exe'), '-s', tag + '.ys'],
                           cwd=d, env=env, stdout=fh, stderr=subprocess.STDOUT)
    if r.returncode:
        print((d / ('synth_%s.log' % tag)).read_text()[-2000:])
        raise RuntimeError('yosys failed for ' + tag)
    log = (d / ('synth_%s.log' % tag)).read_text()
    mult = len(re.findall(r'^\s+\w+\s+MULT18X18\b', log, re.M))
    cells = re.search(r'Number of cells:\s+(\d+)', log)
    return (d / ('netlist_%s.v' % tag)), (cells and int(cells.group(1))), mult


def sim(d, srcs, tag):
    d.mkdir(exist_ok=True)
    (d / 'tb.sv').write_text(TB)
    (d / 'dut_wrap.v').write_text(WRAP)
    cmd = [str(TOOL / 'bin/iverilog.exe'), '-g2012', '-s', 'tb',
           '-o', 't.vvp'] + [str(p) for p in srcs] + ['tb.sv']
    with (d / 'compile.log').open('w') as fh:
        r = subprocess.run(cmd, cwd=d, env=env, stdout=fh,
                           stderr=subprocess.STDOUT)
    if r.returncode:
        print((d / 'compile.log').read_text()[-2500:])
        raise RuntimeError('compile failed for ' + tag)
    with (d / 'run.log').open('w') as fh:
        subprocess.run([str(TOOL / 'bin/vvp.exe'), 't.vvp'], cwd=d, env=env,
                       stdout=fh, stderr=subprocess.STDOUT, timeout=1800)
    if (d / 'out.txt').exists():
        return (d / 'out.txt').read_text().splitlines()
    print('no out.txt for %s: %s' % (tag, (d / 'run.log').read_text()[-500:]))
    return []


def diff(a, b, limit=6):
    bad = [(i, a[i] if i < len(a) else '-', b[i] if i < len(b) else '-')
           for i in range(max(len(a), len(b)))]
    bad = [x for x in bad if x[1] != x[2]]
    return len(bad), bad[:limit]


def main():
    for f in (RTL, TOOL / 'bin/yosys.exe'):
        if not f.exists():
            raise FileNotFoundError(str(f))
    out = BASE / 'evidence' / ('netdiff_nodsp_'
                               + datetime.now().strftime('%Y%m%d_%H%M%S'))
    out.mkdir(parents=True)
    cells_v, _names = merged_deck(out)
    (out / 'dut_wrap.v').write_text(WRAP)

    net_dsp, cells_dsp, mult_dsp = synth(out, 'dsp', '')
    net_nd, cells_nd, mult_nd = synth(out, 'nodsp', ' -nodsp')
    print('dsp build:   %s cells, %s MULT instances in stat' % (cells_dsp, mult_dsp),
          flush=True)
    print('nodsp build: %s cells' % cells_nd, flush=True)

    beh = sim(out / 'beh', [RTL, out / 'dut_wrap.v'], 'beh')
    n_dsp = sim(out / 'net_dsp', [cells_v, net_dsp], 'net_dsp')
    n_nd = sim(out / 'net_nodsp', [cells_v, net_nd], 'net_nodsp')
    d1 = diff(beh, n_dsp)
    d2 = diff(beh, n_nd)
    print('beh=%d rows | beh-vs-dsp-netlist differs in %d rows %s' % (
        len(beh), d1[0], d1[1][:2]), flush=True)
    print('beh=%d rows | beh-vs-NODSP-netlist differs in %d rows %s' % (
        len(beh), d2[0], d2[1][:2]), flush=True)
    (out / 'report.json').write_text(json.dumps(dict(
        rows_beh=len(beh), rows_net_dsp=len(n_dsp), rows_net_nodsp=len(n_nd),
        diff_dsp_rows=d1[0], diff_nodsp_rows=d2[0],
        first_diff_nodsp=[list(x) for x in d2[1]],
        first_diff_dsp=[list(x) for x in d1[1]],
        cells_dsp=cells_dsp, cells_nodsp=cells_nd, out=str(out)), indent=1))
    verdict = ('NODSP CHANGES THE FUNCTION (synthesis-semantics bug)'
               if d2[0] and not d1[0] else
               ('both netlists differ from the RTL' if d2[0] and d1[0]
                else 'nodsp is faithful'))
    print('NETDIFF %s  %s' % (verdict, out))


if __name__ == '__main__':
    main()
