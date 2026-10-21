from pathlib import Path
import tempfile,re,json
from test_color_scan import HERE,SOURCES,execute
with tempfile.TemporaryDirectory(prefix='color_scan_synth_') as td:
 txt=execute(['yosys','-p','read_verilog -sv '+' '.join(p.as_posix() for p in SOURCES)+'; synth_gowin -top jpeg_color_scan -noalu -nodsp; check -assert; stat'],td,HERE/'synthesis.log',timeout=300)
 last=txt.rsplit('=== design hierarchy ===',1)[1]
 cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Za-z0-9_]*)\s*$',last,re.M)}
 result={'result':'PASS','scope':'full DCT+quant+symbols+Huffman+scan hierarchy','flow':'synth_gowin -noalu -nodsp; check -assert','cells':cells,'board':False,'pnr':False}
 (HERE/'synthesis.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
