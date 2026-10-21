from run_tests import *
profiles=[]
for depth in [1024,4096]:
 with tempfile.TemporaryDirectory(prefix='dvp_tx_synth_') as td:
  d=Path(td);(d/'run.ys').write_text(f'read_verilog -sv {RTL.as_posix()}\nchparam -set FIFO_DEPTH {depth} dvp_tx\nsynth_gowin -top dvp_tx -nodsp\ncheck -assert\nstat\n');log=H/f'synthesis_{depth}.log';out=execute(['yosys','-Q','-T','-s',d/'run.ys'],H,log,timeout=600)
  stats=out[out.rfind('=== dvp_tx ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stats,re.M)};lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);bram=sum(v*2 for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9']);dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k)
  row=dict(fifo_depth=depth,max_width=640,max_height=480,cells=cells,lut_class=lut,dsp=dsp,bram9=bram,report_sha256=hashlib.sha256(log.read_bytes()).hexdigest());profiles.append(row);print(json.dumps(row),flush=True);assert lut<=15000 and dsp<=4 and bram<=46
(H/'synthesis.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),profiles=profiles),indent=2)+'\n')
