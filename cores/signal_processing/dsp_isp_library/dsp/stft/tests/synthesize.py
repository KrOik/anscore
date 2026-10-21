"""Isolated Gowin mapping for stft_welch (both RAM styles); no P&R/board."""
import os, json, subprocess, hashlib, collections
from pathlib import Path
from datetime import datetime

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
OUT = BASE / 'evidence' / ('synth_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir()
tool = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
env['PATH'] = (str(tool / 'lib') + os.pathsep + str(tool / 'bin')
               + os.pathsep + env['PATH'])

SOURCES = [BASE / 'rtl/stft_welch.sv',
           BASE.parent / 'spectrum/rtl/window_cos_rom.sv',
           BASE.parent / 'spectrum/rtl/window_mult.sv',
           BASE.parent / 'spectrum/rtl/mag_squared.sv',
           ROOT / 'cores/signal_processing/transforms/src/fft64.v',
           ROOT / 'cores/signal_processing/transforms/src/sig_sdp_ram.v',
           ROOT / 'cores/signal_processing/transforms/src/tw_rom_cos.v',
           ROOT / 'cores/signal_processing/transforms/src/tw_rom_sin.v']

reports = []
for regs in (1, 0):
    d = OUT / str(regs)
    d.mkdir()
    reads = ' '.join('read_verilog -sv ' + s.as_posix() + ';'
                     for s in SOURCES)
    command = (reads + f' chparam -set RAM_REGS {regs} stft_welch;'
               ' synth_gowin -noalu -family gw2a -top stft_welch'
               ' -json core.json; stat')
    (d / 'command.txt').write_text(command + '\n')
    p = subprocess.run([str(tool / 'bin/yosys.exe'), '-p', command],
                       cwd=d, env=env, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT)
    (d / 'yosys.log').write_text(p.stdout)
    if p.returncode:
        raise RuntimeError(str(d))
    design = json.loads((d / 'core.json').read_text())
    # chparam makes the top a $paramod; find it by prefix
    top = next(k for k in design['modules']
               if k == 'stft_welch' or (k.startswith('$paramod')
                                        and '\\stft_welch\\' in k))
    counts = collections.Counter(
        c['type'] for c in design['modules'][top]['cells'].values())
    report = {'ram_regs': regs, 'cells': dict(counts),
              'lut1_4': sum(counts[f'LUT{k}'] for k in range(1, 5)),
              'ff': sum(v for k, v in counts.items()
                        if k.startswith('DFF')),
              'dsp': sum(v for k, v in counts.items()
                         if k.startswith(('MULT', 'PADD', 'ALU54'))),
              'bram': sum(v for k, v in counts.items()
                          if k.startswith(('DPX', 'SPX', 'SDPX'))),
              'wide_mux': sum(v for k, v in counts.items()
                              if k.startswith('MUX'))}
    (d / 'resources.json').write_text(json.dumps(report, indent=2))
    reports.append(report)

summary = {'status': 'PASS',
           'source_sha256': hashlib.sha256(
               (BASE / 'rtl/stft_welch.sv').read_bytes()).hexdigest(),
           'configurations': reports,
           'scope': 'isolated mapped resources including instantiated '
                    'window_mult/fft64/mag_squared; no board pin fit, '
                    'routed timing or physical acceptance'}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print(json.dumps(summary, indent=2))
