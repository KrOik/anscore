"""Core-only Gowin synthesis of cca_stream (yosys synth_gowin, no -family)."""
import datetime
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
from collections import Counter

HERE = pathlib.Path(__file__).resolve().parent   # isp/cca
ROOT = HERE.parents[3]                            # repo root

WRAPPER = """module cca_synth_top(
 input clk,rst_n,
 input s_tdata,input s_tvalid,s_tuser,s_tlast,output s_tready,
 output [{rw}-1:0] m_tdata,output m_tvalid,m_tuser,m_tlast,input m_tready,
 input cfg_valid,output cfg_ready,
 input [{xw}:0] cfg_width,input [{yw}:0] cfg_height,input cfg_conn8,
 output cfg_done,cfg_error,output o_error,output busy);
cca_stream #(.W_MAX({wm}),.H_MAX({hm}),.NL({nl}),.EQT({eq})) dut(
 clk,rst_n,s_tdata,s_tvalid,s_tuser,s_tlast,s_tready,
 m_tdata,m_tvalid,m_tuser,m_tlast,m_tready,
 cfg_valid,cfg_ready,cfg_width,cfg_height,cfg_conn8,cfg_done,cfg_error,
 o_error,busy);
endmodule
"""


def widths(wm, hm, nl):
    xw = (wm - 1).bit_length() if wm > 1 else 1
    yw = (hm - 1).bit_length() if hm > 1 else 1
    lblw = (nl + 1).bit_length()
    aw = (wm * hm).bit_length()
    sw = aw + xw
    fw = aw + 2 * sw + 2 * xw + 2 * yw
    return xw, yw, lblw, lblw + fw


def main():
    out = HERE / 'evidence' / (
        'synth_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True)
    src = out / 'sources'
    src.mkdir()
    files = [HERE / 'rtl/cca_stream.sv', HERE / 'synth_cca.py']
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
    for wm, hm, nl, eqt in ((256, 256, 128, 256), (256, 256, 64, 128),
                            (64, 64, 32, 64)):
        xw, yw, lblw, rw = widths(wm, hm, nl)
        tag = f'w{wm}h{hm}nl{nl}eq{eqt}'
        case = out / tag
        case.mkdir()
        (case / 'top.v').write_text(
            WRAPPER.format(rw=rw, xw=xw, yw=yw, wm=wm, hm=hm, nl=nl, eq=eqt))
        script = (f'read_verilog -sv "{(src / "cca_stream.sv").resolve().as_posix()}"\n'
                  f'read_verilog "{(case / "top.v").resolve().as_posix()}"\n'
                  'synth_gowin -top cca_synth_top -json mapped.json\nstat\n')
        (case / 'build.ys').write_text(script)
        run = subprocess.run([yosys, '-s', 'build.ys'], cwd=case, env=env,
                             capture_output=True, text=True, timeout=900)
        (case / 'synth.log').write_text(run.stdout + run.stderr)
        assert run.returncode == 0, run.stdout[-2000:] + run.stderr[-2000:]
        net = json.loads((case / 'mapped.json').read_text())
        cells = Counter(c['type'] for c in
                        net['modules']['cca_synth_top']['cells'].values())
        assert not any('LATCH' in t.upper() for t in cells)
        row = dict(config=tag,
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
