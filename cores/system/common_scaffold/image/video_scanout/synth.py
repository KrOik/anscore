from test_timing import *
import re
def main():
 frozen=hashes();rows=[]
 for top,parameters,label in [('video_timing_generator',{},'default'),('video_timing_generator',dict(MAX_TOTAL=65535),'max'),('video_rgb_scanout',{},'default'),('video_rgb_scanout',dict(MAX_TOTAL=65535,FIFO_DEPTH=4096,PREBUFFER=16),'max')]:
  with tempfile.TemporaryDirectory(prefix='scanout_synth_') as tmp:
   p=Path(tmp);command=' '.join(f'-set {k} {v}' for k,v in parameters.items());(p/'run.ys').write_text('read_verilog -sv '+' '.join(s.as_posix() for s in SOURCES)+'\n'+(f'chparam {command} {top}\n' if command else '')+f'synth_gowin -top {top} -nodsp\ncheck -assert\nstat\n');out=execute(['yosys','-Q','-T','-s',p/'run.ys'],HERE,p/'yosys.log',timeout=600)
   log=HERE/f'synthesis_{top}_{label}.log';log.write_text(out);stat=out[out.rfind('=== '+top+' ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stat,re.M)}
   # Hierarchy totals follow the top stat when a timing child remains instantiated.
   if '=== design hierarchy ===' in stat:
    stat=stat[stat.rfind('=== design hierarchy ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stat,re.M)}
   lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k);bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9'])
   row=dict(module=top,profile=label,parameters=parameters,log_filename=log.name,cells=cells,lut_class_including_lutram=lut,dsp=dsp,bram9=bram,report_sha256=hashlib.sha256(log.read_bytes()).hexdigest());rows.append(row);print(json.dumps(row),flush=True);assert lut<=15000 and dsp<=4 and bram<=46
 assert hashes()==frozen
 (HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
