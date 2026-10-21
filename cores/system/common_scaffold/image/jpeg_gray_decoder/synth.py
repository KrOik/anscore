import tempfile,json,re,hashlib
from pathlib import Path
from run_tests import HERE,RTL,execute,hashes
frozen=hashes()
with tempfile.TemporaryDirectory(prefix='jpeg_gray_synth_') as tmp:
 d=Path(tmp);(d/'run.ys').write_text('read_verilog -sv '+RTL.as_posix()+'''\nsynth_gowin -top jpeg_gray_decoder -nodsp\ncheck -assert\nstat\n''')
 text=execute(['yosys','-Q','-T','-s',d/'run.ys'],HERE.parents[3],d/'yosys.log',timeout=600)
 (HERE/'synthesis.log').write_text(text)
 stats=text[text.rfind('=== jpeg_gray_decoder ==='):];print(stats)
 cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stats,re.M)}
 lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))
 lutram=sum(v*4 for k,v in cells.items() if k=='RAM16SDP4')
 lut+=lutram
 dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k)
 assert lut<=15000 and dsp<=4,(lut,dsp)
 assert hashes()==frozen
 (HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',sources=frozen,lut_class_including_lutram=lut,lutram_equivalent=lutram,dsp=dsp,cells=cells,stats=stats),indent=2)+'\n')

