from run_tests import HERE,RTL,execute
from pathlib import Path
import tempfile,hashlib,json,re

def main():
 sha=hashlib.sha256(RTL.read_bytes()).hexdigest();rows=[]
 for m,t,aw,dw,rb in [(2,4,16,32,13),(4,8,32,64,12),(3,3,16,32,12),(1,1,4,32,1)]:
  with tempfile.TemporaryDirectory(prefix='axil_multi_synth_') as tmp:
   d=Path(tmp);ys=d/'run.ys';ys.write_text(f'read_verilog -sv {RTL.as_posix()}\nchparam -set MASTERS {m} -set TARGETS {t} -set ADDR_WIDTH {aw} -set DATA_WIDTH {dw} -set REGION_ADDR_BITS {rb} axil_multi_crossbar\nsynth_gowin -top axil_multi_crossbar -nodsp\ncheck -assert\nstat\n')
   name=f'synthesis_{m}x{t}_{aw}_{dw}.log';out=execute(['yosys','-Q','-T','-s',ys],HERE,HERE/name,timeout=600)
   tail=out[out.rfind('=== axil_multi_crossbar ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',tail,re.M)}
   lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0)
   dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k)
   bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9','ROM','ROMX9'])
   assert cells and lut<=15000 and dsp<=4 and bram<=46
   rows.append(dict(masters=m,targets=t,addr_width=aw,data_width=dw,region_bits=rb,cells=cells,lut_class=lut,dsp=dsp,bram9=bram,log_filename=name,report_sha256=hashlib.sha256((HERE/name).read_bytes()).hexdigest()))
   print(json.dumps(rows[-1]),flush=True)
 assert sha==hashlib.sha256(RTL.read_bytes()).hexdigest()
 (HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=sha,profiles=rows,scope='Isolated Gowin synthesis; no board/P&R/timing claim'),indent=2)+'\n')
if __name__=='__main__':main()
