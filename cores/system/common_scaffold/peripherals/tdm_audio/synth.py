from run_tests import *
import re
def main():
 rows=[];source=hashes()
 for rtl in SOURCES:
  for label,params in [('default',{}),('max',dict(SLOTS=16,SLOT_BITS=32,SAMPLE_BITS=32,FIFO_FRAMES=8)),('slot24',dict(SLOTS=8,SLOT_BITS=24,SAMPLE_BITS=20))]:
   with tempfile.TemporaryDirectory(prefix='tdm_synth_') as td:
    d=Path(td);top=rtl.stem;ys=d/'run.ys';p=''.join(f'chparam -set {k} {v} {top}\n' for k,v in params.items());ys.write_text(f'read_verilog -sv {rtl.as_posix()}\n'+p+f'synth_gowin -top {top} -nodsp\ncheck -assert\nstat\n');log=H/f'synthesis_{top}_{label}.log'
    out=execute(['yosys','-Q','-T','-s',ys],d,log,timeout=600);tail=out[out.rfind('=== '+top+' ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',tail,re.M)}
    lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k);bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9','ROM','ROMX9']);assert cells and lut<=15000 and dsp<=4 and bram<=46
    r=dict(module=top,label=label,parameters=params,cells=cells,lut_class=lut,dsp=dsp,bram9=bram,log_filename=log.name,report_sha256=hashlib.sha256(log.read_bytes()).hexdigest());rows.append(r);print(json.dumps(r),flush=True)
 assert source==hashes();(H/'synthesis.json').write_text(json.dumps(dict(status='PASS',sources=source,profiles=rows,scope='Isolated native BCLK-domain synthesis, no placement/timing/board claim'),indent=2)+'\n')
if __name__=='__main__':main()
