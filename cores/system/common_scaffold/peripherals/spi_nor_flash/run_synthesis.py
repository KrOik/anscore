from pathlib import Path
import sys,tempfile,re,json,hashlib
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import execute
rtl=H/'spi_nor_flash.sv';rows=[]
for name,parameters in [('default',{}),('maximum',dict(CLOCK_DIV=65535,SPI_MODE=3,CS_HIGH_CYCLES=65535,HOST_TIMEOUT=2147483647,POLL_LIMIT=2147483647))]:
 with tempfile.TemporaryDirectory(prefix='nor_synth_') as td:
  p=Path(td);config=' '.join(f'-set {k} {v}' for k,v in parameters.items())
  text=f'read_verilog -sv {rtl.as_posix()}\n'
  if config:text+=f'chparam {config} spi_nor_flash\n'
  text+='synth_gowin -top spi_nor_flash -nodsp\ncheck -assert\nstat\n'
  (p/'s.ys').write_text(text,encoding='utf-8');out=execute(['yosys','-s',p/'s.ys'],H,p/'s.log',timeout=600)
  tail=out[out.rfind('=== spi_nor_flash ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',tail,re.M)}
  lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k)
  bram=sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9'])
  log_path=H/f'synthesis_{name}.log'
  log_path.write_text(out,encoding='utf-8')
  rows.append(dict(log=log_path.name,log_sha256=hashlib.sha256(log_path.read_bytes()).hexdigest(),profile=name,parameters=parameters,cells=cells,lut_class=lut,dsp=dsp,bram=bram,status='PASS' if lut<=15000 and dsp<=4 else 'FAIL'))
  print(name,lut,dsp,bram,flush=True)
(H/'synthesis_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(rtl.read_bytes()).hexdigest(),profiles=rows),indent=2)+'\n',encoding='utf-8')
