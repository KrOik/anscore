"""Core-only Gowin synthesis of remap_stream (yosys synth_gowin,
no -family flag).  Reports LUT/FF/DSP/BSRAM-class cell counts including
the frame-RAM and lens-mesh RAM mappings for representative
(BITS, MAX_W, MAX_H, LXMAX) configs."""
import datetime
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
from collections import Counter

HERE = pathlib.Path(__file__).resolve().parent   # isp/remap
LIB = HERE.parents[1]
ROOT = LIB.parents[1]                             # repo root

WRAPPER = """module remap_synth_top(
 input clk,rst_n,
 input [{b}-1:0] s_tdata,input s_tvalid,s_tuser,s_tlast,output s_tready,
 output [{b}-1:0] m_tdata,output m_tvalid,m_tuser,m_tlast,input m_tready,
 input cfg_valid,output cfg_ready,input [319:0] cfg_data,
 output cfg_done,cfg_error,
 input l_valid,output l_ready,input [4:0] l_row,input [4:0] l_col,
 input [53:0] l_data,output l_error,o_error,busy);
remap_stream #(.BITS({b}),.MAX_W({w}),.MAX_H({h}),.LXMAX({lx}),.LYMAX({ly}))
 dut(clk,rst_n,s_tdata,s_tvalid,s_tuser,s_tlast,s_tready,
 m_tdata,m_tvalid,m_tuser,m_tlast,m_tready,
 cfg_valid,cfg_ready,cfg_data,cfg_done,cfg_error,
 l_valid,l_ready,l_row,l_col,l_data,l_error,o_error,busy);
endmodule
"""


def main():
    out = HERE / 'evidence' / (
        'synth_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True)
    src = out / 'sources'
    src.mkdir()
    files = [HERE / 'rtl/remap_stream.sv',
             LIB / 'infra/fixedpoint/rtl/recip_div.sv',
             HERE / 'synth_remap.py']
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
    for bits, mw, mh, lx, ly in [(8, 128, 128, 17, 17),
                                 (10, 128, 128, 17, 17),
                                 (8, 32, 24, 9, 9)]:
        case = out / f'b{bits}_w{mw}h{mh}_l{lx}'
        case.mkdir()
        (case / 'top.v').write_text(WRAPPER.format(b=bits, w=mw, h=mh,
                                                  lx=lx, ly=ly))
        script = (f'read_verilog -sv "{(src / "recip_div.sv").resolve().as_posix()}"\n'
                  f'read_verilog -sv "{(src / "remap_stream.sv").resolve().as_posix()}"\n'
                  f'read_verilog "{(case / "top.v").resolve().as_posix()}"\n'
                  'synth_gowin -top remap_synth_top -json mapped.json\n'
                  'stat\n')
        (case / 'build.ys').write_text(script)
        run = subprocess.run([yosys, '-s', 'build.ys'], cwd=case, env=env,
                             capture_output=True, text=True, timeout=900)
        (case / 'synth.log').write_text(run.stdout + run.stderr)
        assert run.returncode == 0, run.stdout[-3000:]
        net = json.loads((case / 'mapped.json').read_text())
        cells = Counter(c['type'] for c in
                        net['modules']['remap_synth_top']
                        ['cells'].values())
        assert not any('LATCH' in t.upper() for t in cells)
        row = dict(bits=bits, max_w=mw, max_h=mh, lxmax=lx, lymax=ly,
                   frame_ram_bits=mh * mw * bits,
                   mesh_ram_bits=lx * ly * 54,
                   LUT=sum(cells.get('LUT' + str(i), 0) for i in range(1, 5))
                       + cells.get('LUT5', 0) + cells.get('LUT6', 0)
                       + cells.get('LUT7', 0) + cells.get('LUT8', 0)
                       + cells.get('MUX2_LUT5', 0),
                   FF=sum(n for t, n in cells.items()
                          if t.startswith('DFF')),
                   BSRAM=sum(cells.get(t, 0) for t in
                             ('DPX9B', 'SPX9', 'SDPX9B', 'DPB', 'SP',
                              'SDPB', 'DPX9', 'SPX9A', 'RAM16S', 'RAM16')),
                   DSP=sum(n for t, n in cells.items()
                           if t.startswith(('MULT', 'PADD', 'ALU54'))),
                   ALU=cells.get('ALU', 0),
                   raw_cells=dict(cells), status='SYNTHESIS PASS',
                   timing='NOT RUN', board='NOT RUN')
        (case / 'resources.json').write_text(json.dumps(row, indent=2))
        results.append(row)
        print(f'bits={bits} {mw}x{mh} mesh {lx}x{ly}: LUT {row["LUT"]} '
              f'FF {row["FF"]} DSP {row["DSP"]} BSRAM {row["BSRAM"]} '
              f'ALU {row["ALU"]}', flush=True)
    (out / 'summary.json').write_text(json.dumps(results, indent=2))
    print(out)


if __name__ == '__main__':
    main()
