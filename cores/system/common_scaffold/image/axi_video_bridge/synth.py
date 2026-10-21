from run_tests import *
import re
def main():
 frozen=hashes();rows=[]
 for source in SOURCES:
  for w,h,dw in [(16,12,24),(4096,4096,64)]:
   top=source.stem
   with tempfile.TemporaryDirectory(prefix='axi_video_synth_') as tmp:
    p=Path(tmp);(p/'run.ys').write_text(f'read_verilog -sv {source.as_posix()}\nchparam -set WIDTH {w} -set HEIGHT {h} -set DATA_WIDTH {dw} {top}\nsynth_gowin -top {top} -nodsp\ncheck -assert\nstat\n');out=execute(['yosys','-Q','-T','-s',p/'run.ys'],HERE,p/'yosys.log',timeout=600)
    log=HERE/f'synthesis_{top}_{w}x{h}_{dw}.log';log.write_text(out);stat=out[out.rfind('=== '+top+' ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stat,re.M)}
    lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k);bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9'])
    row=dict(top=top,module=top,log_filename=log.name,width=w,height=h,data_width=dw,cells=cells,lut_class_including_lutram=lut,dsp=dsp,bram9=bram,report_sha256=hashlib.sha256(log.read_bytes()).hexdigest());rows.append(row);print(json.dumps(row),flush=True);assert lut<=15000 and dsp<=4 and bram<=46
 assert hashes()==frozen
 (HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
