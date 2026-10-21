from run_tests import *
HERE=H
import re,hashlib

def main():
 rows=[]
 for name,w,h in [('small',8,8),('default',64,64),('maximum',128,128)]:
  with tempfile.TemporaryDirectory(prefix='bmp_index_synth_') as tmp:
   p=Path(tmp);src=[HERE/'bmp_indexed_decoder.sv']
   script='read_verilog -sv '+' '.join(x.as_posix() for x in src)+'\n'
   script+=f'chparam -set MAX_WIDTH {w} -set MAX_HEIGHT {h} bmp_indexed_decoder\nsynth_gowin -top bmp_indexed_decoder -nodsp\ncheck -assert\nstat\n'
   (p/'run.ys').write_text(script);log=HERE/f'synthesis_{name}.log'
   out=execute(['yosys','-Q','-T','-s',p/'run.ys'],p,log,timeout=900)
   assert '=== design hierarchy ===' in out and 'Found and reported 0 problems.' in out
   stats=out[out.rfind('=== design hierarchy ==='):]
   cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Z][A-Z0-9_]*)\s*$',stats,re.M)}
   isdsp=lambda k:'DSP' in k or 'MULT' in k or k in ('ALU54D','PADD9','PADD18')
   lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')) and not isdsp(k))+4*cells.get('RAM16SDP4',0)
   dsp=sum(v for k,v in cells.items() if isdsp(k));bram9=2*sum(v for k,v in cells.items() if k in ('SP','SPX9','DPB','DPX9B','SDPB','SDPX9B','ROM','ROMX9'))
   assert cells and lut<=15000 and dsp<=4 and bram9<=46,(lut,dsp,bram9)
   row=dict(status='PASS',profile=name,width=w,height=h,cells=cells,lut_class=lut,dsp=dsp,bram9=bram9,log_filename=log.name,report_sha256=hashlib.sha256(log.read_bytes()).hexdigest());rows.append(row);print(row,flush=True)
 (HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',full_hierarchy=True,profiles=rows),indent=2))
if __name__=='__main__':main()
