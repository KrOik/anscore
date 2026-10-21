"""Isolated Gowin mapping of hilbert_core; no P&R or board claim."""
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
RTLS = [BASE / 'rtl/hilbert_analytic.sv', BASE / 'rtl/phase_freq.sv',
        BASE / 'rtl/hilbert_core.sv']
CONFIGS = [
    (16, 4, "288'h3fffdfffd3ffe1ffeffff89ffcd3feb7ff80ffd05fee7ff99cfda3bf157f976baedb"),
    (16, 2, "288'h3fffdfffd3ffe1ffeffff89ffcd3feb7ff80ffd05fee7ff99cfda3bf157f976baedb"),
    (8, 4, "144'h3ffe5ffdbbfe2ffedabf5bcfa3bfaff7"),
]
reports = []
for pairs, lanes, dcoeffs in CONFIGS:
    d = OUT / f'pairs{pairs}_lanes{lanes}'
    d.mkdir()
    top = f'''module synth_top(
 input wire clk,rst_n,
 input wire signed [15:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output wire [79:0] m_tdata,output wire m_tvalid,input wire m_tready,
 output wire [1:0] m_tuser,
 input wire cfg_valid,output wire cfg_ready,input wire [5:0] cfg_pairs,
 input wire [{pairs * 18 - 1}:0] cfg_coeffs,input wire cfg_clear,
 output wire cfg_done,cfg_error);
hilbert_core #(.PAIRS({pairs}),.LANES({lanes}),.DEFAULT_COEFFS({dcoeffs})) dut(
 clk,rst_n,s_tdata,s_tvalid,s_tready,m_tdata,m_tvalid,m_tready,m_tuser,
 cfg_valid,cfg_ready,cfg_pairs,cfg_coeffs,cfg_clear,cfg_done,cfg_error);
endmodule'''
    (d / 'top.sv').write_text(top)
    command = ('read_verilog -sv ' +
               ' '.join(r.as_posix() for r in RTLS) +
               f' {d.as_posix()}/top.sv; synth_gowin -noalu -family gw2a '
               '-top synth_top -json core.json; stat')
    (d / 'command.txt').write_text(command + '\n')
    p = subprocess.run([str(TOOL / 'bin/yosys.exe'), '-p', command], cwd=d,
                       env=env, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT)
    (d / 'yosys.log').write_text(p.stdout)
    if p.returncode:
        raise RuntimeError(str(d) + '\n' + p.stdout[-3000:])
    design = json.loads((d / 'core.json').read_text())
    counts = collections.Counter(
        c['type'] for c in design['modules']['synth_top']['cells'].values())
    report = {'pairs': pairs, 'lanes': lanes, 'cells': dict(counts),
              'lut1_4': sum(counts[f'LUT{k}'] for k in range(1, 5)),
              'ff': sum(v for k, v in counts.items() if k.startswith('DFF')),
              'dsp': sum(v for k, v in counts.items()
                         if k.startswith(('MULT', 'PADD', 'ALU54'))),
              'bram': sum(v for k, v in counts.items()
                          if k.startswith(('DPX', 'SPX', 'SDPX'))),
              'wide_mux': sum(v for k, v in counts.items()
                              if k.startswith('MUX'))}
    (d / 'resources.json').write_text(json.dumps(report, indent=2))
    reports.append(report)
summary = {'status': 'PASS',
           'source_sha256': {r.name: hashlib.sha256(r.read_bytes()).hexdigest()
                             for r in RTLS},
           'configurations': reports,
           'scope': 'isolated mapped resources; no board pin fit, routed '
                    'timing or physical acceptance'}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print(json.dumps(summary, indent=2))
