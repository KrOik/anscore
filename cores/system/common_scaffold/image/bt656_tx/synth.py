"""Isolated Gowin synthesis; all block primitives count as two BRAM9 units."""
from run_tests import HERE,RTL,execute
from pathlib import Path
import hashlib,json,re,tempfile
def main():
 source_sha=hashlib.sha256(RTL.read_bytes()).hexdigest();profiles=[]
 for mw,mn in [(720,288),(32766,32767)]:
  with tempfile.TemporaryDirectory(prefix='bt656_tx_synth_') as temp:
   d=Path(temp);script=d/'run.ys';script.write_text(f'read_verilog -sv {RTL.as_posix()}\nchparam -set MAX_WIDTH {mw} -set MAX_FIELD_LINES {mn} bt656_tx\nsynth_gowin -top bt656_tx -nodsp\ncheck -assert\nstat\n')
   out=execute(['yosys','-Q','-T','-s',script],HERE,HERE/f'synthesis_{mw}_{mn}.log',timeout=600)
   stats=out[out.rfind('=== bt656_tx ==='):]
   cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stats,re.M)}
   lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0)
   dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k)
   bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9','ROM','ROMX9'])
   assert cells and lut<=15000 and dsp<=4 and bram<=46
   profiles.append(dict(max_width=mw,max_field_lines=mn,lut_class_including_lutram=lut,dsp=dsp,conservative_bram9_units=bram,cells=cells))
   print(json.dumps(profiles[-1]),flush=True)
 assert source_sha==hashlib.sha256(RTL.read_bytes()).hexdigest()
 (HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',source_sha256=source_sha,scope='Isolated synthesis only; no P&R, board or physical camera claim',profiles=profiles),indent=2)+'\n')
if __name__=='__main__':main()
