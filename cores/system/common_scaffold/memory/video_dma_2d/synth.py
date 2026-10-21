import tempfile,json,re,hashlib
from pathlib import Path
from run_tests import HERE,RTL,tool_execute
def main():
 rows=[]
 for burst in (16,256):
  with tempfile.TemporaryDirectory(prefix='video_dma_synth_') as tmp:
   d=Path(tmp);script=d/'run.ys'
   script.write_text(f'read_verilog {RTL.as_posix()}\nchparam -set MAX_BURST {burst} video_dma_2d_axi32\nsynth_gowin -top video_dma_2d_axi32 -nodsp\ncheck -assert\nstat\n')
   out=tool_execute(['yosys','-Q','-T','-s',script],HERE,d/'log',timeout=600)
   (HERE/f'synthesis_{burst}.log').write_text(out)
  stats=out[out.rfind('=== video_dma_2d_axi32 ==='):]
  cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stats,re.M)}
  lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0)
  dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k)
  bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9'])
  assert cells and lut<=15000 and dsp<=4 and bram<=46
  rows.append(dict(max_burst=burst,cells=cells,lut_class=lut,dsp=dsp,bram9=bram))
  print(rows[-1],flush=True)
 (HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
