import sys,json,hashlib,tempfile,random,re,collections
from pathlib import Path
import numpy as np
import cv2
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
SOURCES=[HERE/'disparity_speckle.sv']
def hashes():return {p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in SOURCES}
def oracle(values,invalid,w,h,threshold,size):
 visited=set(i for i,v in enumerate(invalid)if v);removed=[0]*len(values);components=[]
 for seed in range(len(values)):
  if seed in visited:continue
  todo=collections.deque([seed]);visited.add(seed);component=[]
  while todo:
   i=todo.popleft();component.append(i);x,y=i%w,i//w
   for nx,ny in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)]:
    if 0<=nx<w and 0<=ny<h:
     j=ny*w+nx
     if j not in visited and abs(values[i]-values[j])<=threshold:visited.add(j);todo.append(j)
  components.append(component)
  if len(component)<=size:
   for i in component:removed[i]=1
 return removed,components
TB=r'''module tb;
localparam W=WW,H=HH,DB=DBB,DF=DFF,SB=$clog2(W*H+1);
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,s_valid=0,s_invalid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
reg[DB-1:0]cfg_range=RANGE;reg[SB-1:0]cfg_max_size=SIZE;reg signed[DB-1:0]s_disparity;
wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,m_invalid,m_removed;wire[2:0]error_code;wire signed[DB-1:0]m_disparity;
disparity_speckle #(.WIDTH(W),.HEIGHT(H),.DISP_BITS(DB),.DISP_FRAC(DF))dut(.*);
reg signed[DB-1:0]d[0:W*H-1];reg inv[0:W*H-1];integer i,n=0,cy=0;reg held=0;reg[DB+4:0]token;reg[31:0]rng=32'h7219ba6c;
always @(posedge clk)begin cy=cy+1;if(cy>2000000)$fatal(1,"timeout state%d",dut.state);
if(rst_n)begin
if(held&&(!m_valid||{m_disparity,m_invalid,m_removed,m_sof,m_eol,m_last}!==token))$fatal(1,"hold");
held=m_valid&&!(ce&&m_ready);token={m_disparity,m_invalid,m_removed,m_sof,m_eol,m_last};
if(ce&&m_valid&&m_ready)begin case(n) CHECKS default:$fatal(1,"extra");endcase
if(m_sof!=(n==0)||m_eol!=(n%W==W-1)||m_last!=(n==W*H-1))$fatal(1,"markers");n=n+1;end end else held=0;end
 task tick;begin @(negedge clk);#1;end endtask
initial begin INIT
repeat(2)tick;rst_n=1;tick;start_valid=1;tick;start_valid=0;cfg_range=0;cfg_max_size=0;
for(i=0;i<W*H;i=i+1)begin
s_disparity=d[i];s_invalid=inv[i];s_sof=i==0;s_eol=i%W==W-1;s_last=i==W*H-1;s_valid=1;
if(i%3==0)begin ce=0;repeat(2)tick;if(s_ready)$fatal(1,"CE ready");ce=1;#1;end
while(!s_ready)tick;tick;s_valid=0;
end
while(!done_valid)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};ce=rng[0]||rng[2];m_ready=rng[3];tick;end
ce=1;m_ready=0;if(done_error||error_code||n!=W*H)$fatal(1,"completion %d error%d",n,error_code);
repeat(3)begin tick;if(!done_valid)$fatal(1,"done hold");end
ce=0;done_ready=1;repeat(2)tick;if(!done_valid)$fatal(1,"CE done");ce=1;tick;done_ready=0;if(!start_ready)$fatal(1,"recovery idle");
$display("PASS pixels=%0d cycles=%0d",n,cy);$finish;end endmodule'''
def external(values,invalid,removed,w,h,threshold,size):
 if min(values)<-32767 or max(values)>32767 or threshold>32767:return dict(compared=False,reason='outside unambiguous CV16S sentinel/domain')
 a=np.array(values,dtype=np.int16).reshape(h,w);a[np.array(invalid,dtype=bool).reshape(h,w)]=-32768
 cv=cv2.filterSpeckles(a.copy(),-32768,size,threshold)[0]
 expected=np.array([bool(a or b)for a,b in zip(invalid,removed)]).reshape(h,w)
 assert np.array_equal(cv==-32768,expected),(values,invalid,removed,cv)
 unchanged=~expected;assert np.array_equal(cv[unchanged],a[unchanged])
 return dict(compared=True,pixels=w*h)
def run_case(label,w,h,db,df,threshold,size,values,invalid=None):
 invalid=invalid or [0]*len(values);removed,components=oracle(values,invalid,w,h,threshold,size)
 checks='\n'.join(f'{i}:if($signed(m_disparity)!={d}||m_invalid!={int(bool(inv or rem))}||m_removed!={rem})$fatal(1,"pixel {i} d%0d bad%0d removed%0d",$signed(m_disparity),m_invalid,m_removed);'for i,(d,inv,rem)in enumerate(zip(values,invalid,removed)))
 init='\n'.join(f'd[{i}]={v};inv[{i}]={invalid[i]};'for i,v in enumerate(values));tb=TB
 for key,value in [('WW',w),('HH',h),('DBB',db),('DFF',df),('RANGE',threshold),('SIZE',size),('CHECKS',checks),('INIT',init)]:tb=re.sub(r'\b'+key+r'\b',lambda _:str(value),tb)
 with tempfile.TemporaryDirectory(prefix='speckle_')as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log');text=execute(['vvp',p/'sim'],p,p/'sim.log',timeout=180);assert 'PASS' in text
 cv=external(values,invalid,removed,w,h,threshold,size);print(label,text.strip(),flush=True)
 return dict(label=label,width=w,height=h,disp_bits=db,disp_frac=df,range=threshold,max_size=size,pixels=w*h,component_sizes=[len(c)for c in components],removed=sum(removed),cv2=cv,simulation=text.strip())
def main():
 frozen=hashes();rng=random.Random(942);cases=[]
 cases+=[('single_keep',1,1,16,4,0,0,[7]),('single_remove',1,1,16,4,0,1,[7]),('threshold_chain',17,1,16,4,3,8,[i*3 for i in range(17)]),('thin_separate',1,17,16,4,2,4,[i*3 for i in range(17)])]
 cases += [('full_component_keep',16,8,24,4,0,127,[12]*128),('full_component_remove',16,8,24,4,0,128,[12]*128),('all_invalid',11,7,24,4,7,77,[0]*77,[1]*77)]
 for w,h,threshold,size in [(7,5,0,2),(13,9,7,8),(32,16,3,9),(17,11,64,12),(8,8,0,0),(5,7,4,35)]:
  cases.append(('random',w,h,24,4,threshold,size,[rng.randrange(-32,33)for _ in range(w*h)],[int(rng.random()<.15)for _ in range(w*h)]))
 cases.append(('exact_size_boundary',8,1,16,4,0,3,[1,1,1,10,10,10,10,40]))
 cases.append(('diagonal_not_connected',5,5,16,4,0,1,[int(i%5==i//5)*16 for i in range(25)]))
 cases.append(('unsigned_full_diff',4,2,32,16,4294967295,8,[-2147483648,2147483647,-1,0]*2))
 cases.append(('extreme_diff_separate',4,2,32,16,2147483647,3,[-2147483648,2147483647,-1,0]*2))
 cases.append(('exact_diff_edge',6,1,8,0,255,5,[-128,127,-128,127,0,-1]))
 rows=[run_case(*c)for c in cases];assert hashes()==frozen
 (HERE/'test_result.json').write_text(json.dumps(dict(status='PASS',sources=frozen,opencv=cv2.__version__,cases=rows,board=False),indent=2)+'\n')
if __name__=='__main__':main()
