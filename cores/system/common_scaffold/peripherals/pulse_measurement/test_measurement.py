"""Pin waveform oracle: sampled transition timestamps, not DUT state replay."""
from pathlib import Path
import hashlib,json,tempfile,sys
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
SOURCE=HERE/'pulse_measurement.sv'
def hashes():return {SOURCE.name:hashlib.sha256(SOURCE.read_bytes()).hexdigest()}
TB=r'''
module tb;
localparam W=@W@,N=@N@;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,input_pin=0,start_valid=0,abort=0,m_ready=0,done_ready=0;
wire start_ready,busy,done_valid,m_valid,m_is_cycle,drop_sticky;
wire[W-1:0]m_high,m_low,m_period;wire[2:0]m_flags;wire[7:0]error_code;wire[31:0]drop_count;
reg cfg_active_high=@POL@;reg[7:0]cfg_filter=@FILTER@;
reg[W-1:0]cfg_timeout=@TIMEOUT@,cfg_min_high=@MINH@,cfg_max_high=@MAXH@,cfg_min_low=@MINL@,cfg_max_low=@MAXL@;
pulse_measurement #(.COUNTER_W(W)) d(.*);
reg[5:0]stim[0:N-1];integer i=0,events=0;reg held=0;reg[3*W+3:0]held_data;
always @(posedge clk)if(rst_n)begin
 if(held&&(!m_valid||{m_is_cycle,m_flags,m_high,m_low,m_period}!==held_data))$fatal(1,"exposed token changed while stalled");
 held=m_valid&&!(ce&&m_ready);held_data={m_is_cycle,m_flags,m_high,m_low,m_period};
 if(ce&&m_ready&&m_valid)begin
  $display("EVENT %0d %0d %0d %0d %0d %0d",i,m_is_cycle,m_flags,m_high,m_low,m_period);events=events+1;
 end
end else held=0;
initial begin
 $readmemh("stim.hex",stim);
 for(i=0;i<N;i=i+1)begin
  @(negedge clk);#1;
  {rst_n,ce,m_ready,start_valid,abort,input_pin}=stim[i];
  // Change all live inputs after descriptor acceptance; captured values must win.
  if(i==20)begin cfg_active_high=~cfg_active_high;cfg_filter=255;cfg_timeout=1;cfg_min_high=0;cfg_max_low=0;end
 end
 @(negedge clk);#1;
 if(!done_valid||error_code!=3||busy)$fatal(1,"abort drain completion state");
 $display("PASS PULSE width=%0d events=%0d drops=%0d sticky=%0d",W,events,drop_count,drop_sticky);$finish;
end
initial begin #20000000;$fatal(1,"watchdog");end
endmodule
'''
def frontend(raw,filter_n,start=10):
 # Two clocked synchronizer stages, then symmetric stable-N acceptance.
 # The input stimulus changes half a clock before each observation edge.
 sampled=[0,0]+raw
 level=sampled[start];count=0;edges=[]
 for t in range(start+1,len(raw)):
  value=sampled[t]
  if value==level:count=0
  else:
   count+=1
   if count>=max(1,filter_n):level=value;count=0;edges.append((t,value))
 return edges
def expected_events(raw,pol,filter_n,timeout,width,limits,start=10,stop=None):
 # Segment boundaries are the independent filtered pin transition timestamps.
 # Pair complete active/inactive intervals; no access to the DUT counters/FSM.
 stop=len(raw) if stop is None else stop
 edges=[(t,v) for t,v in frontend(raw,filter_n,start) if t<stop]
 result=[];active_start=None;inactive_start=None;last_transition=start;faulted=False
 maximum=(1<<width)-1
 def failure_until(t):
  nonlocal faulted,active_start,inactive_start
  threshold=timeout if timeout else maximum+1
  flag=1 if timeout else 2
  if not faulted and t-last_transition>threshold:
   result.append((0,flag,0,0,0));faulted=True;active_start=None;inactive_start=None
 for t,value in edges:
  failure_until(t)
  interval=t-last_transition
  if not faulted and active_start is not None and interval>maximum:
   result.append((0,2,0,0,0));active_start=None;inactive_start=None
  elif value==pol:
   if active_start is not None and inactive_start is not None:
    high=inactive_start-active_start;low=t-inactive_start;period=high+low
    flags=(2 if period>maximum else 0)|(4 if not(limits[0]<=high<=limits[1] and limits[2]<=low<=limits[3]) else 0)
    result.append((1,flags,high,low,min(period,maximum)))
   active_start=t;inactive_start=None
  elif active_start is not None:inactive_start=t
  last_transition=t;faulted=False
 failure_until(stop)
 return result
def wave(segments,initial=0):
 raw=[initial]*32
 for level,n in segments:raw.extend([level]*n)
 return raw
def run(label,segments,*,width=32,pol=1,filter_n=0,timeout=0,limits=None,stall=False,ce_off=False,filter_width=8):
 maximum=(1<<width)-1
 limits=limits or (1,maximum,1,maximum)
 raw=wave(segments,initial=not pol);stop=len(raw)+8
 # Eight clocks to retire synchronizer/filter edges, then abort with CE=1.
 raw.extend([raw[-1]]*8)
 expected=expected_events(raw,pol,filter_n,timeout,width,limits,stop=stop)
 retained=expected[:2] if (stall or ce_off) else expected;drops=max(0,len(expected)-2) if (stall or ce_off) else 0
 stim=[]
 for t,value in enumerate(raw):
  ce=False if ce_off else True if stall else t%7 not in (0,1)
  stim.append((int(t>=3)<<5)|(int(ce)<<4)|(int(not stall)<<3)|(int(t==10)<<2)|int(value))
 # Host always accepts start despite the ordinary CE pattern at that one clock.
 stim[10]|=16
 for t in range(50):stim.append(32|16|8|(2 if t==0 else 0)|int(raw[-1]))
 substitutions=dict(W=width,N=len(stim),POL=int(pol),FILTER=filter_n,TIMEOUT=timeout,MINH=limits[0],MAXH=limits[1],MINL=limits[2],MAXL=limits[3])
 tb=TB.replace('reg[7:0]cfg_filter',f'reg[{filter_width-1}:0]cfg_filter').replace('#(.COUNTER_W(W))',f'#(.COUNTER_W(W),.FILTER_W({filter_width}))')
 for k,v in substitutions.items():tb=tb.replace('@'+k+'@',str(v))
 with tempfile.TemporaryDirectory(prefix='pulse_measure_') as tmp:
  p=Path(tmp);(p/'stim.hex').write_text(''.join(f'{n:x}\n' for n in stim));(p/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',SOURCE,p/'tb.sv'],p,p/'compile.log')
  out=execute(['vvp',p/'sim'],p,p/'run.log');(HERE/f'simulation_{label}.log').write_text(out)
 actual=[tuple(map(int,line.split()[2:])) for line in out.splitlines() if line.startswith('EVENT ')]
 assert actual==retained,(label,actual,retained)
 import re
 match=re.search(r'PASS PULSE width=(\d+) events=(\d+) drops=(\d+) sticky=(\d+)',out);assert match
 assert int(match[3])==drops and int(match[4])==bool(drops),(label,match.groups(),drops)
 row=dict(label=label,width=width,polarity=int(pol),filter=filter_n,filter_width=filter_width,timeout=timeout,events=len(actual),dropped=drops,expected_events=expected,output=out)
 print('PASS',label,'events',len(actual),'drops',drops,flush=True);return row
def main():
 frozen=hashes();rows=[]
 seg=[(1,20),(0,30),(1,25),(0,35),(1,40),(0,22),(1,23),(0,31),(1,20)]
 rows.append(run('pwm32',seg))
 rows.append(run('active_low48',[(not l,n) for l,n in seg],width=48,pol=0,filter_n=3))
 rows.append(run('filtered_glitches',[(1,2),(0,12),(1,15),(0,2),(1,10),(0,20),(1,18),(0,25),(1,12)],filter_n=4))
 rows.append(run('range_errors',seg,limits=(22,35,25,32)))
 rows.append(run('queue_drop',seg,stall=True))
 rows.append(run('ce_off_physical_live',seg,ce_off=True))
 rows.append(run('timeout_edge_priority',[(1,40),(0,40),(1,6)],timeout=40))
 rows.append(run('inclusive_limits',[(1,8),(0,13),(1,8),(0,13),(1,6)],limits=(8,8,13,13)))
 rows.append(run('timeout_relock',[(0,80),(1,20),(0,30),(1,18),(0,90),(1,16),(0,24),(1,20)],timeout=60))
 assert hashes()==frozen
 (HERE/'measurement_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows,scope='Independent pin-transition interval oracle, symmetric filter and bounded-output queue; no analog metastability or board claim.'),indent=2)+'\n')
if __name__=='__main__':main()
