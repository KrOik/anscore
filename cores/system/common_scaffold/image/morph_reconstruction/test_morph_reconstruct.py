"""Independent simultaneous geodesic oracle and actual scikit-image reference."""
from pathlib import Path
import os,tempfile,subprocess,json,random
import numpy as np
import skimage
from skimage.morphology import reconstruction
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])

def oracle(marker,mask,erosion,connect8,limit):
 h,w=len(marker),len(marker[0]);current=[row[:] for row in marker]
 illegal=any((marker[y][x]<mask[y][x] if erosion else marker[y][x]>mask[y][x]) for y in range(h) for x in range(w))
 if illegal or not limit:return current,0,0,0,int(illegal),int(not limit)
 for iteration in range(1,limit+1):
  result=[]
  for y in range(h):
   row=[]
   for x in range(w):
    neighbors=[current[yy][xx] for yy in range(max(0,y-1),min(h,y+2)) for xx in range(max(0,x-1),min(w,x+2)) if connect8 or abs(xx-x)+abs(yy-y)<=1]
    row.append(max(mask[y][x],min(neighbors)) if erosion else min(mask[y][x],max(neighbors)))
   result.append(row)
  stable=result==current;current=result
  if stable:return current,iteration,1,0,0,0
 return current,limit,0,1,0,0

def run():
 rng=random.Random(2026474);results=[]
 for bits,w,h in ((8,1,1),(8,1,7),(8,7,1),(8,7,6),(10,6,5),(12,5,4)):
  d=(1<<bits)-1;p=w*h;zero=lambda:[[0]*w for _ in range(h)]
  full=[[d]*w for _ in range(h)];seed=zero();seed[0][0]=d
  obstacle=[[d if x!=w//2 or y==h-1 else 0 for x in range(w)] for y in range(h)]
  om=zero();om[0][0]=obstacle[0][0];om[-1][-1]=obstacle[-1][-1]//2
  corridor=zero()
  for y in range(h):
   for x in range(w):
    if y%2==0 or x==(w-1 if (y//2)%2==0 else 0):corridor[y][x]=d
  cm=zero();cm[0][0]=d
  random_mask=[[rng.randrange(d+1) for _ in range(w)] for _ in range(h)]
  rm=[[rng.randrange(v+1) for v in row] for row in random_mask]
  complement=lambda image:[[d-v for v in row] for row in image]
  bad_d=zero();bad_mask=zero();bad_d[-1][-1]=1
  bad_e=full.copy();bad_e=[row[:] for row in full];bad_e[0][0]=d-1
  cases=[(zero(),zero(),0,0,1),(full,full,1,1,1),
         (seed,full,0,0,p+1),(complement(seed),complement(full),1,0,p+1),
         (om,obstacle,0,0,p+1),(complement(om),complement(obstacle),1,1,p+1),
         (cm,corridor,0,0,p+1),(cm,corridor,0,0,1),
         (rm,random_mask,0,1,p+1),(complement(rm),complement(random_mask),1,0,p+1),
         (random_mask,random_mask,0,1,1),(bad_d,bad_mask,0,0,p+1),
         (bad_e,full,1,1,p+1),(seed,full,0,0,0),
         (rm,random_mask,0,0,p+1),(zero(),zero(),0,1,1)]
  cases.append((complement(cm),complement(corridor),1,1,1))
  diagonal=[[d if x==y else 0 for x in range(w)] for y in range(h)]
  diagonal_marker=zero();diagonal_marker[0][0]=d
  for op in (0,1):
   for connectivity in (0,1):
    cases.append((complement(diagonal_marker) if op else diagonal_marker,
                  complement(diagonal) if op else diagonal,op,connectivity,p+1))
  for op in (0,1):
   for connectivity in (0,1):
    extra_mask=[[rng.randrange(d+1) for _ in range(w)] for _ in range(h)]
    extra_marker=[[rng.randrange(v+1) for v in row] for row in extra_mask]
    cases.append((complement(extra_marker) if op else extra_marker,
                  complement(extra_mask) if op else extra_mask,op,connectivity,p+1))
  expected=[];statuses=[];seq=[];converged_references=0;limits=0
  for fi,(marker,mask,erosion,conn,limit) in enumerate(cases):
   output,iterations,conv,truncated,constraint,config=oracle(marker,mask,erosion,conn,limit)
   footprint=np.ones((3,3),dtype=bool) if conn else np.array([[0,1,0],[1,1,1],[0,1,0]],dtype=bool)
   if constraint:
    try:reconstruction(np.asarray(marker),np.asarray(mask),method='erosion' if erosion else 'dilation',footprint=footprint)
    except ValueError:pass
    else:raise AssertionError('skimage accepted illegal marker/mask')
   else:
    reference=reconstruction(np.asarray(marker),np.asarray(mask),method='erosion' if erosion else 'dilation',footprint=footprint)
    if conv:assert np.array_equal(reference,output);converged_references+=1
    else:
     limits+=int(truncated)
     assert np.all(np.asarray(output)>=reference) if erosion else np.all(np.asarray(output)<=reference)
   if fi==15:
    seq+=['send_pair(0,0,1,0);reset_dut;cfg_erosion=0;cfg_connect8=1;cfg_max_iterations=65535;']
    for ii in range(p):seq.append(f'send_pair(0,{d},{int(ii==0)},{int(ii%w==w-1)});')
    seq+=['while(dut.state!=8)@(negedge clk);reset_dut;']
    if w==7 and h==6:
     seq+=['hold_output=1;cfg_erosion=0;cfg_connect8=0;cfg_max_iterations=65535;']
     for ii in range(p):seq.append(f'send_pair(0,0,{int(ii==0)},{int(ii%w==w-1)});')
     seq+=['while(!mv)@(negedge clk);repeat(5)@(negedge clk);reset_dut;hold_output=0;']
   expected.extend(v for row in output for v in row)
   marker_error=int(fi in (10,14))
   status=(iterations<<5)|(conv<<4)|(truncated<<3)|(marker_error<<2)|(constraint<<1)|config
   statuses.append(status)
   seq.append(f'cfg_erosion={erosion};cfg_connect8={conn};cfg_max_iterations={limit};')
   for y in range(h):
    for x in range(w):
     seq.append(f'send_pair({marker[y][x]},{mask[y][x]},{int(x==0 and y==0 and fi!=14)},{int(x==w-1 and fi!=10)});')
     if x==0 and y==0:seq.append(f'cfg_erosion={1-erosion};cfg_connect8={1-conn};cfg_max_iterations=0;')
   seq.append(f'finish_frame({(fi+1)*p},{status});')
  with tempfile.TemporaryDirectory(prefix='morphrec_test_') as temporary:
   t=Path(temporary)
   (t/'expected.hex').write_text('\n'.join(f'{v:x}' for v in expected)+'\n')
   (t/'status.hex').write_text('\n'.join(f'{v:x}' for v in statuses)+'\n')
   (t/'tb.v').write_text(TB.replace('@PARAM@',f'B={bits},W={w},H={h},N={len(expected)}').replace('@SEQ@','\n'.join(seq)))
   p1=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(t/'sim'),str(ROOT/'morph_reconstruct_frame.v'),str(t/'tb.v')],capture_output=True,text=True)
   if p1.returncode:raise RuntimeError(p1.stderr)
   p1=subprocess.run(['vvp',str(t/'sim')],cwd=t,capture_output=True,text=True,timeout=240)
   if p1.returncode or 'PASS' not in p1.stdout:raise RuntimeError(p1.stdout+p1.stderr)
   print(bits,w,h,p1.stdout.strip(),flush=True)
  results.append({'bits':bits,'width':w,'height':h,'frames':len(cases),'pixels':len(expected),'skimage_converged_matches':converged_references,'bounded_not_converged_cases':limits,'maximum_iterations_observed':max(s>>5 for s in statuses)})
 with tempfile.TemporaryDirectory(prefix='morphrec_invalid_') as temporary:
  t=Path(temporary);invalid=[('BITS',7),('BITS',13),('WIDTH',0),('HEIGHT',4097)]
  for parameter,value in invalid:
   (t/'tb.v').write_text(f'module tb;morph_reconstruct_frame #(.{parameter}({value})) dut();initial #1 $finish;endmodule')
   p1=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(t/'sim'),str(ROOT/'morph_reconstruct_frame.v'),str(t/'tb.v')],capture_output=True,text=True)
   if p1.returncode:continue
   p1=subprocess.run(['vvp',str(t/'sim')],capture_output=True,text=True)
   if p1.returncode==0:raise AssertionError(f'invalid {parameter}={value} accepted')
 (ROOT/'test_result.json').write_text(json.dumps({'status':'PASS','skimage_version':skimage.__version__,'cases':results,'invalid_parameters':len(invalid),'seed':2026474},indent=2)+'\n')

TB=r'''
module tb;
localparam @PARAM@;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,sv=0,sof=0,eol=0,mr=0,dr=0,pause=0,hold_output=0;
reg cfg_erosion=0,cfg_connect8=0;reg[15:0] cfg_max_iterations=100;
reg[B-1:0] marker=0,mask=0;wire sr,mv,ms,me,ml,done,converged,limited,marker_error,constraint_error,config_error,busy;
wire[15:0] iterations;wire[B-1:0] pixel;
wire[((W<2)?1:$clog2(W))-1:0] x;wire[((H<2)?1:$clog2(H))-1:0] y;
morph_reconstruct_frame #(.BITS(B),.WIDTH(W),.HEIGHT(H)) dut(
.clk(clk),.rst(rst),.ce(ce),.cfg_erosion(cfg_erosion),.cfg_connect8(cfg_connect8),.cfg_max_iterations(cfg_max_iterations),
.s_marker(marker),.s_mask(mask),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),.m_valid(mv),.m_ready(mr),.m_pixel(pixel),.m_x(x),.m_y(y),.m_sof(ms),.m_eol(me),.m_last(ml),
.done_valid(done),.done_ready(dr),.converged(converged),.limit_reached(limited),.marker_error(marker_error),.constraint_error(constraint_error),.config_error(config_error),.iterations_done(iterations),.busy(busy));
reg[B-1:0] expected[0:N-1];reg[20:0] expected_status[0:N/(W*H)-1];reg[31:0] random_state=32'h93a4bd71;
integer received=0,cycles=0,index;reg held=0;reg[255:0] payload;
wire[20:0] status={iterations,converged,limited,marker_error,constraint_error,config_error};
always @(negedge clk)begin
random_state=random_state^(random_state<<13);random_state=random_state^(random_state>>17);random_state=random_state^(random_state<<5);
ce=pause?0:random_state[3:0]!=0;mr=hold_output?0:random_state[6:4]!=0;
end
always @(posedge clk)if(!rst)begin
cycles=cycles+1;if(cycles>5000000)$fatal(1,"timeout state%0d",dut.state);
if(held&&(!mv||{pixel,x,y,ms,me,ml,status}!==payload))$fatal(1,"output stall");
held=mv&&!(ce&&mr);payload={pixel,x,y,ms,me,ml,status};
if(ce&&mv&&mr)begin
if(received>=N||pixel!==expected[received])$fatal(1,"pixel%0d got%0d expected%0d",received,pixel,expected[received]);
index=received%(W*H);
if(x!==index%W||y!==index/W||ms!==(index==0)||me!==(index%W==W-1)||ml!==(index==W*H-1))$fatal(1,"metadata");
if(status!==expected_status[received/(W*H)])$fatal(1,"output status %h expected%h",status,expected_status[received/(W*H)]);
received=received+1;
end
end
task send_pair(input[B-1:0] m,k,input first,lastpixel);begin
repeat((m+k)%2)@(negedge clk);#1;marker=m;mask=k;sof=first;eol=lastpixel;sv=1;
@(posedge clk);while(!sr)@(posedge clk);
@(negedge clk);#1;sv=0;
end endtask
task finish_frame(input integer expected_count,expected_flags);begin
while(!done)@(negedge clk);#1;
if(received!=expected_count||status!==expected_flags)$fatal(1,"terminal count%0d flags%h expected%h",received,status,expected_flags);
repeat(5)begin @(negedge clk);#1;if(!done||status!==expected_flags)$fatal(1,"DONE stall");end
dr=1;@(posedge clk);while(!ce)@(posedge clk);
@(negedge clk);#1;dr=0;
end endtask
task reset_dut;begin
@(negedge clk);#1;pause=1;rst=1;sv=0;repeat(2)@(negedge clk);#1;rst=0;held=0;
if(mv||done||status!==0)$fatal(1,"reset");pause=0;
end endtask
initial begin
$readmemh("expected.hex",expected);$readmemh("status.hex",expected_status);repeat(3)@(negedge clk);#1;rst=0;
@SEQ@
$display("PASS %0d simultaneous reconstruction pixels and exact terminal flags",received);$finish;
end
endmodule
'''
if __name__=='__main__':run()
