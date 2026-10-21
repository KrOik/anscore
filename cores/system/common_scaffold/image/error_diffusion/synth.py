from pathlib import Path
import sys,tempfile,re,json
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute,ROOT
results=[]
for bits,outbits in ((8,1),(12,4)):
 with tempfile.TemporaryDirectory(prefix='floyd_synth_') as td:
  out=execute(['yosys','-p',f'read_verilog -sv {(HERE/"floyd_steinberg.sv").as_posix()}; chparam -set WIDTH 9 -set HEIGHT 7 -set BITS {bits} -set OUTPUT_BITS {outbits} floyd_steinberg; synth_gowin -top floyd_steinberg -noalu -nodsp; check; stat'],ROOT,HERE/f'synthesis_B{bits}_O{outbits}.log',timeout=300)
  final=out.rsplit('=== floyd_steinberg ===',1)[1]
  cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',final,re.M)}
  results.append({'status':'PASS','configuration':f'9x7 B{bits} O{outbits}','cells':cells,'board':False,'pnr':False})
(HERE/'synthesis.json').write_text(json.dumps(results,indent=2)+'\n');print(results)
