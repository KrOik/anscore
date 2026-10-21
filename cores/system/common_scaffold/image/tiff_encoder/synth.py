from run_tests import *
import re
def main():
 frozen=hashes();profiles=[]
 for w,h,r in [(16,12,4),(64,32,7)]:
  with tempfile.TemporaryDirectory(prefix='tiff_synth_') as tmp:
   d=Path(tmp);(d/'run.ys').write_text(f'read_verilog -sv {RTL.as_posix()}\nchparam -set WIDTH {w} -set HEIGHT {h} -set ROWS_PER_STRIP {r} tiff_encoder\nsynth_gowin -top tiff_encoder -nodsp\ncheck -assert\nstat\n')
   out=execute(['yosys','-Q','-T','-s',d/'run.ys'],HERE,d/'yosys.log',timeout=600);log=HERE/f'synthesis_{w}x{h}.log';log.write_text(out)
   stat=out[out.rfind('=== tiff_encoder ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stat,re.M)}
   lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k);bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9'])
   row=dict(width=w,height=h,rows_per_strip=r,cells=cells,lut_class_including_lutram=lut,dsp=dsp,bram9=bram,report_sha256=hashlib.sha256(log.read_bytes()).hexdigest());profiles.append(row);print(json.dumps(row),flush=True);assert lut<=15000 and dsp<=4 and bram<=46
 assert hashes()==frozen
 (HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=profiles),indent=2)+'\n')
if __name__=='__main__':main()
