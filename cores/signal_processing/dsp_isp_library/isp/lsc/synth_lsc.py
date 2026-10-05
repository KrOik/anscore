"""Core-only Gowin synthesis of lsc_stream (yosys synth_gowin, no -family)."""
import datetime
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
from collections import Counter

HERE = pathlib.Path(__file__).resolve().parent   # isp/lsc
ROOT = HERE.parents[3]                            # repo root

WRAPPER = """module lsc_synth_top(
 input clk,rst_n,
 input [{b}-1:0] s_tdata,input s_tvalid,s_tuser,s_tlast,output s_tready,
 output [{b}-1:0] m_tdata,output m_tvalid,m_tuser,m_tlast,input m_tready,
 input cfg_valid,output cfg_ready,
 input [12:0] cfg_width,input [12:0] cfg_height,
 input [4:0] cfg_gw,input [3:0] cfg_gh,
 input [3:0] cfg_kx,input [3:0] cfg_ky,
 input cfg_bayer,input [1:0] cfg_order,input cfg_gswap,
 input [15:0] cfg_gmax,output cfg_done,cfg_error,
 input g_valid,output g_ready,
 input [1:0] g_phase,input [3:0] g_row,input [4:0] g_col,
 input [15:0] g_data,output g_error,output o_error);
lsc_stream #(.BITS({b})) dut(clk,rst_n,s_tdata,s_tvalid,s_tuser,s_tlast,
 s_tready,m_tdata,m_tvalid,m_tuser,m_tlast,m_tready,
 cfg_valid,cfg_ready,cfg_width,cfg_height,cfg_gw,cfg_gh,cfg_kx,cfg_ky,
 cfg_bayer,cfg_order,cfg_gswap,cfg_gmax,cfg_done,cfg_error,
 g_valid,g_ready,g_phase,g_row,g_col,g_data,g_error,o_error);
endmodule
"""


def main():
    out = HERE / 'evidence' / (
        'synth_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True)
    src = out / 'sources'
    src.mkdir()
    files = [HERE / 'rtl/lsc_stream.sv', HERE / 'synth_lsc.py']
    for f in files:
        shutil.copy2(f, src / f.name)
    (out / 'hashes.json').write_text(json.dumps(
        {f.name: hashlib.sha256(f.read_bytes()).hexdigest()
         for f in files}, indent=2))
    env = dict(os.environ)
    cad = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
    env['PATH'] = (str(cad / 'bin') + os.pathsep + str(cad / 'lib')
                   + os.pathsep + env['PATH'])
    yosys = shutil.which('yosys', path=env['PATH'])
    results = []
    for bits in (8, 10):
        case = out / f'bits{bits}'
        case.mkdir()
        (case / 'top.v').write_text(WRAPPER.format(b=bits))
        script = (f'read_verilog -sv "{(src / "lsc_stream.sv").resolve().as_posix()}"\n'
                  f'read_verilog "{(case / "top.v").resolve().as_posix()}"\n'
                  'synth_gowin -top lsc_synth_top -json mapped.json\nstat\n')
        (case / 'build.ys').write_text(script)
        run = subprocess.run([yosys, '-s', 'build.ys'], cwd=case, env=env,
                             capture_output=True, text=True, timeout=600)
        (case / 'synth.log').write_text(run.stdout + run.stderr)
        assert run.returncode == 0, run.stdout[-2000:]
        net = json.loads((case / 'mapped.json').read_text())
        cells = Counter(c['type'] for c in
                        net['modules']['lsc_synth_top']['cells'].values())
        assert not any('LATCH' in t.upper() for t in cells)
        row = dict(bits=bits,
                   LUT=sum(cells.get('LUT' + str(i), 0) for i in range(1, 5))
                       + cells.get('LUT5', 0) + cells.get('LUT6', 0)
                       + cells.get('LUT7', 0) + cells.get('LUT8', 0)
                       + cells.get('MUX2_LUT5', 0),
                   FF=sum(n for t, n in cells.items() if t.startswith('DFF')),
                   BSRAM=sum(cells.get(t, 0) for t in
                             ('DPX9B', 'SPX9', 'SDPX9B', 'DPB', 'SP', 'SDPB',
                              'DPX9', 'SPX9A')),
                   DSP=sum(n for t, n in cells.items()
                           if t.startswith(('MULT', 'PADD', 'ALU54'))),
                   ALU=cells.get('ALU', 0),
                   raw_cells=dict(cells), status='SYNTHESIS PASS',
                   timing='NOT RUN', board='NOT RUN')
        (case / 'resources.json').write_text(json.dumps(row, indent=2))
        results.append(row)
        print('bits', row['bits'], 'LUT', row['LUT'], 'FF', row['FF'],
              'DSP', row['DSP'], 'BSRAM', row['BSRAM'], 'ALU', row['ALU'],
              flush=True)
    (out / 'summary.json').write_text(json.dumps(results, indent=2))
    print(out)


if __name__ == '__main__':
    main()
