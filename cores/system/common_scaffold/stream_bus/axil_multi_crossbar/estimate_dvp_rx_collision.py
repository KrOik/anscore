"""Temporary-copy only design estimate; never edits old DVP production files."""
from pathlib import Path
import sys,tempfile,hashlib,json,re
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
ORIGINAL=HERE.parents[1]/'image/dvp_rx/dvp_rx.sv'
def main():
 original=ORIGINAL.read_bytes();sha=hashlib.sha256(original).hexdigest()
 text=original.decode().replace('$clog2(FIFO_DEPTH);','$clog2(FIFO_DEPTH+1);').replace('mem[0:FIFO_DEPTH-1]','mem[0:FIFO_DEPTH]').replace('wp==FIFO_DEPTH-1','wp==FIFO_DEPTH').replace('rp==FIFO_DEPTH-1','rp==FIFO_DEPTH')
 assert text!=original.decode() and 'mem[0:FIFO_DEPTH]' in text
 rows=[]
 for depth in [1024,4096]:
  with tempfile.TemporaryDirectory(prefix='dvp_rx_spare_plan_') as tmp:
   d=Path(tmp);rtl=d/'dvp_rx.sv';rtl.write_text(text);ys=d/'run.ys'
   ys.write_text(f'read_verilog -sv {rtl.as_posix()}\nchparam -set FIFO_DEPTH {depth} dvp_rx\nsynth_gowin -top dvp_rx -nodsp\ncheck -assert\nstat\n')
   name=f'dvp_rx_spare_estimate_{depth}.log';out=execute(['yosys','-Q','-T','-s',ys],d,HERE/name,timeout=600)
   tail=out[out.rfind('=== dvp_rx ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',tail,re.M)}
   lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0)
   dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k)
   bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9','ROM','ROMX9'])
   assert lut<=15000 and dsp<=4 and bram<=46
   rows.append(dict(logical_fifo_depth=depth,physical_words=depth+1,cells=cells,lut_class=lut,dsp=dsp,bram9=bram,log_filename=name,report_sha256=hashlib.sha256((HERE/name).read_bytes()).hexdigest()))
   print(json.dumps(rows[-1]),flush=True)
 assert ORIGINAL.read_bytes()==original
 (HERE/'dvp_rx_collision_estimate.json').write_text(json.dumps(dict(status='ESTIMATE_ONLY_NOT_IMPLEMENTED',original_rtl_sha256=sha,temporary_candidate_sha256=hashlib.sha256(text.encode()).hexdigest(),production_file_unchanged=True,profiles=rows,scope='Isolated synthesis of temporary what-if copy only. Not functionally validated, not a production repair, not board/timing evidence.'),indent=2)+'\n')
if __name__=='__main__':main()
