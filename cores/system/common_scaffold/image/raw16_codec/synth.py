from run_tests import *
import re
profiles=[]
for module,endian in [(m,e) for m in ('raw16_pack','raw16_unpack') for e in (0,1)]:
 with tempfile.TemporaryDirectory(prefix='raw16_synth_') as td:
  p=Path(td);(p/'run.ys').write_text(f'read_verilog -sv {(H/(module+".sv")).as_posix()}\nchparam -set BIG_ENDIAN {endian} {module}\nsynth_gowin -top {module} -nodsp\ncheck -assert\nstat\n');log=H/f'synthesis_{module}_e{endian}.log';out=execute(['yosys','-Q','-T','-s',p/'run.ys'],H,log,timeout=600);mark='=== '+module+' ===';stats=out[out.rfind(mark):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stats,re.M)};lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if 'DSP' in k or 'MULT' in k or k in ('ALU54D','PADD9','PADD18'));bram=2*sum(v for k,v in cells.items() if k in ('SP','SPX9','DPB','DPX9B','SDPB','SDPX9B','ROM','ROMX9'));assert lut<=15000 and dsp<=4 and bram<=46
  row=dict(module=module,pixel_bits=16,big_endian=endian,cells=cells,lut_class=lut,dsp=dsp,bram9=bram,report_sha256=hashlib.sha256(log.read_bytes()).hexdigest());profiles.append(row);print(json.dumps(row),flush=True)
(H/'synthesis.json').write_text(json.dumps(dict(status='PASS',sources=SOURCES,profiles=profiles,scope='Two byte orders for each16-bit top; four genuine legal profiles.'),indent=2)+'\n')
