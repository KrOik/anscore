"""Isolated Gowin mapping of the DSP-03 cores; no P&R or board claim.

Runs `synth_gowin -noalu -top <m>` (default device family context, no
-family flag per task convention) for:
  * ddc_stream        (mix -> CIC decim -> scale -> FIFO -> comp FIR)
  * duc_stream        (comp FIR -> CIC interp -> scale -> mix)
  * chain_top         (loopback wrapper: duc -> ddc, test artifact only --
                       8 DSP-class cells exceeds the <=4 per-image guidance
                       and is documented as such)

Expected per-core DSP usage: 3 (mixer) + 1 (shared FIR MAC) = 4.
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
env['PATH'] = (str(TOOL / 'lib') + os.pathsep + str(TOOL / 'bin') + os.pathsep +
               os.environ.get('SystemRoot', 'C:\\Windows') + r'\System32')

RTL = {n: BASE / 'rtl' / (n + '.sv')
       for n in ('ddcduc_nco', 'ddcduc_iq_fir', 'ddc_stream', 'duc_stream')}
FIFO = BASE.parents[1] / 'infra/stream/stream_sync_fifo.v'
CORE = [RTL['ddcduc_nco'], RTL['ddcduc_iq_fir']]

CHAIN = '''module chain_top(
 input wire clk,rst_n,
 input wire signed [15:0] s_i_tdata,input wire signed [15:0] s_q_tdata,
 input wire s_tvalid,output wire s_tready,
 output wire signed [15:0] m_i_tdata,output wire signed [15:0] m_q_tdata,
 output wire m_clip,output wire m_tvalid,input wire m_tready,
 input wire cfg_valid,output wire cfg_ready,
 input wire [31:0] cfg_phase_inc,input wire [31:0] cfg_phase_init,
 input wire [6:0] cfg_rate,input wire [5:0] cfg_shift,
 input wire [5:0] cfg_taps,input wire [287:0] cfg_coeffs,
 output wire cfg_done,output wire cfg_error,
 output wire [15:0] input_count,output wire [31:0] output_count,
 output wire [15:0] sat_count);
wire signed [15:0] li,lq; wire lv,lr,lcl,ucd,uce,dd,dce,dcr;
wire [15:0] uic; wire [31:0] uoc; wire [15:0] usc; wire ovf;
duc_stream u_duc(.clk(clk),.rst_n(rst_n),
 .s_i_tdata(s_i_tdata),.s_q_tdata(s_q_tdata),.s_tvalid(s_tvalid),
 .s_tready(s_tready),
 .m_i_tdata(li),.m_q_tdata(lq),.m_clip(lcl),.m_tvalid(lv),.m_tready(lr),
 .cfg_valid(cfg_valid),.cfg_ready(cfg_ready),
 .cfg_phase_inc(cfg_phase_inc),.cfg_phase_init(cfg_phase_init),
 .cfg_rate(cfg_rate),.cfg_shift(cfg_shift),.cfg_taps(cfg_taps),
 .cfg_coeffs(cfg_coeffs),.cfg_done(ucd),.cfg_error(uce),
 .input_count(uic),.output_count(uoc),.sat_count(usc));
ddc_stream u_ddc(.clk(clk),.rst_n(rst_n),
 .s_i_tdata(li),.s_q_tdata(lq),.s_tvalid(lv),.s_tready(lr),
 .m_i_tdata(m_i_tdata),.m_q_tdata(m_q_tdata),.m_clip(m_clip),
 .m_tvalid(m_tvalid),.m_tready(m_tready),
 .cfg_valid(cfg_valid),.cfg_ready(dcr),
 .cfg_phase_inc(cfg_phase_inc),.cfg_phase_init(cfg_phase_init),
 .cfg_rate(cfg_rate),.cfg_shift(cfg_shift),.cfg_taps(cfg_taps),
 .cfg_coeffs(cfg_coeffs),.cfg_done(dd),.cfg_error(dce),
 .input_count(input_count),.output_count(output_count),
 .sat_count(sat_count),.fifo_overflow(ovf));
assign cfg_done=dd&ucd; assign cfg_error=dce|uce;
endmodule'''


def synth(top_module, sources, tag, chparam=None):
    d = OUT / tag
    d.mkdir()
    cmd = 'read_verilog -sv ' + ' '.join(s.as_posix() for s in sources) + '; '
    if chparam:
        cmd += ' '.join(f'chparam -set {k} {v} {top_module};'
                        for k, v in chparam.items())
    cmd += (f' synth_gowin -noalu -top {top_module} '
            '-json core.json; stat')
    (d / 'command.txt').write_text(cmd + '\n')
    p = subprocess.run([str(TOOL / 'bin/yosys.exe'), '-p', cmd], cwd=d,
                       env=env, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT)
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
reports.append(synth('ddc_stream', [RTL['ddc_stream']] + CORE + [FIFO],
                     'ddc_stream'))
reports.append(synth('duc_stream', [RTL['duc_stream']] + CORE,
                     'duc_stream'))
# N=4 variant checks bit-growth coverage at max order
reports.append(synth('ddc_stream', [RTL['ddc_stream']] + CORE + [FIFO],
                     'ddc_stream_N4', {'CIC_STAGES': 4}))
reports.append(synth('duc_stream', [RTL['duc_stream']] + CORE,
                     'duc_stream_N4', {'CIC_STAGES': 4}))
# combined loopback wrapper: test artifact, knowingly exceeds <=4 DSP
csrc = OUT / '_chain_top.sv'
csrc.write_text(CHAIN)
reports.append(synth('chain_top', list(RTL.values()) + [FIFO, csrc],
                     'chain_loopback'))

summary = {'status': 'PASS',
           'source_sha256': {n: hashlib.sha256(p.read_bytes()).hexdigest()
                             for n, p in list(RTL.items()) + [('fifo', FIFO)]},
           'configurations': reports,
           'scope': 'isolated mapped resources; no board pin fit, routed '
                    'timing or physical acceptance; chain_top intentionally '
                    'exceeds the <=4 DSP per-image guidance (loopback test '
                    'wrapper, not a delivery configuration)'}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print(json.dumps(summary, indent=2))
