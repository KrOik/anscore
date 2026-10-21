from pathlib import Path
import sys,tempfile,json,re
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[2]))
from integration.tooling import execute
with tempfile.TemporaryDirectory(prefix='chroma420_synth_') as td:
 p=Path(td)
 command=f'read_verilog -sv { (HERE/"chroma_420_to_444.sv").as_posix() }; synth_gowin -top chroma_420_to_444 -noalu -nodsp; stat'
 text=execute(['yosys','-p',command],p,HERE/'synthesis.log',timeout=300)
 last=text.rsplit('=== chroma_420_to_444 ===',1)[1]
 cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+(\w+)\s*$',last,re.M)}
 summary={'config':'BITS=8 WIDTH=8 HEIGHT=6','flow':'synth_gowin -noalu -nodsp','status':'PASS','pnr':False,'board':False,'cells':cells,
 'lut1_4':sum(cells.get('LUT'+str(i),0) for i in range(1,5)),
 'ff':sum(n for name,n in cells.items() if name.startswith('DFF')),
 'DSP':sum(n for name,n in cells.items() if name.startswith(('MULT','DSP')))}
 (HERE/'synthesis.json').write_text(json.dumps(summary,indent=2)+'\n')
