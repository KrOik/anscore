from run_tests import *
import re
profiles=[]
for w,h,pw in [(8,8,24),(32,32,24),(64,64,24),(256,16,24),(64,48,32),(5,7,24)]:
 with tempfile.TemporaryDirectory(prefix='video_frc_synth_') as td:
  p=Path(td);(p/'run.ys').write_text(f'read_verilog -sv {RTL.as_posix()}\nchparam -set MAX_WIDTH {w} -set MAX_HEIGHT {h} -set PIXEL_W {pw} video_frame_rate_converter\nsynth_gowin -top video_frame_rate_converter -nodsp\ncheck -assert\nstat\n');log=H/f'synthesis_{w}x{h}_p{pw}.log';out=execute(['yosys','-Q','-T','-s',p/'run.ys'],H,log,timeout=600);mark='=== video_frame_rate_converter ===';stats=out[out.rfind(mark):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stats,re.M)};lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if 'DSP' in k or 'MULT' in k or k in ('ALU54D','PADD9','PADD18'));bram=2*sum(v for k,v in cells.items() if k in ('SP','SPX9','DPB','DPX9B','SDPB','SDPX9B','ROM','ROMX9'));assert lut<=15000 and dsp<=4 and bram<=46
  row=dict(module='video_frame_rate_converter',max_width=w,max_height=h,pixel_w=pw,cells=cells,lut_class=lut,dsp=dsp,bram9=bram,report_sha256=hashlib.sha256(log.read_bytes()).hexdigest());profiles.append(row);print(json.dumps(row),flush=True)
(H/'synthesis.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),profiles=profiles),indent=2)+'\n')
