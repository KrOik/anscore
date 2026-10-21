"""Isolated complete scheduler+physical engine Gowin synthesis."""
from test_transactions import *
import re

def main():
 frozen=hashes();rows=[]
 for label,ab,cap,page,half,stretch,polls,gap,host in [('small',1,256,8,6,80,5,8,600),('default',2,32768,64,68,270000,100,270,27000000),('max',2,65536,256,65536,1000000,65535,65536,100000000)]:
  with tempfile.TemporaryDirectory(prefix='i2c_eeprom_synth_') as tmp:
   p=Path(tmp);ys='read_verilog -sv '+' '.join(x.as_posix() for x in SOURCES)+'\n'
   params=dict(ADDR_BYTES=ab,CAPACITY_BYTES=cap,PAGE_BYTES=page,HALF_PERIOD_CYCLES=half,STRETCH_TIMEOUT_CYCLES=stretch,POLL_LIMIT=polls,POLL_GAP_CYCLES=gap,HOST_TIMEOUT_CYCLES=host)
   ys+='chparam '+' '.join(f'-set {k} {v}' for k,v in params.items())+' i2c_eeprom\nsynth_gowin -top i2c_eeprom -nodsp\ncheck -assert\nstat\n'
   (p/'run.ys').write_text(ys,encoding='utf-8');out=execute(['yosys','-Q','-T','-s',p/'run.ys'],p,p/'yosys.log',timeout=120)
   log=HERE/('synthesis_'+label+'.log');log.write_text(out,encoding='utf-8')
   stat=out[out.rfind('=== i2c_eeprom ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stat,re.M) if k not in ('wires','ports','cells','memories','processes')}
   lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k);bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9'])
   assert 0<lut<=15000 and dsp<=4 and bram<=46
   row=dict(module='i2c_eeprom',parameters=params,cells=cells,lut_class=lut,dsp=dsp,bram9=bram,log_filename=log.name,report_sha256=hashlib.sha256(log.read_bytes()).hexdigest());rows.append(row);print(json.dumps(row),flush=True)
 assert hashes()==frozen
 (HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()

