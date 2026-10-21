"""Independent Python big-integer statistics oracle and stream protocol tests."""
from pathlib import Path
import os,tempfile,subprocess,json,random,math
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])

def oracle(frame,bits,radius,k,r):
 h,w=len(frame),len(frame[0]);out=[]
 for y in range(h):
  for x in range(w):
   values=[frame[min(h-1,max(0,y+dy))][min(w-1,max(0,x+dx))] for dy in range(-radius,radius+1) for dx in range(-radius,radius+1)]
   n=len(values);total=sum(values);squares=sum(v*v for v in values)
   mean=total//n
   # Direct deviations about the exact rational mean, independent of RTL sums.
   variance_numerator=sum((v*n-total)**2 for v in values)//n
   variance=variance_numerator//(n*n)
   std=math.isqrt(variance)
   threshold=mean*((256-k)*r+k*std)//(256*r)
   assert 0<=variance_numerator<=n*n*((1<<bits)-1)**2
   assert 0<=threshold<1<<(2*bits)
   out.append((mean,std,threshold,int(frame[y][x]>threshold)))
 return out

def run():
 rng=random.Random(2026471);results=[]
 profiles=[(8,1,1,1,51,128),(8,1,5,2,128,128),(8,6,1,1,256,1),
           (8,5,4,1,0,128),(10,6,5,2,51,512),(12,5,5,1,256,2048),
           (8,3,2,7,51,128),(8,7,6,1,51,128)]
 for bits,w,h,rad,k,r in profiles:
  d=(1<<bits)-1
  frames=[[[v for x in range(w)] for y in range(h)] for v in (0,d,d//2)]
  frames += [[[d*x//max(1,w-1) for x in range(w)] for y in range(h)],
             [[d*y//max(1,h-1) for x in range(w)] for y in range(h)],
             [[d if x>=w//2 and y>=h//2 else 0 for x in range(w)] for y in range(h)],
             [[d if (x+y)%2 else 0 for x in range(w)] for y in range(h)],
             [[rng.randrange(d+1) for x in range(w)] for y in range(h)],
             [[d if x==w//2 else 0 for x in range(w)] for y in range(h)],
             [[0 for x in range(w)] for y in range(h)]]
  frames.insert(7,[[d//4+(3*d//4)*x//max(1,w-1) if not(x==w//2 or y==h//2) else d//8 for x in range(w)] for y in range(h)])
  expected=[item for frame in frames for item in oracle(frame,bits,rad,k,r)]
  max_threshold_error=0.0;binary_differences=0
  for frame in frames:
   exact=oracle(frame,bits,rad,k,r)
   for y in range(h):
    for x in range(w):
     values=[frame[min(h-1,max(0,y+dy))][min(w-1,max(0,x+dx))] for dy in range(-rad,rad+1) for dx in range(-rad,rad+1)]
     mu=math.fsum(values)/len(values)
     sigma=math.sqrt(math.fsum((v-mu)**2 for v in values)/len(values))
     floating_threshold=mu*(1+(k/256)*(sigma/r-1))
     threshold=exact[y*w+x][2]
     # Quantization floors mean, std and final threshold; threshold never rises.
     assert threshold<=floating_threshold+1e-7
     assert floating_threshold-threshold < 2-k/256+1.5*(k/256)*d/r+1e-7
     max_threshold_error=max(max_threshold_error,floating_threshold-threshold)
     binary_differences+=exact[y*w+x][3]!=int(frame[y][x]>floating_threshold)
  with tempfile.TemporaryDirectory(prefix='sauvola_test_') as temporary:
   t=Path(temporary)
   (t/'expected.hex').write_text('\n'.join(f'{mean|(std<<bits)|(threshold<<(2*bits))|(binary<<(4*bits)):x}' for mean,std,threshold,binary in expected)+'\n')
   seq=[]
   for fi,frame in enumerate(frames):
    if fi==len(frames)-1:
     seq+=['send_pixel(1,1,0);reset_dut;']
     for yy in range(h):
      for xx in range(w):seq.append(f'send_pixel(1,{int(xx==0 and yy==0)},{int(xx==w-1)});')
     seq+=['while(dut.state!=4)@(negedge clk);reset_dut;']
     seq+=['hold_output=1;']
     for yy in range(h):
      for xx in range(w):seq.append(f'send_pixel(1,{int(xx==0 and yy==0)},{int(xx==w-1)});')
     seq+=['while(!mv)@(negedge clk);repeat(5)@(negedge clk);reset_dut;hold_output=0;']
    for y,row in enumerate(frame):
     for x,pixel in enumerate(row):
      seq.append(f'send_pixel({pixel},{int(x==0 and y==0 and fi!=7)},{int(x==w-1 and fi!=8)});')
    seq.append(f'finish_frame({(fi+1)*w*h},{int(fi in (7,8))});')
   source=TB.replace('@PARAM@',f'B={bits},W={w},H={h},RAD={rad},K={k},R={r},N={len(expected)}').replace('@SEQ@','\n'.join(seq))
   (t/'tb.v').write_text(source)
   p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(t/'sim'),str(ROOT/'sauvola_frame.v'),str(t/'tb.v')],capture_output=True,text=True)
   if p.returncode:raise RuntimeError(p.stderr)
   p=subprocess.run(['vvp',str(t/'sim')],cwd=t,capture_output=True,text=True,timeout=180)
   if p.returncode or 'PASS' not in p.stdout:raise RuntimeError(p.stdout+p.stderr)
   print(bits,w,h,rad,k,r,p.stdout.strip())
   results.append({'bits':bits,'width':w,'height':h,'radius':rad,'k_q8':k,'r':r,'frames':len(frames),'pixels':len(expected),'maximum_threshold_error_vs_real_sauvola':max_threshold_error,'binary_differences_vs_real_sauvola':binary_differences})
 invalid=[('BITS',7),('BITS',13),('WIDTH',0),('RADIUS',0),('RADIUS',8),('K_Q8',-1),('K_Q8',257),('R',0),('R',256)]
 with tempfile.TemporaryDirectory(prefix='sauvola_bad_') as temporary:
  t=Path(temporary)
  for parameter,value in invalid:
   (t/'tb.v').write_text(f'module tb; sauvola_frame #(.{parameter}({value})) dut(); initial #1 $finish; endmodule')
   p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(t/'sim'),str(ROOT/'sauvola_frame.v'),str(t/'tb.v')],capture_output=True,text=True)
   if p.returncode:continue
   p=subprocess.run(['vvp',str(t/'sim')],capture_output=True,text=True)
   if p.returncode==0:raise AssertionError(f'invalid parameter accepted: {parameter}={value}')
 (ROOT/'test_result.json').write_text(json.dumps({'status':'PASS','cases':results,'invalid_parameters':len(invalid),'seed':2026471},indent=2)+'\n')

TB=r'''
module tb;
localparam @PARAM@;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,sv=0,sof=0,eol=0,mr=0,dr=0,force_pause=0,hold_output=0;reg[B-1:0] gray=0;
wire sr,mv,binary,ms,me,ml,done,marker,arithmetic,busy;
wire[2*B-1:0] threshold;wire[B-1:0] mean,stddev;
wire[((W<2)?1:$clog2(W))-1:0] x;wire[((H<2)?1:$clog2(H))-1:0] y;
sauvola_frame #(.BITS(B),.WIDTH(W),.HEIGHT(H),.RADIUS(RAD),.K_Q8(K),.R(R)) dut(
.clk(clk),.rst(rst),.ce(ce),.s_gray(gray),.s_valid(sv),.s_sof(sof),.s_eol(eol),.s_ready(sr),
.m_valid(mv),.m_ready(mr),.m_binary(binary),.m_threshold(threshold),.m_mean(mean),.m_stddev(stddev),
.m_x(x),.m_y(y),.m_sof(ms),.m_eol(me),.m_last(ml),.done_valid(done),.done_ready(dr),
.marker_error(marker),.arithmetic_error(arithmetic),.busy(busy));
reg[4*B:0] expected[0:N-1];
reg[31:0] random_state=32'h2814f31;integer received=0,cycles=0,local_index;
reg held=0;reg[255:0] payload;
always @(negedge clk)begin
random_state=random_state^(random_state<<13);random_state=random_state^(random_state>>17);random_state=random_state^(random_state<<5);
ce=force_pause?0:random_state[3:0]!=0;mr=hold_output?0:random_state[6:4]!=0;
end
always @(posedge clk)if(!rst)begin
cycles=cycles+1;if(cycles>5000000)$fatal(1,"timeout");
if(held&&(!mv||{binary,threshold,mean,stddev,x,y,ms,me,ml}!==payload))$fatal(1,"stalled payload");
held=mv&&!(ce&&mr);payload={binary,threshold,mean,stddev,x,y,ms,me,ml};
if(ce&&mv&&mr)begin
if(received>=N||{binary,threshold,stddev,mean}!==expected[received])$fatal(1,"value %0d got %h expected %h",received,{binary,threshold,stddev,mean},expected[received]);
local_index=received%(W*H);
if(x!==local_index%W||y!==local_index/W||ms!==(local_index==0)||me!==(local_index%W==W-1)||ml!==(local_index==W*H-1))$fatal(1,"metadata");
received=received+1;
end
end
task send_pixel(input[B-1:0] v,input first,lastpixel);begin
repeat(v%2)@(negedge clk);#1;gray=v;sof=first;eol=lastpixel;sv=1;
@(posedge clk);while(!sr)@(posedge clk);
@(negedge clk);#1;sv=0;
end endtask
task finish_frame(input integer count,expected_marker);begin
while(!done)@(negedge clk);#1;
if(received!=count||marker!=expected_marker||arithmetic)$fatal(1,"terminal count=%0d expected=%0d marker=%0d arithmetic=%0d",received,count,marker,arithmetic);
repeat(5)begin @(negedge clk);#1;if(!done||marker!=expected_marker||arithmetic)$fatal(1,"done stall");end
dr=1;@(posedge clk);while(!ce)@(posedge clk);
@(negedge clk);#1;dr=0;
end endtask
task reset_dut;begin
@(negedge clk);#1;force_pause=1;rst=1;sv=0;repeat(2)@(negedge clk);#1;rst=0;held=0;
if(mv||done||marker||arithmetic)$fatal(1,"reset");
force_pause=0;
end endtask
initial begin
$readmemh("expected.hex",expected);repeat(3)@(negedge clk);#1;rst=0;
@SEQ@
$display("PASS %0d exact mean/stddev/threshold/binary pixels",received);$finish;
end
endmodule
'''
if __name__=='__main__':run()
