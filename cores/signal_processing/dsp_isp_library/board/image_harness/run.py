"""Simulate external full frames, then optionally synthesize/route/pack. No hardware."""
import argparse,collections,datetime,hashlib,json,os,re,shutil,struct,subprocess
from pathlib import Path
from protocol import HERE,LIB,cases,make_packet,verify
ROOT=LIB.parents[1]
def audit_warnings(dest):
 patterns=(r'found logic loop',r'(?<!no )latch inferred',r'inferred latch',r'\$dlatch',r'no clocks? (found|defined|constrained)',r'unconstrained',r'no (timing|clock) constraints?',r'failed to (match|constrain)',r'not constrained')
 findings=[]
 for name in ('synthesis.log','route.log','nextpnr.log'):
  path=dest/name
  if path.exists():
   for line in path.read_text(errors='replace').splitlines():
    if any(re.search(p,line,re.I) for p in patterns):findings.append(dict(log=name,line=line))
 (dest/'warning_audit.json').write_text(json.dumps(dict(status='FAIL' if findings else 'PASS',findings=findings),indent=2))
 assert not findings,('strict warning gate',findings)
def main():
 p=argparse.ArgumentParser();p.add_argument('--bits',type=int,choices=(8,10),default=8);p.add_argument('--padding',type=int,choices=(0,1),default=1);p.add_argument('--build',action='store_true');p.add_argument('--replay-json');p.add_argument('--replay-plus-default',action='store_true');p.add_argument('--window-source');p.add_argument('--padded-source');a=p.parse_args()
 dest=HERE/'evidence'/f'image{a.bits}_pad{a.padding}_{datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f")}';dest.mkdir(parents=True)
 cad=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=dict(os.environ);env['PATH']=str(cad/'bin')+os.pathsep+str(cad/'lib')+os.pathsep+env['PATH']
 files=[HERE/'image_harness.v',HERE/'tb_image.sv',LIB/'chains/csc_morphology/csc_morphology_stream.v',LIB/'isp/csc_stream.v',LIB/'isp/csc_coeffs.vh',LIB/'isp/morphology/morphology_stream.v',LIB/'isp/morphology/morph_reduce.v',LIB/'infra/window/stream_window.v',LIB/'infra/window/stream_window_padded.v',LIB/'board/block_harness/block_ram.v',ROOT/'cores/image_processing/window/sim/gowin_bsram_sim.v',ROOT/'cores/communication/primitives/src/uart_rx.v',ROOT/'cores/communication/primitives/src/uart_tx.v']
 files=[Path(a.window_source) if f.name=='stream_window.v' and a.window_source else Path(a.padded_source) if f.name=='stream_window_padded.v' and a.padded_source else f for f in files]
 assert all(f.name in ('stream_window.v','stream_window_padded.v') for f in [Path(x) for x in (a.window_source,a.padded_source) if x]),'candidate source basename'
 for f in files:shutil.copy2(f,dest/f.name)
 for f in [HERE/'run.py',HERE/'protocol.py',LIB/'isp/csc_model.py',LIB/'isp/morphology/model.py']:shutil.copy2(f,dest/f.name)
 shutil.copy2(LIB/'board/uart_injection_probe.cst',dest/'top.cst')
 (dest/'hashes.json').write_text(json.dumps({str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in files},indent=2))
 frames=cases(a.bits);stim='';negative=[]
 if a.replay_json:
  source=Path(a.replay_json);v=json.loads(source.read_text());assert v['bits']==a.bits and v['padding']==a.padding
  frames=[(v['tag'],v['config'],v['words'],v['stall'])];shutil.copy2(source,dest/'replayed_input.json')
  packet_path=source.with_name('request.bin')
  if packet_path.exists():assert packet_path.read_bytes()==make_packet(*frames[0]),'saved UART input differs'
  if a.replay_plus_default:frames+= [(v['tag']^0x80000000,v['config'],v['words'],7)]+cases(a.bits)
 for tag,c,w,stall in frames:
  packet=make_packet(tag,c,w,stall);stim+=f'{len(packet)} 276\n'+''.join(f'{b:02x}\n' for b in packet)
 for tag,c,count,stall,flag in [(0xBAD10001,32,0,0,1),(0xBAD10002,32,63,0,1),(0xBAD10003,32,64,8,1),(0xBAD10004,0,64,0,8),(0xBAD10005,0x80000020,64,0,8)]:
  packet=b'IMG1'+struct.pack('<IIBB',tag,c,count,stall)+(bytes(256) if flag==8 else b'')
  stim+=f'{len(packet)} 20\n'+''.join(f'{b:02x}\n' for b in packet)
  negative.append(b'IMR1'+struct.pack('<IIBBBBI',tag,c,0,flag,0,0,0))
 (dest/'stim.txt').write_text(stim)
 def run(command,log):
  command=[shutil.which(command[0],path=env['PATH']) or command[0],*command[1:]]
  with (dest/log).open('w') as f:
   f.write('$ '+' '.join(command)+'\n');f.flush();r=subprocess.run(command,cwd=dest,env=env,stdout=f,stderr=subprocess.STDOUT)
  if r.returncode:raise RuntimeError(f'{log} failed; {dest}')
 rtl=[f.name for f in files if f.suffix in ('.v','.sv') and f.name not in ('tb_image.sv','gowin_bsram_sim.v')]
 run(['iverilog','-g2012','-Wall','-I.','-s','tb_image',f'-Ptb_image.BITS={a.bits}',f'-Ptb_image.PAD_MODE={a.padding}','-o','sim.vvp','tb_image.sv','gowin_bsram_sim.v',*rtl],'compile.log')
 run(['vvp','sim.vvp','+stim=stim.txt','+trace=trace.txt'],'simulation.log')
 raw=bytes(int(x,16) for x in (dest/'trace.txt').read_text().splitlines());(dest/'raw.bin').write_bytes(raw);offset=0;results=[]
 for tag,c,w,stall in frames:
  report=raw[offset:offset+276];results.append(verify(report,tag,c,w,a.bits,stall,a.padding));offset+=276
  for pos in (0,4,8,12,13,14,15,20,23,275):
   bad=bytearray(report);bad[pos]^=1
   try:verify(bad,tag,c,w,a.bits,stall,a.padding)
   except AssertionError:pass
   else:raise AssertionError('mutation accepted')
 for expected in negative:
  assert raw[offset:offset+20]==expected,('negative packet',raw[offset:offset+20],expected);offset+=20
 assert offset==len(raw),'extra response bytes'
 (dest/'simulation_summary.json').write_text(json.dumps(dict(status='PASS',bits=a.bits,padding=a.padding,frames=results,negative_packets=5,checker_mutations=10*len(frames)),indent=2));print('SIM PASS',dest,flush=True)
 if not a.build:return
 (dest/'build.ys').write_text('read_verilog -sv -I. '+' '.join(rtl)+f'\nchparam -set BITS {a.bits} -set PAD_MODE {a.padding} image_harness\nsynth_gowin -noalu -family gw2a -top image_harness -json top.json\nstat\n')
 run(['yosys','-s','build.ys'],'synthesis.log')
 audit_warnings(dest)
 net=json.loads((dest/'top.json').read_text());cells=collections.Counter(c['type'] for c in net['modules']['image_harness']['cells'].values());lut=sum(n for t,n in cells.items() if re.fullmatch('LUT[1-4]|ALU',t));dsp=sum(n for t,n in cells.items() if t.startswith(('MULT','PADD','ALU54')))
 (dest/'resources.json').write_text(json.dumps(dict(lut=lut,dsp=dsp,cells=dict(cells)),indent=2));assert lut<=15000 and dsp<=4
 run(['nextpnr-himbaechel','--json','top.json','--write','pnr.json','--device','GW2A-LV18PG256C8/I7','--vopt','family=GW2A-18','--vopt','cst=top.cst','--freq','27','--seed','1','--log','nextpnr.log'],'route.log')
 text=(dest/'nextpnr.log').read_text();routed=re.search(r'\bLUT4:\s+(\d+)',text);freq=re.findall(r'Max frequency for clock[^\n]*?:\s*([\d.]+)\s*MHz',text)
 audit_warnings(dest)
 assert routed and int(routed[1])<=15000 and freq and min(map(float,freq))>=27,'route/timing gate'
 py=cad/'lib/python3.exe';py=py if py.exists() else cad/'bin/python.exe'
 run([str(py),str(cad/'bin/gowin_pack-script.py'),'-d','GW2A-18','-o','image.fs','pnr.json'],'pack.log')
 (dest/'build_summary.json').write_text(json.dumps(dict(status='BUILD_PASS_NOT_BOARD',bits=a.bits,padding=a.padding,lut=lut,routed_lut4=int(routed[1]),dsp=dsp,fmax_mhz=list(map(float,freq)),bitstream_sha256=hashlib.sha256((dest/'image.fs').read_bytes()).hexdigest()),indent=2));print('BUILD PASS',dest,flush=True)
if __name__=='__main__':main()
