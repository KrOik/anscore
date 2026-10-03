"""Zero-delay simulation of the exact mapped root/control cone from board JSON.

No arithmetic is resynthesized. Cut only registered leaf power/valid, clock,
POR/state/phase/stall boundaries; retain every downstream mapped LUT/mux/DFF.
"""
import argparse,collections,datetime,hashlib,json,math,os,random,shutil,subprocess
from pathlib import Path
H=Path(__file__).resolve().parent;ROOT=H.parents[5]
p=argparse.ArgumentParser();p.add_argument('build',type=Path);a=p.parse_args()
out=H/'evidence'/datetime.datetime.now().strftime('mapped_%Y%m%d_%H%M%S_%f');out.mkdir(parents=True)
src=a.build/'top.json';design=json.loads(src.read_text());m=design['modules']['dsp_chain_harness'];nets=m['netnames'];cells=m['cells']
portmap={'clk':nets['core.stats.clk']['bits'],'radicand':nets['core.stats.leaf_data']['bits'][64:96],'iv':nets['core.stats.leaf_valid']['bits'],'rst_n':nets['rst_n']['bits'],'state':nets['state']['bits'],'phase':nets['phase']['bits'],'stall':nets['stall']['bits']}
ports={n:dict(direction='input',bits=bits) for n,bits in portmap.items()}
for i in range(4):ports[f'root{i}']=dict(direction='output',bits=nets[f'core.stats.root_stage[{i}]']['bits'])
ports['valid']=dict(direction='output',bits=nets['core.stats.valid']['bits'])
drivers={bit:name for name,c in cells.items() for port,bits in c['connections'].items() if c['port_directions'][port]=='output' for bit in bits}
boundary={bit for bits in portmap.values() for bit in bits};wanted=[bit for port in ports.values() if port['direction']=='output' for bit in port['bits']];visited=set();selected=set()
while wanted:
 bit=wanted.pop()
 if bit in boundary or isinstance(bit,str) or bit in visited:continue
 visited.add(bit);name=drivers[bit]
 if name in selected:continue
 selected.add(name);c=cells[name]
 wanted.extend(bit for port,bits in c['connections'].items() if c['port_directions'][port]=='input' for bit in bits)
cone=dict(attributes={'top':'1'},ports=ports,cells={n:cells[n] for n in selected},netnames={n:dict(hide_name=0,bits=v['bits'],attributes={}) for n,v in ports.items()})
assert not any(c['type'].startswith(('MULT','DPX','SDPX')) for c in cone['cells'].values())
design['modules'].pop('dsp_chain_harness');design['modules']['mapped_root']=cone
(out/'cone.json').write_text(json.dumps(design));shutil.copy2(__file__,out/'test_mapped.py')
rng=random.Random(47321);rows=[];slots=[None]*4;source=None;accepted=outputs=resets=0
initial=[0,32768**2,32767**2,9,12993**2,15776**2,6590**2]
for cycle in range(14000):
 rst=int(cycle%1901 not in (0,1));state=5 if cycle%997 not in (0,1) else 1;reset=not rst or state==1
 phase=cycle%8;stall=0 if cycle%400<180 else 7;sink=phase>=stall
 if source is None and rng.random()<.85:source=initial[accepted] if accepted<len(initial) else rng.randrange((1<<30)+1)
 iv=int(source is not None);rad=source or 0
 valid=sum((x is not None)<<i for i,x in enumerate(slots));roots=[math.isqrt(x>>(24-8*i)) if x is not None else 0 for i,x in enumerate(slots)]
 rows.append(f'{rst} {state} {phase} {stall} {iv} {rad:x} {valid:x} '+' '.join(f'{r:x}' for r in roots))
 if reset:slots=[None]*4;resets+=1;continue
 ready=[False]*4
 for i in reversed(range(4)):ready[i]=slots[i] is None or (sink if i==3 else ready[i+1])
 outputs+=int(slots[-1] is not None and sink)
 slots=[(rad if iv else None) if i==0 and ready[i] else (slots[i-1] if i>0 and ready[i] else slots[i]) for i in range(4)]
 if iv and ready[0]:source=None;accepted+=1
(out/'vectors.txt').write_text('\n'.join(rows)+'\n')
tb='''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,iv=0;reg [3:0] state=1;reg [2:0] phase=0,stall=0;reg [31:0] radicand=0;
wire [15:0] root0,root1,root2,root3;wire [3:0] valid;
mapped_root dut(.*);
integer f,n,row=0,rr,ss,pp,tt,vv;reg [31:0] x;reg [3:0] ev;reg [15:0] r0,r1,r2,r3;
initial begin
f=$fopen("vectors.txt","r");@(posedge clk);#1;
while(!$feof(f))begin
@(negedge clk);n=$fscanf(f,"%d %d %d %d %d %h %h %h %h %h %h\\n",rr,ss,pp,tt,vv,x,ev,r0,r1,r2,r3);
if(n!=11)$fatal(1,"fixture");rst_n=rr;state=ss;phase=pp;stall=tt;iv=vv;radicand=x;#1;
if(valid!==ev)$fatal(1,"valid row %0d got %h expected %h",row,valid,ev);
if((ev[0]&&root0!==r0)||(ev[1]&&root1!==r1)||(ev[2]&&root2!==r2)||(ev[3]&&root3!==r3))$fatal(1,"roots row %0d got %h %h %h %h expected %h %h %h %h",row,root0,root1,root2,root3,r0,r1,r2,r3);
@(posedge clk);#1;row=row+1;
end
$display("PASS mapped root rows=%0d",row);$finish;
end
endmodule
'''
(out/'tb.sv').write_text(tb)
tool=ROOT/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy();env['PATH']=str(tool/'bin')+os.pathsep+str(tool/'lib')+os.pathsep+env['PATH']
def run(cmd,log):
 r=subprocess.run(cmd,cwd=out,env=env,text=True,capture_output=True);(out/log).write_text(r.stdout+r.stderr)
 if r.returncode:raise AssertionError(log+' '+str(out))
run([str(tool/'bin/yosys.exe'),'-Q','-p','read_json cone.json; hierarchy -top mapped_root; write_verilog -noattr mapped.v'],'export.log')
run([str(tool/'bin/iverilog.exe'),'-g2012','-s','tb','-o','test.vvp','tb.sv','mapped.v',str(tool/'share/yosys/gowin/cells_sim.v')],'compile.log')
run([str(tool/'bin/vvp.exe'),'test.vvp'],'run.log')
result=dict(status='PASS',image_sha256=hashlib.sha256((a.build/'chain.fs').read_bytes()).hexdigest(),source_netlist_sha256=hashlib.sha256(src.read_bytes()).hexdigest(),cells=collections.Counter(c['type'] for c in cone['cells'].values()),cycles=len(rows),accepted=accepted,outputs=outputs,reset_edges=resets,boundaries=portmap,scope='exact mapped root/control cone, zero delay; excludes result RAM/physical routing/pack')
(out/'summary.json').write_text(json.dumps(result,indent=2));print('MAPPED ROOT PASS',out)
