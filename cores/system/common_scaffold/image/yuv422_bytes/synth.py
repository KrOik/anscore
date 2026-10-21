from run_tests import *
import re
def main():
 before=hashes();rows=[]
 for name in ['yuv422_byte_packer','yuv422_byte_unpacker']:
  for w,h in [(16,12),(1920,1080)]:
   with tempfile.TemporaryDirectory(prefix='yuv422_synth_') as tmp:
    d=Path(tmp);(d/'r.ys').write_text('read_verilog -sv '+' '.join(p.as_posix() for p in RTLS)+f'\nchparam -set WIDTH {w} -set HEIGHT {h} {name}\nsynth_gowin -top {name} -nodsp\ncheck -assert\nstat\n')
    out=execute(['yosys','-Q','-T','-s',d/'r.ys'],HERE,d/'log',timeout=600);(HERE/f'synthesis_{name}_{w}x{h}.log').write_text(out)
    stats=out[out.rfind(f'=== {name} ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stats,re.M)}
    lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k);bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9'])
    assert lut<=15000 and dsp<=4 and bram<=46;rows.append(dict(module=name,width=w,height=h,cells=cells,lut_class_including_lutram=lut,dsp=dsp,conservative_bram9=bram));print(rows[-1],flush=True)
 assert hashes()==before;(HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',sources=before,profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
