import tempfile,json,re
from pathlib import Path
from run_tests import HERE,RTL,execute,hashes
def main():
 frozen=hashes();rows=[]
 for w,h in [(16,12),(64,32)]:
  with tempfile.TemporaryDirectory(prefix='bmp_encode_synth_') as tmp:
   d=Path(tmp);(d/'r.ys').write_text('read_verilog -sv '+RTL.as_posix()+f'\nchparam -set WIDTH {w} -set HEIGHT {h} bmp_encoder\nsynth_gowin -top bmp_encoder -nodsp\ncheck -assert\nstat\n')
   out=execute(['yosys','-Q','-T','-s',d/'r.ys'],HERE,d/'log',timeout=600);(HERE/f'synthesis_{w}x{h}.log').write_text(out)
   stats=out[out.rfind('=== bmp_encoder ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stats,re.M)}
   lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0)
   dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k)
   blocks=sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9'])
   row=dict(width=w,height=h,cells=cells,lut_class_including_lutram=lut,dsp=dsp,conservative_bram9=2*blocks);rows.append(row);print(json.dumps(row),flush=True)
   assert lut<=15000 and dsp<=4 and 2*blocks<=46
 assert hashes()==frozen
 (HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
