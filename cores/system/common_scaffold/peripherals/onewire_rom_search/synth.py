from run_tests import *
import re
profiles=[]
for depth in [1,16,65535]:
 with tempfile.TemporaryDirectory(prefix='onewire_rom_search_synth_') as td:
  d=Path(td);(d/'run.ys').write_text(f'read_verilog -sv {RTL.as_posix()}\nchparam -set MAX_DEVICES {depth} onewire_rom_search\nsynth_gowin -top onewire_rom_search -nodsp\ncheck -assert\nstat\n');log=H/f'synthesis_{depth}.log';out=execute(['yosys','-Q','-T','-s',d/'run.ys'],H,log,timeout=600)
  stats=out[out.rfind('=== onewire_rom_search ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stats,re.M)};lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);bram=sum(v*2 for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9']);dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k)
  row=dict(max_devices=depth,module="onewire_rom_search",cells=cells,lut_class=lut,dsp=dsp,bram9=bram,report_sha256=hashlib.sha256(log.read_bytes()).hexdigest());profiles.append(row);print(json.dumps(row),flush=True);assert lut<=15000 and dsp<=4 and bram<=46
(H/'synthesis.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),profiles=profiles),indent=2)+'\n')
