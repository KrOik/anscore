from test_temperature import *
import re
def main():
 frozen=hashes();rows=[]
 for hz,timeout in [(1000000,1),(27000000,800000),(250000000,10000000)]:
  with tempfile.TemporaryDirectory(prefix='ds18_synth_') as tmp:
   p=Path(tmp);(p/'run.ys').write_text(f'read_verilog -sv {SOURCE.as_posix()}\nchparam -set CLK_HZ {hz} -set CONVERSION_TIMEOUT_US {timeout} ds18b20_temperature\nsynth_gowin -top ds18b20_temperature -nodsp\ncheck -assert\nstat\n')
   out=execute(['yosys','-Q','-T','-s',p/'run.ys'],p,p/'yosys.log',timeout=120)
   log=HERE/f'synthesis_hz{hz}_t{timeout}.log';log.write_text(out);stat=out[out.rfind('=== ds18b20_temperature ==='):]
   cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stat,re.M)}
   lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0)
   dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k)
   bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9'])
   assert 0<lut<=15000 and dsp<=4 and bram<=46
   row=dict(module='ds18b20_temperature',parameters=dict(CLK_HZ=hz,CONVERSION_TIMEOUT_US=timeout),cells=cells,lut_class=lut,dsp=dsp,bram9=bram,log_filename=log.name,report_sha256=hashlib.sha256(log.read_bytes()).hexdigest());rows.append(row);print(json.dumps(row),flush=True)
 assert hashes()==frozen
 (HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
