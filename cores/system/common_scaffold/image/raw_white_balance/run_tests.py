from pathlib import Path
from fractions import Fraction
import hashlib,json,random,sys,tempfile
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute

def nearest(v): return (2*v.numerator+v.denominator)//(2*v.denominator)
def oracle(w,h,b,c):
 sums=[0]*4;counts=[0]*4;out=[];sat=[];mask=(1<<b)-1
 for n,v in enumerate(c['data']):
  x=n%w;y=n//w;p=((y&1)*2+(x&1))^c['pattern']
  if c['roi'][0]<=x<=c['roi'][2] and c['roi'][1]<=y<=c['roi'][3] and c['gate'][0]<=v<=c['gate'][1]:
   sums[p]+=v;counts[p]+=1
 if c.get('config_error'): return sums,counts,c['manual'],[],[],1
 if c.get('marker_error'):return sums,counts,c['manual'],[],[],2
 gains=c['manual'][:]
 if c['auto']:
  sg=sums[1]+sums[2];cg=counts[1]+counts[2]
  for p in range(4):
   if cg==0 or sg==0 or counts[p]==0 or sums[p]==0:
    return sums,counts,gains,[],[],3 if not cg or not counts[p] else 4
   gains[p]=max(c['bounds'][0],min(c['bounds'][1],nearest(Fraction(sg*counts[p]*4096,cg*sums[p]))))
 for n,v in enumerate(c['data']):
  p=(((n//w)&1)*2+(n%w&1))^c['pattern'];q=nearest(Fraction(v*gains[p],4096))
  out.append(min(mask,q));sat.append(int(q>mask))
 return sums,counts,gains,out,sat,0

def make_cases(w,h,b):
 r=random.Random(w*123+h+b);m=(1<<b)-1;cases=[]
 for pat in range(4):
  for mode in range(3):
   c=dict(pattern=pat,auto=mode!=2,roi=[0,0,w-1,h-1],gate=[0,m],bounds=[512,65535],manual=[2048,4096,8192,65535])
   c['data']=[r.randrange(1,m+1) for _ in range(w*h)]
   if mode==0:
    c['data']=[max(1,m//([8,3,2,6][(((n//w)&1)*2+(n%w&1))^pat])) for n in range(w*h)]
   if mode==1 and w>3 and h>3:c['roi']=[1,0,w-2,h-2];c['gate']=[m//8,m*7//8];c['bounds']=[3000,6000]
   cases.append(c)
 if w>=4 and h>=4:
  # Unequal surviving green populations distinguish pooled sample mean from
  # an incorrect equally weighted average of the two green-plane means.
  d=[];first=True
  for y in range(h):
   for x in range(w):
    p=(y&1)*2+(x&1)
    if p==1:d.append(3000 if first else (1<<b)-1);first=False
    else:d.append([500,0,1000,1500][p])
  if b==12:
   cases.append(dict(pattern=0,auto=True,roi=[0,0,w-1,h-1],gate=[0,3500],bounds=[0,65535],manual=[4096]*4,data=d,kind='unequal_green_population'))
  cases.append(dict(pattern=0,auto=True,roi=[0,0,w-1,h-1],gate=[0,m],bounds=[4096,8192],manual=[4096]*4,
    data=[m if (((i//w)&1)*2+(i%w&1))in(0,3)else 1 for i in range(w*h)],kind='lower_gain_clamp'))
 for typ in ('empty','zero','invalid_roi','invalid_gate','invalid_bounds','manual_bad','marker_sof','marker_eol','marker_last'):
  c=dict(pattern=0,auto=True,roi=[0,0,w-1,h-1],gate=[0,m],bounds=[1,65535],manual=[4096]*4,data=[max(1,m//3)]*(w*h),kind=typ)
  if typ=='empty':c['gate']=[m,m]
  if typ=='zero':c['data']=[0]*(w*h)
  if typ=='invalid_roi':c['roi'][2]=w;c['config_error']=True
  if typ=='invalid_gate':c['gate']=[m,0];c['config_error']=True
  if typ=='invalid_bounds':c['bounds']=[100,99];c['config_error']=True
  if typ=='manual_bad':c['auto']=False;c['manual'][0]=0;c['config_error']=True
  if typ.startswith('marker'):c['marker_error']=typ
  cases.append(c)
 # Recovery frame immediately after final fault.
 cases.append(dict(pattern=3,auto=False,roi=[0,0,w-1,h-1],gate=[0,m],bounds=[0,65535],manual=[0,4096,8192,65535],data=[r.randrange(m+1) for _ in range(w*h)]))
 return cases

def run_profile(w,h,b,cases=None):
 cases=make_cases(w,h,b) if cases is None else cases;n=w*h;rows=[];body=[]
 for ci,c in enumerate(cases):
  sums,counts,gains,out,sat,err=oracle(w,h,b,c)
  assignments='\n'.join(f'data[{i}]={v};' for i,v in enumerate(c['data']))
  expected='\n'.join(f'exp[{i}]={v};esat[{i}]={sat[i]};' for i,v in enumerate(out))
  pack=lambda a,bits:sum(v<<(i*bits) for i,v in enumerate(a))
  statscheck='' if c.get('config_error') or c.get('marker_error') else f'if(stats_sums!==128\'h{pack(sums,32):032x}||stats_counts!==128\'h{pack(counts,32):032x}) $fatal(1,"stats case {ci}");'
  gaincheck='' if err else f'if(applied_gains!==64\'h{pack(gains,16):016x}) $fatal(1,"gains case {ci} %h",applied_gains);'
  body.append(f'''
   cid={ci};seen=0;want={len(out)};expected_error={err};
   {assignments}
   {expected}
   cfg_auto={int(c['auto'])};cfg_pattern={c['pattern']};
   cfg_roi_x0={c['roi'][0]};cfg_roi_y0={c['roi'][1]};cfg_roi_x1={c['roi'][2]};cfg_roi_y1={c['roi'][3]};
   cfg_low={c['gate'][0]};cfg_high={c['gate'][1]};cfg_gain_min={c['bounds'][0]};cfg_gain_max={c['bounds'][1]};
   cfg_manual_gains=64'h{pack(c['manual'],16):016x};
   start_valid=1;do tick();while(!got_start);start_valid=0;
   // Deliberately poison host config after accepted start: all fields must be latched.
   cfg_auto=~cfg_auto;cfg_pattern=~cfg_pattern;cfg_roi_x0=65535;cfg_roi_x1=65535;
   cfg_roi_y0=65535;cfg_roi_y1=65535;cfg_low=0;cfg_high=0;cfg_gain_min=65535;cfg_gain_max=0;cfg_manual_gains=0;
   if(expected_error!=1)begin
    for(k=0;k<{n};k=k+1)begin
     s_valid=1;s_data=data[k];s_sof=(k==0);s_eol=(k%{w}=={w-1});s_last=(k=={n-1});
     {('if(k==0)s_sof=0;' if c.get('marker_error')=='marker_sof' else '')}
     {('if(k==0)s_eol=~s_eol;' if c.get('marker_error')=='marker_eol' else '')}
     {('if(k==0)s_last=~s_last;' if c.get('marker_error')=='marker_last' else '')}
     do tick();while(!got_input);s_valid=0;
     if(expected_error==2)k={n};
    end
   end
   while(!done_valid)tick();
   if(done_error!==(expected_error!=0)||error_code!==expected_error||seen!=want)$fatal(1,"done case {ci} err %d count %d",error_code,seen);
   {statscheck}{gaincheck}
   // Hold DONE, including CE stalls; interface must remain inert until ack.
   repeat(5)begin tick();if(!done_valid||start_ready||s_ready)$fatal(1,"done hold");end
   done_ready=1;do tick();while(!got_done);done_ready=0;
  ''')
  rows.append(dict(case=ci,pattern=c['pattern'],automatic=c['auto'],kind=c.get('kind','numeric'),error=err,pixels=len(out),gains=gains if not err else None))
 tb=f'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=0,start_valid=0,cfg_auto;reg[1:0]cfg_pattern;
 reg[15:0]cfg_roi_x0,cfg_roi_y0,cfg_roi_x1,cfg_roi_y1,cfg_gain_min,cfg_gain_max;
 reg[{b-1}:0]cfg_low,cfg_high,s_data;reg[63:0]cfg_manual_gains;
 reg s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 wire start_ready,s_ready,m_valid,m_saturated,m_sof,m_eol,m_last,done_valid,done_error;
 wire[{b-1}:0]m_data;wire[3:0]error_code;wire[127:0]stats_sums,stats_counts;wire[63:0]applied_gains,green_sum;wire[31:0]green_count;
 raw_white_balance #(.WIDTH({w}),.HEIGHT({h}),.BITS({b})) dut(.*);
 integer data[0:{n-1}],exp[0:{n-1}],esat[0:{n-1}],k,cid,seen,want,expected_error;
 reg got_start,got_input,got_done;reg[31:0]rng=32'h34561789;integer cycles=0;
 reg held=0;reg[{b+3}:0]held_payload;
 always @(posedge clk)if(rst_n)begin
  cycles=cycles+1;if(cycles>3000000)$fatal(1,"timeout");
  if(held&&{{m_data,m_saturated,m_sof,m_eol,m_last}}!==held_payload)$fatal(1,"output changed stalled");
  held=m_valid&&!(ce&&m_ready);held_payload={{m_data,m_saturated,m_sof,m_eol,m_last}};
  if(ce&&m_valid&&m_ready)begin
   if(seen>=want||m_data!==exp[seen]||m_saturated!==esat[seen]||m_sof!==(seen==0)||m_eol!==(seen%{w}=={w-1})||m_last!==(seen=={n-1}))
    $fatal(1,"pixel case %d idx %d got %d expected %d",cid,seen,m_data,exp[seen]);
   seen=seen+1;
  end
 end
 task tick;begin
  @(negedge clk);rng=(rng>>1)^((rng[0])?32'hd0000001:0);ce=(rng[2:0]!=0);m_ready=(rng[5:3]!=0);
  @(posedge clk);got_start=ce&&start_valid&&start_ready;got_input=ce&&s_valid&&s_ready;got_done=ce&&done_valid&&done_ready;#1;
 end endtask
 initial begin repeat(3)@(posedge clk);#1;rst_n=1;
 {''.join(body)}
 $display("PASS AWB {w}x{h} RAW{b} cases {len(cases)}");$finish;end
 endmodule'''
 with tempfile.TemporaryDirectory(prefix='raw_awb_test_') as td:
  d=Path(td);(d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',H/'raw_white_balance.sv',d/'tb.sv'],ROOT,d/'compile.log')
  result=execute(['vvp',d/'a.vvp'],ROOT,d/'run.log',timeout=180)
  print(result.strip())
 return dict(width=w,height=h,bits=b,cases=rows,outputs=sum(x['pixels'] for x in rows))

if __name__=='__main__':
 profiles=[run_profile(*p) for p in [(8,6,8),(7,5,10),(9,7,12),(1,5,12),(5,1,10),(1,1,8),(32,24,12)]]
 evidence=dict(result='PASS',rtl_sha256=hashlib.sha256((H/'raw_white_balance.sv').read_bytes()).hexdigest(),oracle='independent fractions.Fraction rational mean/gain and output round-half-up',profiles=profiles,total_cases=sum(len(p['cases'])for p in profiles),total_outputs=sum(p['outputs']for p in profiles))
 (H/'test_result.json').write_text(json.dumps(evidence,indent=2)+'\n')
