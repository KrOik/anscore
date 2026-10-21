from run_tests import *
def main():
 rows=[];frozen=hashes()
 for cw,gw,fw in [(8,8,1),(32,32,8),(48,48,16)]:
  with tempfile.TemporaryDirectory(prefix='freq_synth_') as td:
   p=Path(td);ys=p/'run.ys';ys.write_text(f'read_verilog -sv {RTL.as_posix()}\nchparam -set COUNT_W {cw} -set GATE_W {gw} -set FILTER_W {fw} frequency_counter\nsynth_gowin -top frequency_counter -nodsp\ncheck -assert\nstat\n');log=H/f'synthesis_c{cw}_g{gw}_f{fw}.log';out=execute(['yosys','-Q','-T','-s',ys],p,log,timeout=300);tail=out[out.rfind('=== frequency_counter ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',tail,re.M)}
   lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k);bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9']);assert cells and lut<=15000 and dsp<=4 and bram<=46
   r=dict(count_w=cw,gate_w=gw,filter_w=fw,cells=cells,lut_class=lut,dsp=dsp,bram9=bram,report_sha256=hashlib.sha256(log.read_bytes()).hexdigest());rows.append(r);print(json.dumps(r),flush=True)
 assert frozen==hashes();(H/'synthesis.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows,scope='Isolated Gowin synthesis, no physical CDC/timing or board claim'),indent=2)+'\n')
if __name__=='__main__':main()
