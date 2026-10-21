"""Core-only Gowin synthesis of bilateral_stream (yosys synth_gowin, no -family)."""
import datetime
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
from collections import Counter

HERE = pathlib.Path(__file__).resolve().parent   # isp/bilateral
LIB = HERE.parents[1]                            # dsp_isp_library
ROOT = LIB.parents[1]                            # repo root
INFRA_WIN = LIB / 'infra' / 'window'
INFRA_DIV = LIB / 'infra' / 'fixedpoint' / 'rtl'

WRAPPER = """module bilateral_synth_top(
 input clk,rst_n,
 input [{b}-1:0] s_tdata,input s_tvalid,s_tuser,s_tlast,output s_tready,
 output [{b}-1:0] m_tdata,output m_tvalid,m_tuser,m_tlast,input m_tready,
 input cfg_valid,output cfg_ready,
 input cfg_bypass,cfg_lswap,input [5:0] cfg_rsvd,
 output cfg_done,cfg_error,
 input lt_valid,output lt_ready,input [6:0] lt_addr,input [7:0] lt_data,
 output lt_error,output o_error);
bilateral_stream #(.BITS({b}),.WIDTH({w}),.HEIGHT({h})) dut(
 clk,rst_n,s_tdata,s_tvalid,s_tuser,s_tlast,s_tready,
 m_tdata,m_tvalid,m_tuser,m_tlast,m_tready,
 cfg_valid,cfg_ready,cfg_bypass,cfg_lswap,cfg_rsvd,cfg_done,cfg_error,
 lt_valid,lt_ready,lt_addr,lt_data,lt_error,o_error);
endmodule
"""


def main():
    out = HERE / 'evidence' / (
        'synth_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True)
    src = out / 'sources'
    src.mkdir()
    files = [HERE / 'rtl/bilateral_stream.sv',
             INFRA_WIN / 'stream_window.v',
             INFRA_WIN / 'stream_window_padded.v',
             INFRA_DIV / 'recip_div.sv',
             HERE / 'synth_bilateral.py']
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
    for bits, w, h in [(8, 32, 24), (10, 32, 24), (8, 320, 240)]:
        tag = f'bits{bits}_w{w}h{h}'
        case = out / tag
        case.mkdir()
        (case / 'top.v').write_text(WRAPPER.format(b=bits, w=w, h=h))
        reads = '\n'.join(
            f'read_verilog {"-sv" if f.suffix == ".sv" else ""} '
            f'"{(src / f.name).resolve().as_posix()}"'
            for f in files[:4])
        script = (reads + '\n'
                  f'read_verilog "{(case / "top.v").resolve().as_posix()}"\n'
                  'synth_gowin -top bilateral_synth_top -json mapped.json\n'
                  'stat\n')
        (case / 'build.ys').write_text(script)
        run = subprocess.run([yosys, '-s', 'build.ys'], cwd=case, env=env,
                             capture_output=True, text=True, timeout=900)
        (case / 'synth.log').write_text(run.stdout + run.stderr)
        assert run.returncode == 0, run.stdout[-2000:]
        net = json.loads((case / 'mapped.json').read_text())
        cells = Counter(c['type'] for c in
                        net['modules']['bilateral_synth_top']['cells'].values())
        assert not any('LATCH' in t.upper() for t in cells)
        row = dict(bits=bits, width=w, height=h,
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
        print(tag, 'LUT', row['LUT'], 'FF', row['FF'], 'DSP', row['DSP'],
              'BSRAM', row['BSRAM'], 'ALU', row['ALU'], flush=True)
    (out / 'summary.json').write_text(json.dumps(results, indent=2))
    print(out)


if __name__ == '__main__':
    main()
