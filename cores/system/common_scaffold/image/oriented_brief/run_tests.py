from pathlib import Path
import sys,tempfile,random,math,json,hashlib
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import execute,ROOT

def run(r,bits):
 w=h=2*r+10;n=w*h;rng=random.Random(88+r)
 def signed6(v):return (v&63)-64 if v&32 else v&63
 base=[tuple(signed6(int(word,16)>>shift) for shift in (18,12,6,0)) for word in (H/f'base_r{r}.hex').read_text().splitlines()]
 frames=[]
 for k in range(16):
  c=math.cos(k*math.pi/8);s=math.sin(k*math.pi/8)
  frames.append([max(0,min((1<<bits)-1,int((1<<(bits-1))+(x-w//2)*c*3+(y-h//2)*s*3))) for y in range(h) for x in range(w)])
 random_frame=[rng.randrange(1<<bits) for _ in range(n)]
 frames += [random_frame,[(1<<bits)-1]*n]
 # 90-degree turns around the actual keypoint center, preserving a zero outer rim.
 centered=[rng.randrange(1<<bits) if 1<=x<w-1 and 1<=y<h-1 else 0 for y in range(h) for x in range(w)]
 frames.append(centered)
 for turn in range(3):
  prev=frames[-1];cx=cy=w//2
  frames.append([prev[(cy-(x-cx))*w+cx+(y-cy)] if 0<=cy-(x-cx)<h and 0<=cx+(y-cy)<w else 0 for y in range(h) for x in range(w)])
 keys=[(w//2,h//2),(0,0),(65535,65535)]
 expected=[]
 trig=[round(127*math.cos(k*math.pi/8)) for k in range(16)]
 def rnd(v):return int(math.copysign(math.floor(abs(v)+.5),v))
 for image in frames:
  for x,y in keys:
   bad=x<r+1 or y<r+1 or x+r+1>=w or y+r+1>=h
   if bad:expected.append((0,0,0,1));continue
   mx=sum(dx*image[(y+dy)*w+x+dx] for dy in range(-r,r+1) for dx in range(-r,r+1) if dx*dx+dy*dy<=r*r)
   my=sum(dy*image[(y+dy)*w+x+dx] for dy in range(-r,r+1) for dx in range(-r,r+1) if dx*dx+dy*dy<=r*r)
   a=max(range(16),key=lambda k:mx*trig[k]+my*trig[(k+12)%16])
   c=math.cos(a*math.pi/8);s=math.sin(a*math.pi/8);d=0
   for i,(ax,ay,bx,by) in enumerate(base):
    xa,ya,xb,yb=map(rnd,(ax*c-ay*s,ax*s+ay*c,bx*c-by*s,bx*s+by*c))
    d|=int(image[(y+ya)*w+x+xa]<image[(y+yb)*w+x+xb])<<i
   expected.append((d,a,int(bool(mx or my)),0))
 # For quarter-turn rotations, quantized orientation and rotated sample sets commute exactly.
 for j in range(19,22):
  assert expected[j*3][0]==expected[18*3][0], 'rotation descriptor invariance'
  assert expected[j*3][1]==(expected[18*3][1]+4*(j-18))%16
 with tempfile.TemporaryDirectory(prefix='oriented_brief_') as td:
  p=Path(td)
  (p/'pixels.mem').write_text('\n'.join(f'{v:x}' for f in frames for v in f))
  (p/'expected.mem').write_text('\n'.join(f'{(d<<6)|(a<<2)|(ov<<1)|bad:x}' for d,a,ov,bad in expected))
  tb=f'''module tb;
 reg clk=0;always #5 clk=~clk;reg rst=0,ce=1,sv=0,sof=0,eol=0,kv=0,rel=0,mr=0;reg [{bits-1}:0] pixel;reg [15:0] kx,ky,kid;
 wire sr,kr,rr,loaded,mv,ov,bad;wire [255:0] desc;wire [3:0] angle,err;wire [15:0] mx,my,mid;
 oriented_brief_frame #(.WIDTH({w}),.HEIGHT({h}),.BITS({bits}),.RADIUS({r}),.PATTERN_FILE("{(H/f'pattern_r{r}.mem').as_posix()}")) dut(clk,rst,ce,pixel,sv,sof,eol,sr,kv,kr,kx,ky,kid,rel,rr,loaded,desc,angle,ov,bad,mv,mx,my,mid,mr,err);
 reg [{bits-1}:0] pixels[0:{len(frames)*n-1}];reg [261:0] expected[0:{len(expected)-1}];integer f,i,k,t=0;reg take,held_valid=0;reg [309:0] held;reg [31:0] rng=32'h1234;reg [23:0] saved;
 always @(posedge clk) begin t=t+1;if(t>1000000)$fatal(1,"timeout");if(rst)begin if(held_valid&&(!mv||{{desc,angle,ov,bad,mx,my,mid}}!==held))$fatal(1,"output unstable");held_valid=mv&&(!ce||!mr);held={{desc,angle,ov,bad,mx,my,mid}};end else held_valid=0;end
 task tick;begin @(negedge clk);rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[1];mr=rng[2]&rng[3];end endtask
 initial begin $readmemh("pixels.mem",pixels);$readmemh("expected.mem",expected);repeat(3)@(negedge clk);rst=1;
 // Marker fault abort and full recovery.
 sv=1;sof=0;eol=0;@(negedge clk);sv=0;if(err!=1||loaded)$fatal(1,"marker error");
 for(f=0;f<{len(frames)};f=f+1) begin
 i=0;while(i<{n})begin sv=1;pixel=pixels[f*{n}+i];sof=i==0;eol=i%{w}=={w-1};@(posedge clk);take=ce&&sr;if(take)i=i+1;tick;end sv=0;
 if(!loaded||err)$fatal(1,"frame");
 for(k=0;k<3;k=k+1) begin ce=1;mr=0;kv=1;kx=k==0?{w//2}:k==1?0:65535;ky=k==0?{h//2}:k==1?0:65535;kid=f*3+k;@(negedge clk);kv=0;
 while(!mv)tick;if({{desc,angle,ov,bad}}!==expected[f*3+k]||mx!=kx||my!=ky||mid!=kid)$fatal(1,"mismatch f=%0d k=%0d got=%h expected=%h moments=%d,%d",f,k,{{desc,angle,ov,bad}},expected[f*3+k],dut.mx,dut.my);
 while(mv)tick;end ce=1;mr=0;rel=1;@(negedge clk);rel=0;if(loaded)$fatal(1,"release");end
 // Reset overrides CE during partial capture; next full frame can restart.
 ce=1;sv=1;sof=1;eol=0;pixel=7;@(negedge clk);sv=0;ce=0;rst=0;@(negedge clk);if(loaded||mv||sr)$fatal(1,"reset");rst=1;ce=1;
 for(i=0;i<{n};i=i+1)begin sv=1;sof=i==0;eol=i%{w}=={w-1};@(negedge clk);end sv=0;
 // Corrupt one ROM entry: constant frame selects angle0, so entry0 must reject before sampling.
 saved=dut.pattern[0];dut.pattern[0]=24'h7c0000;
 kv=1;kx={w//2};ky={h//2};@(negedge clk);kv=0;
 while(!mv)@(negedge clk);if(!bad||desc!==0||err!=3)$fatal(1,"custom ROM bounds");
 // Reset pending output with CE disabled, then recover the ROM and a fresh frame.
 rst=0;ce=0;@(negedge clk);if(mv||loaded)$fatal(1,"reset output");dut.pattern[0]=saved;
 rst=1;ce=1;for(i=0;i<{n};i=i+1)begin sv=1;sof=i==0;eol=i%{w}=={w-1};@(negedge clk);end sv=0;
 kv=1;kx={w//2};ky={h//2};@(negedge clk);kv=0;repeat(10)@(negedge clk);rst=0;ce=0;@(negedge clk);if(mv||loaded)$fatal(1,"reset work");
 $display("PASS oriented BRIEF R={r} BITS={bits} {len(expected)} descriptors all16angles quarterturns borders CE stalls release marker reset");$finish;end endmodule'''
  (p/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',H/'oriented_brief_frame.sv',p/'tb.sv'],ROOT,H/f'compile_r{r}.log')
  result=execute(['vvp',p/'sim'],p,H/f'test_r{r}.log',timeout=120)
  print(result.strip())
 return {'radius':r,'bits':bits,'frames':len(frames),'descriptors':len(expected),'result':'PASS'}
if __name__=='__main__':
 trig=[round(127*math.cos(k*math.pi/8)) for k in range(16)]
 bounds=[]
 for i in range(16):
  j=(i+1)%16;dx=trig[i]-trig[j];dy=trig[(i+12)%16]-trig[(j+12)%16]
  crossing=math.degrees(math.atan2(-dx,dy))%180
  target=i*22.5+11.25
  crossing=min((crossing+180*k for k in range(-1,4)),key=lambda a:abs(a-target))
  bounds.extend([abs(crossing-i*22.5),abs(crossing-(i+1)*22.5)])
 assert max(bounds)<12, bounds
 result=[run(1,8),run(3,8),run(7,10),run(15,12)]
 (H/'test_evidence.json').write_text(json.dumps({'result':'PASS','cases':result,'max_analytic_angle_error_degrees':max(bounds),'board':False},indent=2)+'\n')
