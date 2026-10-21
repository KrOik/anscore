from pathlib import Path
import sys,tempfile,hashlib,json,random,bisect,re
H=Path(__file__).resolve().parent;sys.path.insert(0,str(H.parents[1]));from integration.tooling import execute
RTL=H/'frequency_counter.sv'
def hashes():return {RTL.name:hashlib.sha256(RTL.read_bytes()).hexdigest()}
def simulate(label,tb,files):
 with tempfile.TemporaryDirectory(prefix='frequency_counter_') as td:
  d=Path(td)
  for n,body in files.items():
   p=d/n;p.write_text(body);tb=tb.replace('"'+n+'"','"'+p.as_posix()+'"')
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'sim',RTL,d/'tb.sv'],d,H/(label+'_compile.log'))
  out=execute(['vvp',d/'sim'],d,H/(label+'_simulation.log'),timeout=120);assert 'PASS FREQUENCY' in out;return out
TB=r'''`timescale 1ps/1ps
module tb;
localparam CW=@CW@,GW=@GW@,FW=@FW@,NE=@NE@,NH=@NH@,NR=@NR@,PW=CW+GW+35;
reg host_enable=1;reg clk=0;always #5000 clk=~clk;reg rst_n=0,ce=1,input_pin=0,start_valid=0,abort=0,m_ready=1,done_ready=0;
reg[GW-1:0]cfg_gate_clocks=@GATE@;reg[FW-1:0]cfg_filter=@FILTER@;reg[1:0]cfg_edge_mode=@MODE@;
reg cfg_range_enable=@RANGE@;reg[CW-1:0]cfg_min_edges=@MIN@,cfg_max_edges=@MAX@;
wire start_ready,busy,done_valid,m_valid,drop_sticky;wire[CW-1:0]m_edges;wire[GW-1:0]m_gate_clocks;wire[31:0]m_window_index,drop_count;wire[2:0]m_flags;wire[7:0]error_code;
frequency_counter #(.COUNT_W(CW),.GATE_W(GW),.FILTER_W(FW))dut(.*);
reg[64:0]ev[0:NE-1];reg[1:0]host[0:NH-1];reg[PW-1:0]wanted[0:NR];integer e,k,got=0,cycles=0,last_transfer=-1;reg[63:0]prevtime=0;reg held=0;reg[PW-1:0]held_data;
initial begin $readmemh("pin.hex",ev);for(e=0;e<NE;e=e+1)begin #(ev[e][64:1]-prevtime);input_pin=ev[e][0];prevtime=ev[e][64:1];end end
initial begin $readmemh("host.hex",host);for(k=0;k<NH;k=k+1)begin @(negedge clk);#1;if(host_enable){ce,m_ready}=host[k];end end
always @(posedge clk)begin
cycles=cycles+1;if(cycles>NH+100)$fatal(1,"watchdog");
if(rst_n)begin
if(held&&(!m_valid||{m_flags,m_window_index,m_edges,m_gate_clocks}!==held_data))$fatal(1,"held output revoked");
held=m_valid&&!(ce&&m_ready);held_data={m_flags,m_window_index,m_edges,m_gate_clocks};
if(ce&&m_valid&&m_ready)begin
if(@II1@&&got>0&&cycles-last_transfer!=1)$fatal(1,"gate1 output cadence");last_transfer=cycles;
if(got>=NR||{m_flags,m_window_index,m_edges,m_gate_clocks}!==wanted[got])$fatal(1,"tuple%0d idx%0d edges%0d flags%0d want%h",got,m_window_index,m_edges,m_flags,wanted[got]);got=got+1;end
end else held=0;
end
initial begin
$readmemh("expected.hex",wanted);#31000;rst_n=1;#60000;start_valid=1;#10000;start_valid=0;
#9000;cfg_gate_clocks=1;cfg_filter=0;cfg_edge_mode=3;cfg_min_edges=0; // captured descriptor must win
#(@STOP@-2000-110000);abort=1;
wait(done_valid);@(negedge clk);#1;host_enable=0;abort=0;
if(busy||error_code!=3||got!=NR||drop_count!=@DROPS@||drop_sticky!=(@DROPS@!=0))$fatal(1,"final got%0d want%0d drop%0d want%0d",got,NR,drop_count,@DROPS@);
ce=0;done_ready=1;repeat(5)@(negedge clk);#1;if(!done_valid)$fatal(1,"DONE CE0");ce=1;@(negedge clk);#1;if(!start_ready)$fatal(1,"DONE ack");
$display("PASS FREQUENCY gates=@NGATES@ retained=%0d dropped=%0d",got,drop_count);$finish;
end endmodule'''
def case(label,*,gate=31,windows=12,count_w=32,gate_w=32,filter_w=8,filter_n=0,mode=0,range_enable=False,limits=None,events=None,period_ps=37331,phase_ps=431,stall=False,ce_off=False,host_always=False):
 startn=9;stopn=startn+gate*windows+1;stop=5000+stopn*10000;total=stopn+200
 if events is None:
  events=[];t=phase_ps;v=0
  while t<stop:
   v^=1;events.append((t,v));t+=period_ps//2+(len(events)%3-1)*113
 if not events:events=[(1,0)]
 maximum=(1<<count_w)-1;lo,hi=limits or (0,maximum)
 # Independent raw pin sample timestamps followed by accepted transitions.
 times=[t for t,v in events];values=[v for t,v in events]
 sampled=[]
 for n in range(total+1):
  p=bisect.bisect_right(times,5000+n*10000)-1;sampled.append(values[p] if p>=0 else 0)
 level=sampled[startn-2];run=0;counts=[0]*windows;accepted=[]
 for n in range(startn+1,stopn):
  val=sampled[n-2]
  if val==level:run=0
  else:
   run+=1
   if run>=max(1,filter_n):
    level=val;run=0
    if mode==2 or (mode==0 and val==1) or (mode==1 and val==0):counts[(n-startn-1)//gate]+=1;accepted.append(n)
 expected_windows=[]
 for idx,c in enumerate(counts):
  flags=(c==0)|((c>maximum)<<1)|((range_enable and (c<lo or c>hi))<<2)
  expected_windows.append((int(flags)<<(32+count_w+gate_w))|(idx<<(count_w+gate_w))|(min(c,maximum)<<gate_w)|gate)
 controls=[]
 for n in range(total+1):
  ce=not(startn<n<stopn and (ce_off or n%11 in (0,1,2)))
  ready=not(startn<n<stopn and (stall or n%7<3))
  if host_always:ce=ready=True
  if n==startn:ce=True
  controls.append((int(ce)<<1)|int(ready))
 queue=[];retained=[];drops=0;generated={startn+(i+1)*gate:word for i,word in enumerate(expected_windows)}
 for n in range(startn+1,total+1):
  if queue and controls[n]==3:retained.append(queue.pop(0))
  if n-1 in generated:
   if len(queue)<2:queue.append(generated[n-1])
   else:drops+=1
 assert not queue
 tb=TB
 for k,v in dict(CW=count_w,GW=gate_w,FW=filter_w,NE=len(events),NH=total,NR=len(retained),GATE=gate,FILTER=filter_n,MODE=mode,RANGE=int(range_enable),MIN=lo,MAX=hi,STOP=stop,DROPS=drops,NGATES=windows,II1=int(gate==1 and host_always)).items():tb=tb.replace('@'+k+'@',str(v))
 # +one unused expected sentinel avoids an empty memory array profile.
 files={'pin.hex':'\n'.join(f'{(t<<1)|v:x}' for t,v in events),'host.hex':'\n'.join(f'{v:x}' for v in controls[1:]),'expected.hex':'\n'.join(f'{v:x}' for v in retained+[0])}
 out=simulate(label,tb,files);print(label,out.splitlines()[0]);return dict(label=label,status='PASS',gate=gate,windows=windows,count_w=count_w,gate_w=gate_w,filter_w=filter_w,filter=filter_n,mode=mode,accepted_edges=len(accepted),window_counts=counts,retained=len(retained),dropped=drops,output=out)
def main():
 rows=[]
 for mode in (0,1,2):
  for filter_n in (0,1,3,8):rows.append(case(f'mode{mode}_filter{filter_n}',mode=mode,filter_n=filter_n,period_ps=173331 if filter_n>1 else 37331))
 rows.append(case('ce_off',ce_off=True));rows.append(case('queue_stall',stall=True));rows.append(case('range',range_enable=True,limits=(6,8)))
 rows.append(case('no_edges',events=[(1,0)],range_enable=True,limits=(1,99)))
 (H/'evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),profiles=rows,scope='Independent physical asynchronous pin event timestamps, separate sampled-transition/window and two-entry host queue oracle; no internal counter forcing'),indent=2)+'\n')
if __name__=='__main__':main()
