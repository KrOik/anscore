from test_lcd8080 import *
import re
def main():
 frozen=hashes();rows=[]
 for width,cw in [(8,16),(16,24)]:
  with tempfile.TemporaryDirectory(prefix='lcd8080_synth_',dir=os.environ.get('TEMP')) as td:
   p=Path(td);(p/'run.ys').write_text(f'read_verilog -sv {SOURCE.as_posix()}\nchparam -set BUS_WIDTH {width} -set COUNT_W {cw} lcd8080_engine\nsynth_gowin -top lcd8080_engine -nodsp\ncheck -assert\nstat\n')
   out=execute([tool('yosys'),'-Q','-T','-s',p/'run.ys'],HERE,p/'yosys.log',timeout=120)
   log=HERE/f'synthesis_w{width}_c{cw}.log';log.write_text(out);stat=out[out.rfind('=== lcd8080_engine ==='):]
   cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stat,re.M)}
   lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0)
   dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k)
   bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9'])
   assert 0<lut<=15000 and dsp<=4 and bram<=46
   row=dict(module='lcd8080_engine',parameters=dict(BUS_WIDTH=width,COUNT_W=cw),cells=cells,lut_class_including_lutram=lut,dsp=dsp,bram9=bram,log_filename=log.name,report_sha256=hashlib.sha256(log.read_bytes()).hexdigest());rows.append(row);print(json.dumps(row))
 assert hashes()==frozen
 (HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
