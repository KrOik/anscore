from pathlib import Path
import sys,tempfile,json,re
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
with tempfile.TemporaryDirectory(prefix='asrc_synth_') as td:
 text=execute(['yosys','-p',f'read_verilog -sv {(HERE/"asrc_linear.sv").as_posix()}; synth_gowin -top asrc_linear -noalu -nodsp; stat'],td,HERE/'synthesis.log',timeout=300)
 (HERE/'synthesis.json').write_text(json.dumps({'status':'PASS','config':'BITS=16 FRAC=12 FIFO_ADDR=4','flow':'synth_gowin -noalu -nodsp','board':False,'pnr':False,'note':'hierarchical totals in synthesis.log'},indent=2)+'\n')
