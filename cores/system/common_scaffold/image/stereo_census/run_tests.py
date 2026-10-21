"""Independent all-candidate Hamming oracle and randomized paired-stream checks."""
from pathlib import Path
import hashlib,random,sys,tempfile,runpy
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'integration'))
from tooling import ROOT,execute,evidence_dir,write_json
HERE=Path(__file__).resolve().parent

def oracle(left,right,lb,rb,width,height,max_disp,max_cost,uniqueness):
    output=[]
    for i,value in enumerate(left):
        choices=[] if lb[i] else sorted(((value^right[i-d]).bit_count(),d) for d in range(min(max_disp,i%width)+1) if not rb[i-d])
        if not choices:output.append((0,None,1));continue
        cost,disp=choices[0]
        invalid=cost>max_cost or (uniqueness!=0 and len(choices)>1 and choices[1][0]-cost<uniqueness)
        output.append((disp,cost,int(invalid)))
    return output

def run(bits,width,height,max_disp,folder,image_radius=None):
    rng=random.Random(bits*width+height);limit=(1<<bits)-1;n=width*height
    c=(bits+1).bit_length();d=max(1,max_disp.bit_length());frames=[]
    def add(left,right,lb=None,rb=None,max_cost=None,unique=0):
        frames.append((left,right,lb or [0]*n,rb or [0]*n,bits if max_cost is None else max_cost,unique))
    left=[rng.randrange(limit+1) for _ in range(n)]
    right=[rng.randrange(limit+1) for _ in range(n)]
    add(left,right);add(left,right,max_cost=0);add(left,right,unique=1)
    add(left,right,lb=[1]*n);add(left,right,rb=[1]*n)
    add([0]*n,[0]*n);add([0]*n,[0]*n,unique=1)
    add([0]*n,[limit]*n,max_cost=bits-1);add([0]*n,[limit]*n,max_cost=bits)
    for shift in sorted({0,min(2,max_disp),max_disp}):
        right=[rng.randrange(limit+1) for _ in range(n)]
        left=[right[y*width+max(0,x-shift)] for y in range(height) for x in range(width)]
        add(left,right,unique=1)
    for _ in range(6):
        add([rng.randrange(limit+1) for _ in range(n)],[rng.randrange(limit+1) for _ in range(n)],
            lb=[int(rng.random()<.2) for _ in range(n)],rb=[int(rng.random()<.3) for _ in range(n)],max_cost=rng.randrange(bits+1),unique=rng.randrange(4))
    raw_pairs=[]
    if image_radius is not None:
        census=runpy.run_path(str(HERE.parent/'census/run_tests.py'))['oracle']
        frames=[]
        for shift in (0,1,min(3,max_disp)):
            right=[rng.randrange(256) for _ in range(n)]
            left=[right[y*width+max(0,x-shift)] for y in range(height) for x in range(width)]
            raw_pairs.append((left,right))
        raw_pairs.append(([100]*n,[100]*n))
        for left,right in raw_pairs:
            lc=census(left,width,height,0,image_radius);rc=census(right,width,height,0,image_radius)
            add([v for v,b in lc],[v for v,b in rc],lb=[b for v,b in lc],rb=[b for v,b in rc],unique=1)
    samples=[];expected=[];configs=[]
    for number,(left,right,lb,rb,max_cost,unique) in enumerate(frames):
        if image_radius is None:
            samples.extend(l|(r<<bits)|(a<<(2*bits))|(b<<(2*bits+1)) for l,r,a,b in zip(left,right,lb,rb))
        else:
            samples.extend(l|(r<<bits) for l,r in zip(*raw_pairs[number]))
        expected.extend(disp|((bits+1 if cost is None else cost)<<d)|(invalid<<(d+c)) for disp,cost,invalid in oracle(left,right,lb,rb,width,height,max_disp,max_cost,unique))
        configs.append(max_cost|(unique<<c))
    label=f'b{bits}_{width}x{height}_d{max_disp}'+('' if image_radius is None else f'_images_r{image_radius}')
    with tempfile.TemporaryDirectory(prefix='stereo_') as temp:
        p=Path(temp)
        for name,data in (('pixels',samples),('expected',expected),('config',configs)):
            (p/f'{name}.hex').write_text(''.join(f'{v:x}\n' for v in data),encoding='utf-8')
        tb='''`timescale 1ns/1ps
module tb;
localparam B=BB,W=WW,H=HH,N=W*H,F=FF,MD=MM,C=$clog2(B+2),D=MD<1?1:$clog2(MD+1),I=2*B+2,O=C+D;
reg clk=0;always #5 clk=~clk;
reg rst=0,ce=1,cv=0,sv=0,sf=0,se=0,mr=0,dr=0;
reg[I-1:0]sd;reg[2*C-1:0]threshold;wire cr,sr,mv,corner,ms,ml,dv,error;wire[D-1:0]disparity;wire[C-1:0]cost;wire[O-1:0]score={cost,disparity};
reg[I-1:0]pixels[0:N*F-1];reg[2*C-1:0]configurations[0:F-1];reg[O:0]expected[0:N*F-1];
integer sent=0,received=0,frame=0,cycles=0;reg accepted=0,held=0;reg[O+2:0]previous;
reg[31:0]rnd=32'h121baba;
stereo_census_match_frame #(.DESC_BITS(B),.WIDTH(W),.HEIGHT(H),.MAX_DISPARITY(MD)) d(clk,rst,ce,cv,cr,threshold[C-1:0],threshold[2*C-1:C],sd[B-1:0],sd[2*B-1:B],sd[2*B],sd[2*B+1],sv,sr,sf,se,
disparity,cost,corner,mv,mr,ms,ml,dv,dr,error);
always @(posedge clk)if(rst)begin
accepted=ce&&sv&&sr;if(accepted)sent=sent+1;
if(ce&&mv&&mr)begin
if({corner,score}!==expected[frame*N+received]||ms!==(received==0)||ml!==(received%W==W-1))
$fatal(1,"STEREO frame %d pixel %d got %d %d expected %h",frame,received,corner,score,expected[frame*N+received]);
received=received+1;
end
end
always @(negedge clk)if(rst)begin
if(held&&{corner,score,ms,ml}!==previous)$fatal(1,"stall stability");
rnd={rnd[30:0],rnd[31]^rnd[21]^rnd[1]^rnd[0]};ce=rnd[1]||rnd[4];mr=rnd[7];
held=mv&&(!ce||!mr);previous={corner,score,ms,ml};cycles=cycles+1;
if(cycles>1000000)$fatal(1,"timeout");
end
initial begin
$readmemh("pixels.hex",pixels);$readmemh("expected.hex",expected);$readmemh("config.hex",configurations);
repeat(3)@(negedge clk);#1;rst=1;
for(frame=0;frame<F;frame=frame+1)begin
sent=0;received=0;
if(frame==1)begin
@(negedge clk);#1;sv=1;sf=0;se=(W==1);sd=0;
@(posedge clk);while(!(ce&&sr))@(posedge clk);
@(negedge clk);#1;sv=0;wait(dv);if(!error||mv)$fatal(1,"bad frame before recovery");
@(negedge clk);#1;dr=1;
@(posedge clk);while(!ce)@(posedge clk);
@(negedge clk);#1;dr=0;sent=0;received=0;accepted=0;
end
@(negedge clk);#1;cv=1;threshold=configurations[frame];
@(posedge clk);while(!(ce&&cr))@(posedge clk);
@(negedge clk);#1;cv=0;
while(sent<N)begin
@(negedge clk);#1;
if(!sv||accepted)begin sv=sent<N&&(rnd[3]||rnd[8]);if(sent<N)begin sd=pixels[frame*N+sent];sf=sent==0;se=sent%W==W-1;end end
end
@(negedge clk);#1;sv=0;
wait(dv);if(received!=N||error)$fatal(1,"frame result");
repeat(3)@(negedge clk);#1;dr=1;
@(posedge clk);while(!ce)@(posedge clk);
@(negedge clk);#1;dr=0;
end
// A malformed first marker produces an error result and no score stream.
@(negedge clk);#1;sv=1;sf=0;se=(W==1);sd=0;
@(posedge clk);while(!(ce&&sr))@(posedge clk);
@(negedge clk);#1;sv=0;wait(dv);if(!error||mv)$fatal(1,"marker rejection");
// Reset also aborts a stalled result and clears diagnostics.
rst=0;@(posedge clk);@(negedge clk);#1;if(dv||mv||error)$fatal(1,"reset");
$display("STEREO PASS frames=%0d pixels=%0d",F,N*F);$finish;
end endmodule
'''
        sources=[HERE/'stereo_census_match_frame.sv']
        if image_radius is not None:
            start=tb.index('stereo_census_match_frame #')
            end=tb.index('always @(posedge clk)',start)
            tb=tb[:start]+"""wire lsr,rsr,lv,rv,lr,rr,lb,rb,ssr;wire[B-1:0]ld,rd;
wire ignored0,ignored1,ignored2,ignored3,ignored4,ignored5,ignored6,ignored7,ignored8,ignored9;
assign sr=lsr&&rsr;assign lr=ssr&&rv;assign rr=ssr&&lv;
img_census_frame #(.WIDTH(W),.HEIGHT(H),.BITS(8),.RADIUS(RRR)) lc(
clk,rst,ce,1'b0,ignored0,8'b0,sd[7:0],sv&&rsr,lsr,sf,se,
ld,lb,lv,lr,ignored1,ignored2,ignored3,1'b1,ignored4);
img_census_frame #(.WIDTH(W),.HEIGHT(H),.BITS(8),.RADIUS(RRR)) rc(
clk,rst,ce,1'b0,ignored5,8'b0,sd[B+7:B],sv&&lsr,rsr,sf,se,
rd,rb,rv,rr,ignored6,ignored7,ignored8,1'b1,ignored9);
stereo_census_match_frame #(.DESC_BITS(B),.WIDTH(W),.HEIGHT(H),.MAX_DISPARITY(MD)) d(
clk,rst,ce,cv,cr,threshold[C-1:0],threshold[2*C-1:C],ld,rd,lb,rb,lv&&rv,ssr,ignored1,ignored2,
disparity,cost,corner,mv,mr,ms,ml,dv,dr,error);
""".replace('RRR',str(image_radius))+tb[end:]
            start=tb.index('if(frame==1)begin');end=tb.index('@(negedge clk);#1;cv=1;',start)
            tb=tb[:start]+tb[end:]
            start=tb.index('// A malformed first marker');end=tb.index('rst=0;@(posedge clk)',start)
            tb=tb[:start]+tb[end:]
            sources.append(HERE.parent/'census/img_census_frame.sv')
        for name,value in (('BB',bits),('WW',width),('HH',height),('FF',len(frames)),('MM',max_disp)):tb=tb.replace(name,str(value))
        (p/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*sources,p/'tb.sv'],p,folder/f'{label}_compile.log')
        output=execute(['vvp',p/'sim'],p,folder/f'{label}_simulation.log')
        assert 'STEREO PASS' in output
    return dict(bits=bits,width=width,height=height,max_disparity=max_disp,frames=len(frames),outputs=len(expected),input_scope="descriptors" if image_radius is None else "actual dual-Census RTL",status='PASS')

def main():
    folder=evidence_dir('stereo_census')
    cases=[run(b,w,h,d,folder) for b,w,h,d in ((8,7,3,3),(24,9,5,6),(1,1,1,0),(32,3,2,7),(64,5,1,2))]
    cases.extend(run((2*r+1)**2-1,w,h,4,folder,image_radius=r) for r,w,h in ((1,9,7),(2,13,9)))
    write_json(folder/'result.json',dict(status='PASS',cases=cases,board_tested=False,rtl_sha256=hashlib.sha256((HERE/'stereo_census_match_frame.sv').read_bytes()).hexdigest()))
    print(cases);print(folder)
if __name__=='__main__':main()
