from run_tests import HERE,SOURCES,execute
from pathlib import Path
import tempfile,json,hashlib,re
def main():
 hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES};rows=[]
 for source in SOURCES:
  top=source.stem
  with tempfile.TemporaryDirectory(prefix='tmds_synth_') as tmp:
   d=Path(tmp);ys=d/'run.ys';ys.write_text(f'read_verilog -sv {source.as_posix()}\nsynth_gowin -top {top} -nodsp\ncheck -assert\nstat\n');name=f'synthesis_{top}.log';out=execute(['yosys','-Q','-T','-s',ys],d,HERE/name,timeout=300)
   tail=out[out.rfind('=== '+top+' ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',tail,re.M)}
   lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k);bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9','ROM','ROMX9']);assert cells and lut<=15000 and dsp<=4 and bram<=46
   row=dict(module=top,cells=cells,lut_class=lut,dsp=dsp,bram9=bram,log_filename=name,report_sha256=hashlib.sha256((HERE/name).read_bytes()).hexdigest());rows.append(row);print(json.dumps(row),flush=True)
 assert hashes=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
 (HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',sources=hashes,profiles=rows,scope='Isolated Gowin synthesis only, no physical serializer/routing/board claim'),indent=2)+'\n')
if __name__=='__main__':main()
