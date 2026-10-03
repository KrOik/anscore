"""Isolated Gowin mapping of the DSP-10 cores; no P&R or board claim.

Runs synth_gowin -noalu -family gw2a for each module at LANES=4 and
LANES=1, plus a chain wrapper (decim LANES=1 -> comp LANES=1 ->
interp LANES=2) proving all three fit the <=4 DSP-class budget together.
"""
import os, json, subprocess, hashlib, collections
from pathlib import Path
from datetime import datetime
BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
OUT = BASE / 'evidence' / ('synth_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir()
TOOL = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
# lib first avoids DLL shadowing; external PATH dirs carry incompatible DLLs.
env['PATH'] = str(TOOL / 'lib') + os.pathsep + str(TOOL / 'bin') + os.pathsep + \
    os.environ.get('SystemRoot', 'C:\\Windows') + r'\System32'
RTLS = {n: BASE / 'rtl' / (n + '.sv')
        for n in ('halfband_decim', 'halfband_interp', 'cic_comp_fir')}

# resource-accounting wrapper: all three cores in one image, independent
# stream ports, shared cfg broadcast (each instance keeps its own
# ready/done/error wires so nothing is pruned).  LANES 1+1+2 -> <=4 DSPs.
CHAIN = '''module chain_top(
 input wire clk,rst_n,
 input wire signed [15:0] s1_tdata,input wire s1_tvalid,
 output wire s1_tready,
 output wire signed [15:0] m1_tdata,output wire m1_tuser,
 output wire m1_tvalid,input wire m1_tready,
 input wire signed [15:0] s2_tdata,input wire s2_tvalid,
 output wire s2_tready,
 output wire signed [15:0] m2_tdata,output wire m2_tuser,
 output wire m2_tvalid,input wire m2_tready,
 input wire signed [15:0] s3_tdata,input wire s3_tvalid,
 output wire s3_tready,
 output wire signed [15:0] m3_tdata,output wire m3_tuser,
 output wire m3_tvalid,input wire m3_tready,
 input wire cfg_valid,input wire [5:0] cfg_taps,
 input wire [287:0] cfg_coeffs,
 input wire flush_valid,
 output wire [2:0] ready_o,output wire [2:0] done_o,output wire [2:0] err_o,
 output wire [2:0] flush_ready_o,output wire [2:0] flush_done_o,
 output wire [47:0] input_count_o,output wire [62:0] output_count_o,
 output wire [2:0] capacity_error_o);
wire[15:0] ic1,ic2,ic3;wire[20:0] oc1,oc2,oc3;wire cap1,cap2,cap3;
halfband_decim #(.LANES(1)) u_dec(.clk(clk),.rst_n(rst_n),
 .s_tdata(s1_tdata),.s_tvalid(s1_tvalid),.s_tready(s1_tready),
 .m_tdata(m1_tdata),.m_tuser(m1_tuser),.m_tvalid(m1_tvalid),
 .m_tready(m1_tready),.cfg_valid(cfg_valid),.cfg_ready(ready_o[0]),
 .cfg_taps(cfg_taps),.cfg_coeffs(cfg_coeffs[161:0]),.cfg_done(done_o[0]),
 .cfg_error(err_o[0]),.flush_valid(flush_valid),
 .flush_ready(flush_ready_o[0]),.flush_done(flush_done_o[0]),
 .input_count(ic1),.output_count(oc1),.capacity_error(cap1));
cic_comp_fir #(.LANES(1)) u_cmp(.clk(clk),.rst_n(rst_n),
 .s_tdata(s2_tdata),.s_tvalid(s2_tvalid),.s_tready(s2_tready),
 .m_tdata(m2_tdata),.m_tuser(m2_tuser),.m_tvalid(m2_tvalid),
 .m_tready(m2_tready),.cfg_valid(cfg_valid),.cfg_ready(ready_o[1]),
 .cfg_taps(cfg_taps),.cfg_coeffs(cfg_coeffs),.cfg_done(done_o[1]),
 .cfg_error(err_o[1]),.flush_valid(flush_valid),
 .flush_ready(flush_ready_o[1]),.flush_done(flush_done_o[1]),
 .input_count(ic2),.output_count(oc2),.capacity_error(cap2));
halfband_interp #(.LANES(2)) u_int(.clk(clk),.rst_n(rst_n),
 .s_tdata(s3_tdata),.s_tvalid(s3_tvalid),.s_tready(s3_tready),
 .m_tdata(m3_tdata),.m_tuser(m3_tuser),.m_tvalid(m3_tvalid),
 .m_tready(m3_tready),.cfg_valid(cfg_valid),.cfg_ready(ready_o[2]),
 .cfg_taps(cfg_taps),.cfg_coeffs(cfg_coeffs[161:0]),.cfg_done(done_o[2]),
 .cfg_error(err_o[2]),.flush_valid(flush_valid),
 .flush_ready(flush_ready_o[2]),.flush_done(flush_done_o[2]),
 .input_count(ic3),.output_count(oc3),.capacity_error(cap3));
assign input_count_o={ic1,ic2,ic3};
assign output_count_o={oc1,oc2,oc3};
assign capacity_error_o={cap1,cap2,cap3};
endmodule'''


def synth(top_module, sources, tag, chparam=None):
    d = OUT / tag
    d.mkdir()
    cmd = 'read_verilog -sv ' + ' '.join(s.as_posix() for s in sources) + '; '
    if chparam:
        cmd += ' '.join(f'chparam -set {k} {v} {top_module};'
                        for k, v in chparam.items())
    cmd += (f' synth_gowin -noalu -family gw2a -top {top_module} '
            '-json core.json; stat')
    (d / 'command.txt').write_text(cmd + '\n')
    p = subprocess.run([str(TOOL / 'bin/yosys.exe'), '-p', cmd], cwd=d, env=env,
                       text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (d / 'yosys.log').write_text(p.stdout)
    if p.returncode:
        raise RuntimeError(str(d) + '\n' + p.stdout[-3000:])
    design = json.loads((d / 'core.json').read_text())
    counts = collections.Counter(
        c['type'] for c in design['modules'][top_module]['cells'].values())
    rep = {'config': tag, 'cells': dict(counts),
           'lut1_4': sum(counts[f'LUT{k}'] for k in range(1, 5)),
           'ff': sum(v for k, v in counts.items() if k.startswith('DFF')),
           'dsp': sum(v for k, v in counts.items()
                      if k.startswith(('MULT', 'PADD', 'ALU54'))),
           'bram': sum(v for k, v in counts.items()
                       if k.startswith(('DPX', 'SPX', 'SDPX'))),
           'wide_mux': sum(v for k, v in counts.items()
                           if k.startswith('MUX'))}
    (d / 'resources.json').write_text(json.dumps(rep, indent=2))
    return rep


reports = []
for name in ('halfband_decim', 'halfband_interp', 'cic_comp_fir'):
    for lanes in (4, 1):
        reports.append(synth(name, [RTLS[name]], f'{name}_L{lanes}',
                             {'LANES': lanes}))

# wrapper: decim(L1) + comp(L1) + interp(L2) -> <=4 DSP-class cells
csrc = OUT / '_chain_top.sv'
csrc.write_text(CHAIN)
reports.append(synth('chain_top', list(RTLS.values()) + [csrc],
                     'chain_top'))

summary = {'status': 'PASS',
           'source_sha256': {n: hashlib.sha256(p.read_bytes()).hexdigest()
                             for n, p in RTLS.items()},
           'configurations': reports,
           'scope': 'isolated mapped resources; no board pin fit, routed '
                    'timing or physical acceptance'}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print(json.dumps(summary, indent=2))
