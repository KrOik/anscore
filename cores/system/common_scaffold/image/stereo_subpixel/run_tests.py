from pathlib import Path
import sys,tempfile,random,json,hashlib
from fractions import Fraction
from itertools import product
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute

def reference(cost,invalid,gap,frac):
 valid=[i for i in range(len(cost)) if not invalid[i]]
 if not valid:return (0,0,0,0,1,96)
 order=sorted(valid,key=lambda i:(cost[i],i));best=order[0];conf=cost[order[1]]-cost[best] if len(order)>1 else 0
 bad=len(order)<2 or conf<gap;status=(32 if len(order)<2 else 16 if conf<gap else 0);offset=0
 if len(order)>=2:
  if best in (0,len(cost)-1):status|=2
  elif invalid[best-1] or invalid[best+1]:status|=4
  else:
   curvature=cost[best-1]-2*cost[best]+cost[best+1]
   if curvature<=0:status|=8
   else:
    exact=Fraction(cost[best-1]-cost[best+1],2*curvature)*(1<<frac)
    mag,rem=divmod(abs(exact.numerator),exact.denominator);mag+=2*rem>=exact.denominator
    if mag>1<<(frac-1):status|=128;mag=1<<(frac-1)
    offset=-mag if exact<0 else mag;status|=1
 return ((best<<frac)+offset,best,offset,conf,int(bad),status)

def cases(d,bits):
 maximum=(1<<bits)-1;rng=random.Random(d+bits);out=[]
 if d==3 and bits==2:
  return [('exhaustive',list(c),list(inv),gap) for c in product(range(4),repeat=3) for inv in product(range(2),repeat=3) for gap in range(4)]
 def add(name,c,inv=None,gap=1):out.append((name,c,inv or [0]*d,gap))
 add('flat', [19]*d);add('flat_tie_allowed',[19]*d,gap=0)
 add('left_boundary',list(range(d)));add('right_boundary',list(reversed(range(d))))
 add('all_invalid',[rng.randrange(maximum+1) for _ in range(d)],[1]*d)
 inv=[1]*d;inv[d//2]=0;add('only_one_valid',[maximum]*d,inv)
 for left,right in [(3,7),(7,3),(0,maximum),(maximum,0),(1,maximum),(maximum,1),(maximum,maximum),(1,3),(3,1),(2,6),(6,2)]:
  c=[maximum]*d;c[d//2]=0;c[d//2-1]=left;c[d//2+1]=right;add(f'neighbors_{left}_{right}',c)
 c=[maximum]*d;c[1]=0;c[d//2]=0;add('distant_minima_tie',c);add('tie_allowed_nonconvex',c,gap=0)
 for side in (-1,1):
  c=[maximum]*d;c[d//2]=0;inv=[0]*d;inv[d//2+side]=1;add('invalid_neighbor',c,inv)
 for delta in (0,1,2):
  c=[maximum]*d;c[d//2]=100;c[d//2+2]=100+delta;add('gap_boundary',c,gap=1)
 for j in range(120):
  c=[rng.randrange(maximum+1) for _ in range(d)];inv=[int(rng.randrange(11)==0) for _ in range(d)];add('random',c,inv,rng.randrange(min(maximum,20)+1))
 return out

def run(d,bits,frac):
 rows=cases(d,bits);expected=[reference(c,inv,gap,frac) for _,c,inv,gap in rows];count=len(rows)
 with tempfile.TemporaryDirectory(prefix='stereo_subpixel_') as td:
  p=Path(td)
  (p/'costs.mem').write_text('\n'.join(f'{v:x}' for _,c,_,_ in rows for v in c))
  (p/'invalid.mem').write_text('\n'.join(str(v) for _,_,inv,_ in rows for v in inv))
  (p/'gaps.mem').write_text('\n'.join(f'{gap:x}' for _,_,_,gap in rows))
  def pack(row):
   q,b,off,conf,bad,status=row
   return (((((q<<16)|b)<<(frac+1))|(off&((1<<(frac+1))-1)))<<(bits+9))|(conf<<9)|(bad<<8)|status
  ow=32+16+frac+1+bits+9
  (p/'expected.mem').write_text('\n'.join(f'{pack(row):x}' for row in expected))
  tb=f'''module tb;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,abort=0,cfg_valid=0,s_valid=0,s_cost_invalid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[{bits-1}:0]cfg_min_gap,s_cost;reg[15:0]s_disp;wire cfg_ready,s_ready,m_invalid,m_valid,m_sof,m_eol,m_last,done_valid,frame_error;wire[3:0]error_code;wire signed[31:0]m_disparity_q;wire[15:0]m_integer;wire signed[{frac}:0]m_offset;wire[{bits-1}:0]m_confidence;wire[7:0]m_status;
 stereo_subpixel #(.WIDTH(1),.HEIGHT(1),.DISPARITIES({d}),.COST_BITS({bits}),.FRAC_BITS({frac})) dut(.*);
 reg[{bits-1}:0]cost[0:{count*d-1}],gaps[0:{count-1}];reg inv[0:{count*d-1}];reg[{ow-1}:0]expected[0:{count-1}];integer f,i,cycles=0;reg[31:0]rng=23;reg take,held_valid=0;reg[{ow+2}:0]held;
 wire[{ow-1}:0]token={{m_disparity_q,m_integer,m_offset,m_confidence,m_invalid,m_status}};
 always @(posedge clk)begin cycles=cycles+1;if(cycles>1000000)$fatal(1,"timeout");if(rst_n&&!abort)begin if(held_valid&&(!m_valid||{{token,m_sof,m_eol,m_last}}!==held))$fatal(1,"hold");held_valid=m_valid&&(!ce||!m_ready);held={{token,m_sof,m_eol,m_last}};end else held_valid=0;end
 task tick;begin @(negedge clk);rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[1];m_ready=rng[2]&rng[3];end endtask
 initial begin $readmemh("costs.mem",cost);$readmemh("invalid.mem",inv);$readmemh("gaps.mem",gaps);$readmemh("expected.mem",expected);
 repeat(3)@(negedge clk);rst_n=1;
 for(f=0;f<{count};f=f+1)begin ce=1;cfg_min_gap=gaps[f];cfg_valid=1;@(negedge clk);cfg_valid=0;
 i=0;while(i<{d})begin s_disp=i;s_cost=cost[f*{d}+i];s_cost_invalid=inv[f*{d}+i];s_sof=1;s_eol=1;s_last=1;s_valid=1;
 @(posedge clk);take=ce&&s_ready;if(take)i=i+1;tick;end s_valid=0;
 // Pending configuration during processing must not change this pixel's uniqueness policy.
 cfg_valid=1;cfg_min_gap=0;
 while(!m_valid)tick;
 if(token!==expected[f]||!m_sof||!m_eol||!m_last)$fatal(1,"case=%d got=%h expected=%h",f,token,expected[f]);
 while(m_valid)tick;cfg_valid=0;if(!done_valid||frame_error||error_code)$fatal(1,"done");ce=0;done_ready=1;repeat(2)@(negedge clk);if(!done_valid)$fatal(1,"CE done");ce=1;@(negedge clk);done_ready=0;
 end
 $display("PASS stereo_subpixel D{d} B{bits} Q{frac}: {count} complete axes masks/ties/boundaries/nonconvex/exact rounding/extremes/gap/CE/hold");$finish;end endmodule'''
  (p/'tb.sv').write_text(tb);tag=f'd{d}_b{bits}_q{frac}'
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',H/'stereo_subpixel.sv',p/'tb.sv'],ROOT,H/f'{tag}_compile.log')
  print(execute(['vvp',p/'sim'],p,H/f'{tag}_simulation.log').strip(),flush=True)
 return {'result':'PASS','disparities':d,'cost_bits':bits,'frac_bits':frac,'axes':count,'cost_beats':count*d,'invalid_outputs':sum(row[4] for row in expected),'refined_outputs':sum(bool(row[5]&1) for row in expected)}
if __name__=='__main__':
 rows=[run(16,16,4),run(32,24,8),run(32,24,12),run(3,2,12)]
 for script in ('test_protocol.py','test_numeric_limits.py','test_reference_variant.py'):
  print(execute([sys.executable,'-B',H/script],ROOT,H/(script.removesuffix('.py')+'_driver.log'),timeout=120).strip(),flush=True)
 (H/'test_evidence.json').write_text(json.dumps({'result':'PASS','oracle':'exact Python Fraction, nearest ties away from zero','cases':rows,'rtl_sha256':hashlib.sha256((H/'stereo_subpixel.sv').read_bytes()).hexdigest(),'board':False},indent=2)+'\n')
